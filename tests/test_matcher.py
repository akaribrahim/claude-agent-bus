#!/usr/bin/env python3
"""Which resources a command touches — and the pre-filter invariant.

Three separate things are asserted here, and the last two are the ones that
break silently in production.

1. `resources_for` must claim exactly the resources a command genuinely acts
   on. A commit message, a pull-request body or a heredoc that happens to name
   a tool is text the command is carrying, not a service it is using; treating
   it as a use blocks the commit and teaches the agent that the bus is wrong.

2. Anything the engine would guard must also match the literal pre-filter that
   the shell fast path derives from the same patterns. The fast path exits
   before waking the engine when nothing matches, so a guard the pre-filter
   cannot see never fires at all — silently, looking exactly like a resource
   nobody is contending for. That is what `git add -A` did until commit
   768f183. The check is run through bash's own `[[ =~ ]]`, not just Python's
   `re`, because bash is what actually makes the decision.

3. The second gate, added in 2.12.0, and the same invariant one step further
   in. Both fast paths now also decline to wake the engine for a command every
   segment of which the engine would skip as read-only — so the pre-filter is no
   longer the only thing standing between a guard and never firing. That gate is
   held to the same one-directional rule: whatever it skips, the engine must
   find nothing in. Asked of the real `bin/ab-hook` and `bin/hook.py` against a
   stand-in engine that records being woken, so what is measured is the decision
   a session's tool call would get and not a description of it.

The engine has no `.py` extension, so it is loaded by path.
"""

import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.environ.get("AB_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
TMP = os.environ.get("TEST_TMP") or "/tmp"

PASSES = os.path.join(TMP, ".passes")
FAILURES = os.path.join(TMP, ".failures")


def record(path, label):
    with open(path, "a") as fh:
        fh.write(label + "\n")


def ok(label):
    record(PASSES, label)
    if os.environ.get("VERBOSE"):
        print("    ok   %s" % label)


def bad(label, detail=""):
    record(FAILURES, label)
    print("    FAIL %s" % label)
    if detail:
        for line in str(detail).split("\n"):
            print("         %s" % line)


def eq(expected, actual, label):
    if expected == actual:
        ok(label)
    else:
        bad(label, "expected: %r\nactual:   %r" % (expected, actual))


def load_by_path(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def load_engine():
    return load_by_path("agentbus_engine", os.path.join(ROOT, "bin", "agentbus"))


# A config shaped like the ones real repositories end up with: one service the
# plugin owns, one plain mutex, one runner that implies the service, and the
# universal per-checkout resource.
CFG = {
    "resources": [
        {"name": "server", "desc": "the dev API on :8099", "port": 8099,
         "start": "uvicorn app:api --reload --port 8099",
         "patterns": [r"\buvicorn\b", r":8099\b"]},
        {"name": "db", "desc": "the shared development database",
         "patterns": [r"\balembic\b", r"\bpsql\b", r"\bprisma\s+migrate\b",
                      r"\bmake\s+seed"]},
        {"name": "e2e", "desc": "the end-to-end runner", "implies": ["server"],
         "patterns": [r"\bplaywright\b", r"\bmaestro\b"]},
        {"name": "worktree", "desc": "this checkout's tree and index",
         "scope": "worktree",
         "patterns": [r"\bgit\s+(checkout|switch|stash|reset|rebase|add|commit)\b",
                      r"\b(npm|pnpm|yarn|bun)\s+(install|ci)\b"]},
    ],
}

HEREDOC = """gh pr create --body-file - <<'EOF'
While reviewing this I had to restart uvicorn on :8099 twice.
EOF"""

# (command, the resources it must claim, what the case is about)
CASES = [
    ("curl -sf http://localhost:8099/health", {"server"},
     "a request to a declared port claims the service"),
    ('curl -sf "http://localhost:8099/health"', {"server"},
     "quoting the URL does not hide the port"),
    ("bash -c 'uvicorn app:api --reload --port 8099'", {"server"},
     "bash -c recurses into its argument"),
    ("uvicorn app:api --reload --port 8099", {"server"},
     "starting the service claims it"),

    ('git commit -m "restart uvicorn on :8099 before testing"', {"worktree"},
     "a commit message naming a service does not claim that service"),
    ('gh pr create --title "notes" --body "we restart uvicorn on :8099 here"',
     set(), "a pull-request body naming a service claims nothing"),
    (HEREDOC, set(), "a heredoc body naming a service claims nothing"),
    ("grep -rn uvicorn api/", set(),
     "reading about a service is not using it"),
    ("rg ':8099' --files-with-matches", set(),
     "searching for a port is not reaching it"),

    ("git status", set(), "git status claims nothing"),
    ("git log --oneline -20", set(), "git log claims nothing"),
    ("git stash", {"worktree"}, "git stash claims the checkout"),
    ("git add -A", {"worktree"}, "git add -A claims the checkout"),
    ("git checkout -b feature/x", {"worktree"},
     "git checkout claims the checkout"),
    ("npm install", {"worktree"}, "npm install claims the checkout"),
    ("bun install --frozen-lockfile", {"worktree"},
     "bun install claims the checkout"),

    ("alembic upgrade head", {"db"}, "a migration claims the database"),
    ("make seed", {"db"}, "a reseed claims the database"),
    ("npx playwright test", {"e2e", "server"},
     "the e2e runner pulls in the server it is only meaningful against"),

    ("ls -la && echo done", set(), "ordinary work claims nothing"),
    ('agentbus post "uvicorn on :8099 is mine for ten minutes"', set(),
     "talking about a service on the bus does not claim it"),
]


# The second fixture, for the superset invariant below. Between them the four
# resources exercise every feature that can change what `resources_for`
# matches: an `unless` that takes a resource away again, an `implies` that adds
# one nothing in the command named, a `key` that splits one resource into
# several, and `_explicit` — a resource named outright on an `agentbus` command
# line, where none of the patterns' own literals appear anywhere in the payload.
SUPERSET = {
    "resources": [
        {"name": "db", "desc": "the shared development database",
         "patterns": [r"\bpsql\b", r"\balembic\b"],
         # A `db` describing the local Postgres matches every psql there is,
         # including one aimed at a staging server in another country.
         "unless": [r"staging\.example", r"--host\s+\S*staging"]},
        {"name": "bundler", "desc": "the bundler", "patterns": [r"\bmetro\b"]},
        {"name": "simulator", "desc": "one of the simulators on this machine",
         "key": r"--udid\s+(\S+)", "implies": ["bundler"],
         "patterns": [r"\bmaestro\b", r"\bxcrun\s+simctl\b"]},
        {"name": "worktree", "desc": "this checkout's tree and index",
         "scope": "worktree",
         "patterns": [r"\bgit\s+(add|commit|stash)\b"]},
    ],
}

# (command, what the case is about). Every one of these must be matched by
# `resources_for`, which is asserted here rather than assumed — a case that
# stopped matching would otherwise satisfy the superset invariant vacuously.
SUPERSET_CASES = [
    ("psql -c 'select 1'", "a plain pattern"),
    ("alembic upgrade head", "the second pattern of a resource, not the first"),
    ("maestro --udid ABC123 test a.yaml", "a command naming one instance"),
    ("maestro test a.yaml", "and one naming none"),
    ("xcrun simctl list devices", "a two-word pattern"),
    ("git add -A", "a pattern whose literal is outside its alternation"),
    ("git stash", "and another branch of the same alternation"),
    # The `_explicit` case, and the one that has no pattern literal in it at
    # all: `metro` appears nowhere in this line. Only the `agentbus` token
    # carries it, which is why `guard_token_line` adds one.
    ("agentbus serve bundler", "a resource named outright on an agentbus line"),
    ("agentbus run simulator -- ./flows.sh", "and one named on a run line"),
]


def prefilter(mod, cfg=None):
    """The exact string refresh_derived() writes to guard-tokens.

    Asked of the engine rather than rebuilt here. A test that reconstructs the
    thing it is checking is the same defect it exists to catch, one level up —
    and this one demonstrated it: the reconstruction left out the `agentbus`
    token, so every `_explicit` case below would have failed against a
    pre-filter that is in fact correct."""
    return mod.guard_token_line([cfg or CFG])


def superset(mod, alt, cmd, label):
    """Whatever the engine would guard, the pre-filter must see first."""
    if not re.search(alt, cmd, re.I):
        return bad("the pre-filter is a superset: %s" % label,
                   "guard-tokens /%s/ does not match:\n%s" % (alt, cmd))
    if not bash_matches(alt, cmd):
        return bad("the pre-filter is a superset: %s" % label,
                   "python matched but bash did not — the fast path would exit "
                   "before waking the engine:\n%s" % cmd)
    ok("the pre-filter is a superset: %s" % label)


def bash_matches(alternation, text):
    """Ask bash the same question bin/ab-hook asks it."""
    script = 'shopt -s nocasematch; [[ "$2" =~ $1 ]]'
    res = subprocess.run(["bash", "-c", script, "prefilter", alternation, text])
    return res.returncode == 0


# =============================================================================
# The read-only gate: three copies of one decision, and what it may skip
# =============================================================================
#
# `is_readonly` skips a segment whose head only reads, so `command_targets`
# yields nothing for a command made of nothing else, and the engine starts up to
# find nothing. Both fast paths now answer that case themselves — which means the
# lists live in three languages, and a head in one and not another is a class of
# command nothing guards, failing exactly the way a dropped pre-filter token
# does.

# (command, must the fast paths wake the engine, what the case is about)
#
# Both columns matter. The wake column keeps the table from going vacuous: a
# rule that skipped nothing would satisfy the invariant below perfectly and save
# nothing, and a rule that skipped everything would fail the wake cases loudly
# rather than silently guarding nothing.
FASTPATH_CASES = [
    ("git status --short", False, "git status"),
    ("git log --oneline -1", False, "git log"),
    ("git -C /elsewhere/checkout worktree list", False,
     "a reading subcommand behind a global option"),
    ("git diff HEAD~1", False, "git diff"),
    ("ls -la && echo done", False, "a compound command every segment of which reads"),
    ("ps ax", False, "asking what is running"),
    ("lsof -i :8099", False, "a declared port inside a read-only command"),
    ("grep -rn maestro flows/", False, "reading about a tool"),
    ("sudo lsof -i", False, "a wrapper stripped before the head is read"),
    ("env FOO=1 git log", False, "an assignment behind a wrapper, both stripped"),
    ("cat package.json > /tmp/copy.json", False, "a redirect, which the engine also ignores"),

    ("git add -A", True, "git add, which rewrites the index"),
    ("git stash", True, "git stash"),
    ("git checkout -b topic/x", True, "git checkout"),
    ("git -C /elsewhere/checkout add -A", True,
     "a writing subcommand behind the same global option"),
    ("git", True, "git with no subcommand to judge"),
    ("npm install", True, "an install"),
    ("alembic upgrade head", True, "a migration"),
    ("maestro test flows/checkout.yaml", True, "a runner"),
    ("git status && npm install", True,
     "a compound command only part of which reads"),
    ("ls; kill -9 4242", True, "kill, whatever it is standing next to"),
    ("pkill -f metro", True, "and pkill, which the engine also refuses to call reading"),
    ("bash -c npm", True, "a shell whose argument is a command"),
    ("a-b=c ls", True, "a word that only looks like an assignment"),
    # The two shapes that must not be read out of the payload with a scan. Both
    # are read-only commands and both must wake the engine anyway, because the
    # value JSON wrote for them cannot be split without unescaping it first.
    ('grep -rn "maestro" flows/', True,
     "a read-only command JSON had to escape"),
    ("git status\ngit add -A", True,
     "and one whose second line is not read-only at all"),
    # The trap. `agentbus` IS in the engine's read-only list — it reads and
    # writes the bus, never the repository — and it reaches a decision by two
    # routes that do not go through `command_targets` at all.
    ("agentbus serve bundler", True,
     "an agentbus line, which names its resource outright"),
    ("agentbus done", True,
     "and one that only leaves the party hint the CLI reads next"),
]


def ab_hook_lists():
    """The two lists `bin/ab-hook` carries, read out of the file as data.

    Not sourced: that file is a hook, and sourcing it runs it. Read as text
    instead, which is also the honest thing to compare — what is committed there
    is what every tool call in every session on this machine will use."""
    text = open(os.path.join(ROOT, "bin", "ab-hook")).read()
    out = {}
    for name in ("RO_HEADS", "RO_GIT"):
        m = re.search(r'^%s="\|(.*)\|"$' % name, text, re.M)
        out[name] = set(m.group(1).split("|")) if m else None
    return out


def stand_in_engine(where):
    """A copy of both fast paths beside an engine that records being woken.

    The stand-in is a Python file that is also an executable script, because the
    two entry points reach the engine two different ways — `bin/ab-hook` execs
    it, `bin/hook.py` imports it — and which of them was reached is the whole
    measurement."""
    os.makedirs(where, exist_ok=True)
    for name in ("ab-hook", "hook.py"):
        shutil.copy(os.path.join(ROOT, "bin", name), os.path.join(where, name))
    engine = os.path.join(where, "agentbus")
    with open(engine, "w") as fh:
        fh.write('#!/usr/bin/env python3\n'
                 'import os, sys\n'
                 'def _note(event):\n'
                 '    p = os.environ.get("FASTPATH_LOG")\n'
                 '    if p:\n'
                 '        open(p, "a").write((event or "?") + "\\n")\n'
                 'def ensure_dirs():\n'
                 '    pass\n'
                 'def run_hook(event, raw):\n'
                 '    _note(event)\n'
                 'if __name__ == "__main__":\n'
                 '    _note(sys.argv[2] if len(sys.argv) > 2 else "")\n')
    os.chmod(engine, 0o755)
    return where


def fastpath_bus(where):
    """A bus the pre-tool gate gets all the way through.

    Two live sessions and the catch-all pre-filter, so the only thing left that
    can stop either entry point short is the read-only rule this section is
    about. The catch-all is the right setting for that and not a convenience:
    a resource with no mandatory literal opens the token gate for every command
    there is, and the read-only rule still has to be safe underneath it."""
    for d in ("acted", "cursors", "sessions", "hot-for", "autoclaim"):
        os.makedirs(os.path.join(where, d), exist_ok=True)
    open(os.path.join(where, "live-count"), "w").write("2\n")
    open(os.path.join(where, "guard-tokens"), "w").write(".\n")
    return where


def woke(fast, bus, log, entry, cmd):
    """Did that entry point start the engine for this command?"""
    payload = json.dumps({
        "session_id": "matcher-a", "cwd": ROOT, "hook_event_name": "PreToolUse",
        "tool_name": "Bash", "tool_input": {"command": cmd},
        "tool_use_id": "matcher-1"}).encode("utf-8")
    if os.path.exists(log):
        os.unlink(log)
    env = dict(os.environ, AGENTBUS_HOME=bus, FASTPATH_LOG=log)
    argv = (["bash", os.path.join(fast, "ab-hook"), "pre-tool"] if entry == "sh"
            else [sys.executable, os.path.join(fast, "hook.py"), "pre-tool"])
    subprocess.run(argv, input=payload, capture_output=True, env=env)
    return os.path.exists(log)


def hints_left(mod, cmd):
    """The party hints `leave_party_hint` would record for this command.

    Asked by running it, into this file's own isolated bus, rather than by
    restating its rule here — a test that reimplements what it is checking is
    the defect it exists to catch, one level up. This is the route that makes
    `agentbus` unskippable although the engine calls it read-only."""
    mod.ensure_dirs()
    for name in os.listdir(mod.HINTS):
        os.unlink(os.path.join(mod.HINTS, name))
    mod.leave_party_hint({"sid": "matcher", "agent": "matcher"}, cmd)
    return sorted(os.listdir(mod.HINTS))


def engine_would_find(mod, cmd, cfg):
    """Everything `hook_pre_tool` has to say about one Bash command, or {}.

    Three routes reach a decision and they are not the same route.
    `command_targets` is what every pattern sees and what `wrong_port_check`
    reads its ports out of; `explicit_resources` is what an `agentbus` line
    names outright; `leave_party_hint` is the record the CLI process a few
    milliseconds later has no other way of obtaining. A fast path that stops
    short has to be right about all three, so all three are asked."""
    found = {}
    targets = mod.command_targets(cmd)
    if targets:
        found["targets"] = targets
    named = [r["name"] for r in mod.explicit_resources(cmd, cfg)]
    if named:
        found["explicit"] = named
    hints = hints_left(mod, cmd)
    if hints:
        found["hint"] = hints
    return found


def check_readonly_gate(mod):
    sh = ab_hook_lists()
    gate = load_by_path("agentbus_pyhook", os.path.join(ROOT, "bin", "hook.py"))

    # ---- one decision, three copies of it -----------------------------------
    eq(mod.FASTPATH_SKIP_HEADS, sh["RO_HEADS"],
       "the shell fast path skips exactly the heads the engine says it may")
    eq(mod.FASTPATH_SKIP_HEADS, set(gate.RO_HEADS),
       "and so does the Python one")
    eq(mod.GIT_READONLY_SUBCOMMANDS, sh["RO_GIT"],
       "the shell fast path's reading git subcommands are the engine's")
    eq(mod.GIT_READONLY_SUBCOMMANDS, set(gate.RO_GIT),
       "and so are the Python one's")
    eq(mod.WRAPPERS, set(gate.RO_WRAPPERS),
       "and the wrappers stripped before a head is read")

    # The narrowing itself, stated as the two directions it can be wrong in. A
    # head a fast path skips and the engine does not is a command class nothing
    # guards; a head the engine holds back and a fast path does not is the same
    # thing by another door, which is exactly what `agentbus` would have been.
    eq(set(), mod.FASTPATH_SKIP_HEADS - mod.READONLY_HEADS,
       "nothing a fast path skips is outside the engine's own read-only list")
    eq({"agentbus"}, mod.READONLY_HEADS - mod.FASTPATH_SKIP_HEADS,
       "and the one read-only head held back is the one that reaches the guard "
       "another way")

    # ---- and the invariant, through the real entry points --------------------
    fast = stand_in_engine(os.path.join(TMP, "ro-fastpath"))
    bus = fastpath_bus(os.path.join(TMP, "ro-bus"))
    log = os.path.join(TMP, "ro-woke.log")
    for cmd, must_wake, label in FASTPATH_CASES:
        a = woke(fast, bus, log, "sh", cmd)
        b = woke(fast, bus, log, "py", cmd)
        eq(a, b, "both fast paths agree about waking: %s" % label)
        eq(must_wake, a, "the engine is %s for %s"
           % ("woken" if must_wake else "left alone", label))
        if a or b:
            continue
        # The one-directional rule, and the only one that fails silently: a
        # command skipped here never reaches any guard, so if the engine would
        # have found anything at all in it, nothing guards that shape of command
        # and it looks exactly like a resource nobody is contending for.
        eq({}, engine_would_find(mod, cmd, SUPERSET),
           "and the engine would have found nothing in it: %s" % label)


def main():
    mod = load_engine()

    for cmd, expected, label in CASES:
        got = {r["name"] for r in mod.resources_for(cmd, CFG)}
        eq(expected, got, label)

    alt = prefilter(mod)
    label = "the pre-filter is a real filter, not the catch-all '.'"
    if alt in (".", ""):
        bad(label, "every pattern in this fixture has a mandatory literal, so "
                   "the fast path should be filtering on them; got %r" % alt)
    else:
        ok(label)

    for cmd, expected, label in CASES:
        if not expected:
            continue
        superset(mod, alt, cmd, label)

    # The invariant itself, over a configuration that uses every feature able
    # to change what `resources_for` answers. The two questions are asked
    # independently and in that order: what does the engine guard, and would
    # the fast path ever have let the engine be asked?
    #
    # This is the check that fails silently in production. Both fast paths exit
    # before starting the engine when nothing here matches, so a dropped token
    # is a guard that never fires — indistinguishable, from the outside, from a
    # resource nobody is contending for. It broke once already, in 768f183, and
    # every other assertion in this suite calls the engine directly and would
    # have gone on passing.
    alt = prefilter(mod, SUPERSET)
    for cmd, label in SUPERSET_CASES:
        hit = {r["name"] for r in mod.resources_for(cmd, SUPERSET)}
        if not hit:
            bad("the pre-filter is a superset: %s" % label,
                "nothing to be a superset OF — `resources_for` matches nothing "
                "in:\n%s" % cmd)
            continue
        superset(mod, alt, cmd, label)

    # And the exclusion, so that the fixture is not simply matching everything:
    # `unless` takes the resource away again, and this is the shape that does
    # it. A superset may of course still contain it — `psql` is in the token
    # line either way — so what is asserted here is only that the engine's own
    # answer is empty.
    eq(set(), {r["name"] for r in mod.resources_for(
        "psql --host db.staging.example -c 'select 1'", SUPERSET)},
       "a command an `unless` excludes claims nothing")

    # The regression itself, stated directly: the literal chosen for a pattern
    # whose distinguishing words live inside an alternation must cover every
    # branch, not just the longest run anywhere in the pattern.
    toks = mod.pattern_tokens(r"\bgit\s+(checkout|switch|stash|reset|rebase|add|commit)\b")
    eq({"git"}, toks, "a pattern with a literal outside its groups filters on it")
    toks = mod.pattern_tokens(r"\b(npm|pnpm|yarn|bun)\s+(install|ci)\b")
    eq({"npm", "pnpm", "yarn", "bun"}, toks,
       "a pattern with nothing outside its groups filters on every branch")
    eq(set(), mod.pattern_tokens(r"\b\w+\b"),
       "a pattern with no literal at all reports that it cannot be filtered")

    check_readonly_gate(mod)

    return 1 if os.path.exists(FAILURES) and os.path.getsize(FAILURES) else 0


if __name__ == "__main__":
    sys.exit(main())
