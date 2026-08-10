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


def raw_command(text):
    """The Bash command, or None when it is not safe to read one this way.

    `values` stops at the first `"`, so a command JSON had to escape arrives
    truncated — and a truncation is the one error that must not happen here:
    `echo \\"x\\" && npm run dev` cut to `echo \\` reads as a read-only command
    while the engine sees one that claims the checkout. Any backslash at all
    therefore means None. `bin/ab-hook` refuses exactly the same values by
    matching `[^"\\\\]*`, and a missing key is None in both."""
    cmd = next(values(text, "command"), None)
    if cmd is None or "\\" in cmd:
        return None
    return cmd


# Everything a party key may contain. The bash entry point refuses the same set
# with `*[!A-Za-z0-9_.-]*` and the engine with a regular expression, so all three
# agree about which ids get a line — and none of them can be talked into writing
# outside the bus by a `/` in an id.
KEYSAFE = set("abcdefghijklmnopqrstuvwxyz"
              "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

# ---- the commands the engine would exempt anyway ----------------------------
#
# `is_readonly` in the engine skips a segment whose head only reads, so
# `command_targets` yields nothing for a command made of nothing else — and then
# `resources_for` matches nothing, `wrong_port_check` sees no port,
# `explicit_resources` names nothing and `leave_party_hint` has nothing to
# record. The engine starts, finds nothing, and returns. Measured on the Windows
# work machine this file exists for: 478 ms to be told that against 132 ms for
# deciding it here, and on that machine's real command mix 11 of 18 commands were
# exactly this shape — `git status --short`, `git log --oneline -1`,
# `git -C <path> worktree list`.
#
# These are `FASTPATH_SKIP_HEADS` and `GIT_READONLY_SUBCOMMANDS` from
# bin/agentbus, and `bin/ab-hook` carries the same two; `tests/test_matcher.py`
# fails if any of the three copies drifts. They are carried rather than imported
# because importing the engine is the cost this file exists to avoid, and carried
# rather than read from the bus because they are code and not configuration —
# nothing about them varies per machine, and a list shipped through the bus would
# leave a just-upgraded fast path reading the previous version's.
#
# Note what is NOT here. `agentbus` is in the engine's own read-only list and
# deliberately absent from this one: an `agentbus` line names its resource
# outright and leaves the party hint, neither of which goes through the read-only
# skip. `kill` and `pkill` are absent for the engine's own reason — killing the
# process that serves a resource is the most decisive way there is of touching
# it — while `ps`, `pgrep` and `lsof` are here, because asking what is running is
# not running it.
RO_HEADS = frozenset("""
awk basename bat cat code cut date diff dirname echo false fd file find grep
head jq less ll ls lsof man more open pgrep printf ps pwd realpath rg sed sort
stat tail test tree true type uniq wc which yq
""".split())
RO_GIT = frozenset("""
blame branch cat-file check-ignore config describe diff fetch for-each-ref grep
log ls-files reflog remote rev-parse shortlog show status tag worktree
""".split())
# `WRAPPERS` in the engine, stripped before the head is read.
RO_WRAPPERS = frozenset("sudo time nohup exec command env caffeinate".split())
# git's global options, which sit between the command and its subcommand:
# `strip_git_globals`. The first group takes an argument of its own.
GIT_GLOBAL_2 = frozenset(
    "-C -c --namespace --work-tree --git-dir --exec-path --config-env".split())
GIT_GLOBAL_1 = frozenset(
    "-p --paginate -P --no-pager --bare --no-replace-objects "
    "--literal-pathspecs".split())
GIT_GLOBAL_EQ = ("--git-dir=", "--work-tree=", "--namespace=", "--exec-path=",
                 "--config-env=")
# `^[A-Za-z_][A-Za-z0-9_]*=` without importing `re`, which is 60 ms here.
ASSIGN_HEAD = set("abcdefghijklmnopqrstuvwxyz"
                  "ABCDEFGHIJKLMNOPQRSTUVWXYZ_")
ASSIGN_REST = ASSIGN_HEAD | set("0123456789")


def is_assignment(tok):
    """`VAR=value`, by the engine's rule and not a looser one: `a-b=c` is not an
    assignment to the engine, so stripping it here would uncover a read-only
    head the engine never sees."""
    if not tok or tok[0] not in ASSIGN_HEAD:
        return False
    for i, ch in enumerate(tok):
        if ch == "=":
            return i > 0
        if ch not in ASSIGN_REST:
            return False
    return False


def all_readonly(cmd):
    """Is every segment of this command one the engine would skip?

    Allowed to be wrong in one direction only. Where it cannot be sure it says
    no and the engine decides, because a wrong yes is a class of command nothing
    guards and it fails silently. It is only ever asked about a command JSON
    wrote with no escape in it, which is what makes the two splits below exact:
    with no quote and no backslash anywhere, splitting on `;`, `&&`, `||` and
    `|` is the split `split_segments` makes, and splitting on whitespace is what
    `tokens_of` returns.

    `bin/ab-hook` makes the same decision by the same steps; every branch of it
    is compared against this one in tests/test_pyhook.sh."""
    # The separators `split_segments` splits on, in its order: `&&` and `||`
    # before the single `|` inside them. A lone `&` is not one of them there, so
    # it is not one here either.
    for sep in ("&&", "||", ";", "|"):
        cmd = cmd.replace(sep, "\n")
    for seg in cmd.split("\n"):
        toks = seg.split()
        # Leading assignments and wrappers, as `command_targets` strips them:
        # alternating, so `env FOO=1 git status` loses both.
        while toks and (is_assignment(toks[0])
                        or os.path.basename(toks[0]) in RO_WRAPPERS):
            toks = toks[1:]
        if not toks:
            continue                      # nothing left to act on
        head = os.path.basename(toks[0])
        if head == "git":
            # `strip_git_globals`, so that `git -C <path> status` reads as `git
            # status`. Stopping early is safe: the subcommand then looks like an
            # option instead, which is in no list, and the engine is woken.
            i, n = 1, len(toks)
            while i < n:
                if toks[i] in GIT_GLOBAL_2:
                    i += 2
                elif toks[i] in GIT_GLOBAL_1 \
                        or toks[i].startswith(GIT_GLOBAL_EQ):
                    i += 1
                else:
                    break
            sub = next((t for t in toks[i:] if not t.startswith("-")), "")
            if sub in RO_GIT:
                continue
            return False
        if head in RO_HEADS:
            continue
        return False
    return True


def acted(text, sid, tool):
    """What this party last did, for the board's live line: one line, overwritten.

    The same write `bin/ab-hook` performs, in the same place and with the same
    content. No timestamp: the file's mtime is the time, exactly as the
    heartbeat's is. Keyed by party, because `agent_id` is on a subagent's
    payloads and its parent must not be credited with work it did not do."""
    if not sid:
        return
    aid = field(text, "agent_id")
    key = "%s__%s" % (sid, aid) if aid else sid
    if set(key) - KEYSAFE:
        return
    if tool == "Bash":
        what = field(text, "command")
    elif tool in ("Edit", "Write", "NotebookEdit"):
        what = field(text, "file_path") or field(text, "notebook_path")
    else:
        return
    # The payload is JSON, so a newline inside a command arrives as the two
    # characters `\` and `n` and never as a real one. Cut there, and drop a
    # backslash the cut left dangling.
    what = what.split("\\n")[0]
    if what.endswith("\\"):
        what = what[:-1]
    try:
        with open(os.path.join(BUS, "acted", key), "w") as fh:
            fh.write("%s %s\n" % (tool, what[:200]))
    except OSError:
        pass


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
    layer must never be the reason a session breaks.

    This is the only way into the engine either fast path uses, `bin/ab-hook`
    included since 2.12.0 — a file the interpreter is handed as a script is
    `__main__`, and `__main__` is never cached, so running it recompiled ten
    thousand lines on every wake. On the Windows work machine that was 238 ms of
    a 313 ms floor and the cache gives back 115 ms of it; on a quiet Mac it is
    36 ms of 54 ms.

    When the plugin directory is not writable there is no cache to apply: Python
    swallows the failed write, the engine loads and runs exactly as it would
    otherwise, and every wake pays the compile again. Nothing breaks and nothing
    says so, which is why `agentbus doctor` now reports it."""
    try:
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("agentbus_engine", ENGINE)
        spec = importlib.util.spec_from_loader("agentbus_engine", loader)
        engine = importlib.util.module_from_spec(spec)
        loader.exec_module(engine)
        # `main` is not reached this way, and the console encoding was the first
        # thing it did. A hook's own decisions are ASCII JSON, but its "could not
        # read the payload" warning is not, and that warning exists because a
        # guard which fails open must say so out loud.
        #
        # Guarded, because this file and the engine beside it are not guaranteed
        # to be the same version: a plugin update replaces a directory file by
        # file, and for the moment in between, one of them is older. A hook that
        # decided nothing because a helper had been renamed would take every guard
        # off, which is a far worse outcome than a mojibake warning.
        try:
            engine.use_utf8()
        except AttributeError:
            pass
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
    # Executable, not merely present, because that is what `bin/ab-hook` asks
    # and the two must decide alike — an engine that lost its mode bits would
    # otherwise stop guarding on macOS and go on guarding on Windows, which is
    # worse than either. `os.X_OK` has no effect on Windows, where any existing
    # file answers yes, so this is the same test there as before.
    if not event or not os.access(ENGINE, os.X_OK):
        return 0

    # `hook.py wake <event>` — the gate has already been passed, by `bin/ab-hook`,
    # which cannot import the engine itself and so hands over here to get the
    # bytecode cache. Nothing is re-decided: the shell fast path decided, and two
    # files deciding the same thing twice is how they come to disagree.
    if event == "wake" and len(sys.argv) > 2:
        return wake(sys.argv[2], sys.stdin.buffer.read())

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
        # Before the gates below, which decide whether the ENGINE is worth
        # waking: this is worth writing either way, since the tool call that
        # matters most to somebody watching the board is usually the one that
        # needed no coordination at all.
        acted(text, sid, tool)
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
            # A token matched — but the pre-filter scans the whole payload, cwd
            # included, so `git status` inside a checkout whose path names a
            # guarded tool matches every time. The engine would skip every
            # segment of a command like that and find nothing; see
            # `all_readonly`. Second, because one scan of the payload is cheaper
            # than parsing the command, and most commands never get here.
            #
            # `raw_command` refuses a value JSON had to escape: a command read
            # with a scan that stops at the first quote would arrive truncated,
            # and `echo \"x\" && npm run dev` truncated to `echo \` reads as
            # read-only while the engine sees a command that claims the
            # checkout. `bin/ab-hook` refuses the same values, with `[^"\\]*`.
            one = raw_command(text)
            if one is not None and all_readonly(one):
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
