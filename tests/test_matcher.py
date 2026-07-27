#!/usr/bin/env python3
"""Which resources a command touches — and the pre-filter invariant.

Two separate things are asserted here, and the second is the one that has
already broken once in production.

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

The engine has no `.py` extension, so it is loaded by path.
"""

import importlib.machinery
import importlib.util
import os
import re
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


def load_engine():
    path = os.path.join(ROOT, "bin", "agentbus")
    loader = importlib.machinery.SourceFileLoader("agentbus_engine", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


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


def prefilter(mod):
    """The exact string refresh_derived() writes to guard-tokens."""
    tokens, unfilterable = set(), False
    for res in CFG["resources"]:
        if not res.get("patterns"):
            continue
        toks = mod.resource_tokens(res)
        if not toks:
            unfilterable = True
            continue
        for tok in toks:
            tokens.add(re.escape(tok))
    if unfilterable:
        return "."
    return "|".join(sorted(tokens)) if tokens else ""


def bash_matches(alternation, text):
    """Ask bash the same question bin/ab-hook asks it."""
    script = 'shopt -s nocasematch; [[ "$2" =~ $1 ]]'
    res = subprocess.run(["bash", "-c", script, "prefilter", alternation, text])
    return res.returncode == 0


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
        if not re.search(alt, cmd, re.I):
            bad("pre-filter sees: %s" % label,
                "guard-tokens /%s/ does not match:\n%s" % (alt, cmd))
        elif not bash_matches(alt, cmd):
            bad("pre-filter sees: %s" % label,
                "python matched but bash did not — the fast path would exit "
                "before waking the engine:\n%s" % cmd)
        else:
            ok("pre-filter sees: %s" % label)

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

    return 1 if os.path.exists(FAILURES) and os.path.getsize(FAILURES) else 0


if __name__ == "__main__":
    sys.exit(main())
