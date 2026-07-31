#!/usr/bin/env python3
"""Where a hook's time actually goes, on this machine.

    python3 tests/perf/hook-cost.py            # or the interpreter the hooks use

Every hook this plugin wires runs in front of, or behind, a tool call — so its
cost is added to the wall clock, not hidden behind the model. On macOS the bash
fast path answers the common case in ~5 ms and the engine is woken only for real
work; on Windows there is no fast path, so every hook pays for a full
interpreter start and a 5000-line recompile. This measures that split, and three
specific suspicions, so an optimisation lands where the time is rather than
where it is assumed to be.

It touches nothing: an isolated AGENTBUS_HOME under the system temp directory,
never the live bus, and it starts no sessions.

Two traps this avoids, both paid for on a Windows 10 host on 2026-07-31:

  - piping to a native executable from PowerShell prepends a UTF-8 BOM, so
    payloads are fed as bytes through the subprocess API rather than a shell;
  - an embeddable Python's `._pth` file takes sys.path over completely, so
    PYTHONPATH is ignored and a "warm" import measured nothing. Paths are
    injected explicitly, and the cache is checked rather than assumed.
"""

import json
import os
import subprocess
import sys
import tempfile
import time

RUNS = int(os.environ.get("RUNS", "15"))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, "bin", "agentbus")
HOME = os.path.join(tempfile.mkdtemp(prefix="ab-perf-"), "bus")

PAYLOAD = json.dumps({
    "session_id": "perf-probe", "cwd": ROOT, "hook_event_name": "PreToolUse",
    "tool_name": "Bash", "tool_input": {"command": "echo hello"},
    "tool_use_id": "perf-1",
}).encode("utf-8")


def hooked_interpreter():
    """The interpreter the installed hooks actually run, when it can be read.

    Measuring with a different Python than the one Claude Code invokes is how a
    benchmark ends up describing a machine nobody is using."""
    try:
        cfg = json.load(open(os.path.join(ROOT, "hooks", "hooks.json")))
    except Exception:
        return None
    for entries in cfg.get("hooks", {}).values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                args = hook.get("args")
                cmd = hook.get("command") or ""
                if args and cmd and os.path.basename(cmd).lower().startswith("py"):
                    return cmd
                if cmd.lower().endswith(("python.exe", "python3.exe", "pythonw.exe")):
                    return cmd
    return None


def ms(fn, runs=None):
    runs = runs or RUNS
    fn()                                   # warm-up, discarded
    xs = []
    for _ in range(runs):
        t = time.perf_counter()
        fn()
        xs.append((time.perf_counter() - t) * 1000.0)
    xs.sort()
    return xs[len(xs) // 2]


def spawn(args, stdin=b"", env=None):
    e = dict(os.environ, AGENTBUS_HOME=HOME)
    if env:
        e.update(env)
    return lambda: subprocess.run(args, input=stdin, capture_output=True, env=e)


def row(label, value, note=""):
    print("  %-46s %8.1f ms  %s" % (label, value, note))


def setup_contended(py):
    """Two live sessions and a command the config guards — the path that costs.

    Everything else here measures a bus with nobody on it, where the engine
    returns at the live-count check having done nothing. That is the cheap case
    and not the one anybody notices."""
    repo = tempfile.mkdtemp(prefix="ab-perf-repo-")
    try:
        os.makedirs(os.path.join(repo, ".claude"))
        with open(os.path.join(repo, ".claude", "agent-bus.json"), "w") as fh:
            json.dump({"resources": [{"name": "db", "desc": "the database",
                                      "patterns": [r"\bpsql\b"]}]}, fh)
        env = dict(os.environ, AGENTBUS_HOME=HOME)
        for sid in ("perf-a", "perf-b"):
            e = dict(env, AGENTBUS_SESSION=sid, CLAUDE_CODE_SESSION_ID=sid)
            subprocess.run([py, ENGINE, "register"], cwd=repo,
                           capture_output=True, env=e)
        live = os.path.join(HOME, "live-count")
        if not os.path.exists(live) or open(live).read().strip() != "2":
            return 0.0
        payload = json.dumps({
            "session_id": "perf-a", "cwd": repo, "hook_event_name": "PreToolUse",
            "tool_name": "Bash", "tool_input": {"command": "psql -c 'select 1'"},
            "tool_use_id": "perf-guarded"}).encode("utf-8")
        # Give the claim back between runs, or every run after the first is
        # measuring "already yours" instead of taking a lock.
        def once():
            subprocess.run([py, ENGINE, "hook", "pre-tool"], input=payload,
                           capture_output=True, env=env)
            subprocess.run([py, ENGINE, "hook", "post-bash"],
                           input=json.dumps({
                               "session_id": "perf-a", "cwd": repo,
                               "hook_event_name": "PostToolUse",
                               "tool_use_id": "perf-guarded"}).encode("utf-8"),
                           capture_output=True, env=env)
        pair = ms(once)
        solo = ms(spawn([py, ENGINE, "hook", "post-bash"],
                        json.dumps({"session_id": "perf-a", "cwd": repo,
                                    "hook_event_name": "PostToolUse",
                                    "tool_use_id": "nothing"}).encode("utf-8")))
        return max(0.0, pair - solo)
    except Exception:
        return 0.0


def main():
    py = sys.argv[1] if len(sys.argv) > 1 else (hooked_interpreter() or sys.executable)
    same = os.path.normcase(py) == os.path.normcase(sys.executable)
    print("agent-bus — where a hook's time goes\n")
    print("  engine      : %s" % ENGINE)
    print("  interpreter : %s%s" % (py, "" if same else "   (the one the hooks use)"))
    print("  python      : %s" % sys.version.split()[0])
    print("  platform    : %s" % sys.platform)
    print("  runs        : %d (median)\n" % RUNS)
    if not os.path.exists(ENGINE):
        print("  ! no engine at that path — run this from inside the plugin tree")
        return 1

    print("PROCESS FLOOR — what any hook costs before agent-bus exists")
    bare = ms(spawn([py, "-c", "pass"]))
    row("bare interpreter start", bare)
    if os.name == "nt":
        row("cmd.exe start, for comparison", ms(spawn(["cmd", "/c", "exit"])),
            "a .cmd fast path could not beat this")

    print("\nTHE ENGINE, AS THE HOOKS RUN IT (a script: no bytecode cache)")
    off = ms(spawn([py, ENGINE, "hook", "pre-tool"], PAYLOAD, {"AGENTBUS_OFF": "1"}))
    row("earliest possible return (AGENTBUS_OFF=1)", off,
        "+%.0f ms over the floor" % (off - bare))
    full = ms(spawn([py, ENGINE, "hook", "pre-tool"], PAYLOAD))
    row("a PreToolUse, alone on the bus", full,
        "returns at the live-count check")

    # The path that actually matters: somebody else is live, and the command
    # touches something the repository declares. This is what a guarded call
    # costs, and it is the number to compare against a machine with a fast path.
    guarded = setup_contended(py)
    if guarded:
        row("a PreToolUse that takes a lock", guarded,
            "+%.0f ms of real work" % (guarded - off))
    else:
        guarded = full
        print("  ! could not set up the contended case; using the quiet number")

    print("\nWHERE THAT OVERHEAD SITS")
    src = open(ENGINE, "rb").read().decode("utf-8")
    comp = ms(spawn([py, "-c",
                     "import io;compile(io.open(%r,encoding='utf-8').read(),'e','exec')"
                     % ENGINE]))
    row("read + compile %d lines" % src.count("\n"), comp,
        "+%.0f ms over the floor" % (comp - bare))
    # __name__ is deliberately not "__main__", so main() does not run.
    ex = ms(spawn([py, "-c",
                   "import io;g={'__name__':'perf'};"
                   "exec(compile(io.open(%r,encoding='utf-8').read(),'e','exec'),g)"
                   % ENGINE]))
    row("... and its `import json, re` (NOT its own defs)", ex,
        "+%.0f ms over compiling" % (ex - comp))
    rest = off - ex
    row("... and everything else to the first return", max(0.0, rest),
        "ensure_dirs, argv, stdin")

    print("\nSUSPICION 1 — the recompile, because a script is never cached")
    pkg = tempfile.mkdtemp(prefix="ab-perf-mod-")
    mod = os.path.join(pkg, "abperfmod.py")
    with open(mod, "wb") as fh:
        fh.write(src.encode("utf-8"))
    warm = [py, "-c", "import sys;sys.path.insert(0,%r);import abperfmod" % pkg]
    subprocess.run(warm, capture_output=True)          # write the .pyc
    cached = os.path.isdir(os.path.join(pkg, "__pycache__"))
    if not cached:
        print("  ! no __pycache__ was written — this measurement is void")
        print("    (read-only temp dir, or PYTHONDONTWRITEBYTECODE is set)")
    else:
        as_mod = ms(spawn(warm))
        row("the same file imported, warm .pyc", as_mod)
        row("saved by caching the bytecode", ex - as_mod,
            "%.0f%% of a hook" % (100.0 * (ex - as_mod) / off if off else 0))

    print("\nSUSPICION 2 — ensure_dirs, which runs on every single invocation")
    import importlib.machinery
    import importlib.util
    os.environ["AGENTBUS_HOME"] = HOME
    loader = importlib.machinery.SourceFileLoader("abperf", ENGINE)
    spec = importlib.util.spec_from_loader("abperf", loader)
    ab = importlib.util.module_from_spec(spec)
    loader.exec_module(ab)
    ab.ensure_dirs()                                   # create them once
    mk = ms(lambda: ab.ensure_dirs(), 200) * 1000.0
    st = ms(lambda: os.path.isdir(ab.SESSIONS), 200) * 1000.0
    print("  %-46s %8.0f us  %s" % ("13 x makedirs, already present", mk,
                                    "every hook pays this"))
    print("  %-46s %8.0f us  %s" % ("one isdir, which could replace it", st,
                                    "%.0fx cheaper" % (mk / st if st else 0)))

    print("\nTHE PYTHON FAST PATH — what Windows now runs")
    gate = os.path.join(ROOT, "bin", "hook.py")
    if os.path.exists(gate):
        quiet = ms(spawn([py, gate, "pre-tool"], PAYLOAD))
        row("a hook with nothing to do", quiet,
            "%.0f ms saved against the engine" % (off - quiet))
        row("  ... its floor is the interpreter", bare, "so this is close to free")
    else:
        print("  ! no bin/hook.py in this copy")

    print("\nSUSPICION 3 — is there a shell fast path in front of it?")
    hook = os.path.join(ROOT, "bin", "ab-hook")
    wired = ""
    try:
        wired = open(os.path.join(ROOT, "hooks", "hooks.json")).read()
    except OSError:
        pass
    if "ab-hook" in wired and os.name != "nt":
        fast = ms(spawn([hook, "pre-tool"], PAYLOAD))
        row("the shell fast path, alone on the bus", fast,
            "%.0fx cheaper than waking the engine" % (off / fast if fast else 0))
    else:
        print("  %-46s %8s      %s"
              % ("none — hooks call Python directly", "-",
                 "so every hook pays the %.0f ms above" % off))

    print("\nWHAT A TURN COSTS, from these numbers")
    for label, batches, edits, bash in (("reading around", 5, 0, 0),
                                        ("a mixed turn", 6, 2, 2),
                                        ("heavy implementation", 15, 10, 8)):
        # Pre+Post per guarded tool, one PostToolBatch per batch, one prompt hook.
        total = (batches * full + (edits + bash) * 2 * guarded + full) / 1000.0
        print("  %-46s %8.1f s   %d batches, %d edits, %d bash"
              % (label, total, batches, edits, bash))
    print("\n  (Upper bound: hooks for tools in one batch run concurrently, and a")
    print("   PreToolUse whose command matches nothing returns sooner than this.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
