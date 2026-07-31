#!/usr/bin/env python3
"""agent-bus — hook fast path for hosts without a shell.

This is `bin/ab-hook` written in Python, for Windows and anywhere else the
POSIX entry point cannot be used. It makes the same decisions in the same
order, and exists for the same reason: to answer "nothing to do here" without
loading the engine.

Why it is worth a separate file rather than an early return inside the engine.
Measured on a Windows 10 host with endpoint scanning, per hook:

    interpreter start                     103 ms   unavoidable
    reading and compiling the engine       95 ms   avoided here
    the engine's `import json, re`         60 ms   avoided here
    ensure_dirs, argv, stdin               23 ms   avoided here

So a hook with nothing to do cost 281 ms, of which 178 ms was spent getting
ready to decide there was nothing to do. This file imports `os` and `sys` and
nothing else — no `json`, no `re`, both of which are filesystem-bound and were
the single most expensive line on that machine — and reads the payload with
plain string scanning, exactly as the bash version does.

When there IS something to do it imports the engine as a *module*, which a
script can never be: Python writes no bytecode cache for `__main__`, so running
the engine directly recompiles five thousand lines every time. Importing it
warm cost 4 ms against 30 ms cold here, and saved 71 ms there.

It must never fail a session: every path exits 0 unless the engine deliberately
returns a decision.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, "agentbus")
BUS = os.environ.get("AGENTBUS_HOME") or os.path.join(
    os.path.expanduser("~"), ".claude", "agent-bus")

# Once the engine is loaded there is nothing left to save, so these are the only
# events that get to skip it.
UNGATED = ("session-start", "session-end", "prompt-submit",
           "subagent-start", "subagent-stop")


def read_int(path, default=0):
    try:
        with open(path) as fh:
            return int(fh.read().strip() or default)
    except Exception:
        return default


def values(text, key):
    """Every `"key": "value"` in the payload, without importing `re`.

    The payload is JSON, but parsing it costs an `import json` — 60 ms on the
    machine this was written for — to answer questions a scan answers exactly
    as well. Whitespace around the colon is tolerated, because the bash entry
    point tolerates it and the two must decide alike."""
    quoted, at = '"%s"' % key, 0
    while True:
        at = text.find(quoted, at)
        if at < 0:
            return
        i = at + len(quoted)
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
        if i < len(text) and text[i] == ":":
            i += 1
            while i < len(text) and text[i] in " \t\r\n":
                i += 1
            if i < len(text) and text[i] == '"':
                end = text.find('"', i + 1)
                if end > 0:
                    yield text[i + 1:end]
        at = i or at + 1


def field(text, key):
    for v in values(text, key):
        return v
    return ""


def anybody_behind():
    """Is any live session behind the end of the event stream?

    A session that has just left may have handed something over that nobody has
    read, and its own exit is what took the live count back to one — so the
    handoff the two-session case exists to deliver would be dropped exactly when
    it matters."""
    seq = read_int(os.path.join(BUS, "events.seq"))
    if not seq:
        return False
    cursors = os.path.join(BUS, "cursors")
    try:
        names = os.listdir(cursors)
    except OSError:
        return False
    for name in names:
        # A cursor left behind by a crash would lag for ever and hold this gate
        # open on every batch.
        if not os.path.isfile(os.path.join(BUS, "sessions", name + ".json")):
            continue
        if read_int(os.path.join(cursors, name)) != seq:
            return True
    return False


def wake(event, raw):
    """Hand over to the engine, importing it as a module so the bytecode cache
    applies. Anything at all going wrong here exits quietly: a coordination
    layer must never be the reason a session breaks."""
    try:
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("agentbus_engine", ENGINE)
        spec = importlib.util.spec_from_loader("agentbus_engine", loader)
        engine = importlib.util.module_from_spec(spec)
        loader.exec_module(engine)
        engine.ensure_dirs()
        engine.run_hook(event, raw)
    except SystemExit:
        raise
    except Exception:
        if os.environ.get("AGENTBUS_DEBUG"):
            import traceback
            traceback.print_exc(file=sys.stderr)
    return 0


def main():
    if os.environ.get("AGENTBUS_OFF"):
        return 0
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    if not event or not os.path.exists(ENGINE):
        return 0

    if event in UNGATED:
        # Once per session, per user turn, or per subagent: always worth it.
        return wake(event, sys.stdin.buffer.read())

    if not os.path.isdir(BUS):
        return 0

    live = read_int(os.path.join(BUS, "live-count"))
    if live <= 1 and event != "post-batch":
        return 0

    if event == "post-bash":
        # Only worth a look if some command actually took a lock automatically.
        try:
            if not os.listdir(os.path.join(BUS, "autoclaim")):
                return 0
        except OSError:
            return 0
        return wake(event, sys.stdin.buffer.read())

    raw = sys.stdin.buffer.read()
    text = raw.decode("utf-8-sig", "replace")
    sid = field(text, "session_id")

    if event == "post-batch":
        if sid:
            try:            # the file's mtime IS the heartbeat; no content
                open(os.path.join(BUS, "sessions", sid + ".beat"), "w").close()
            except OSError:
                pass
        else:
            return 0
        # Alone, the only reason to look is a session that has just left having
        # handed something over — its own exit is what dropped the count.
        if live <= 1 and not anybody_behind():
            return 0
        # A batch that ran no Bash call cannot have printed anybody's build
        # failure and cannot have claimed anything. An exact test, not a
        # heuristic: the payload lists every call.
        ran_command = any(v == "Bash" for v in values(text, "tool_name"))
        if live <= 1 or not ran_command:
            if read_int(os.path.join(BUS, "events.seq")) == \
                    read_int(os.path.join(BUS, "cursors", sid)):
                return 0
        return wake(event, raw)

    if event == "record-write":
        if not sid:
            return 0
        path = field(text, "file_path") or field(text, "notebook_path")
        if not path:
            return 0
        import time
        try:
            with open(os.path.join(BUS, "writes", sid + ".log"), "a") as fh:
                fh.write("%d %s\n" % (int(time.time()), path))
        except OSError:
            pass
        # Push it into every other live session's filter, so their pre-tool
        # fast path sees the collision without waiting for their next turn.
        hot = os.path.join(BUS, "hot-for")
        try:
            names = os.listdir(hot)
        except OSError:
            return 0
        for name in names:
            if name == sid:
                continue
            try:
                with open(os.path.join(hot, name), "a") as fh:
                    fh.write(path + "\n")
            except OSError:
                pass
        return 0

    if event == "pre-tool":
        tool = field(text, "tool_name")
        if tool == "Bash":
            # One line of literal substrings derived from the configured
            # patterns. No match anywhere means no guarded resource can be
            # involved — cheap, and never a false negative, because every
            # pattern contributes a substring it must contain.
            try:
                with open(os.path.join(BUS, "guard-tokens")) as fh:
                    tokens = fh.read().strip()
            except OSError:
                return 0
            if not tokens:
                return 0
            low = text.lower()
            if tokens != "." and not any(t and t.lower() in low
                                         for t in tokens.split("|")):
                return 0
        elif tool in ("Edit", "Write", "NotebookEdit"):
            if not sid:
                return 0
            try:
                with open(os.path.join(BUS, "hot-for", sid)) as fh:
                    hot = [ln.strip() for ln in fh if ln.strip()]
            except OSError:
                return 0
            if not hot or not any(h in text for h in hot):
                return 0
        else:
            return 0
        return wake(event, raw)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except SystemExit:
        raise
    except Exception:
        if os.environ.get("AGENTBUS_DEBUG"):
            import traceback
            traceback.print_exc(file=sys.stderr)
        sys.exit(0)
