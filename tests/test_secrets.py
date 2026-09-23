#!/usr/bin/env python3
"""What `redact` masks before anything reaches the log, a lock or a block.

The bus records commands, and a command line is where passwords are typed. By
2026-09-22 the log on the machine this was written on held 127 events carrying
one, 36 of them in announcements delivered into other sessions' contexts.

Both directions are pinned, and the second matters as much as the first: a
masker that eats `MAX_TOKENS=4096` or a port in a URL hides the part of an
event somebody reads it for. Every "left alone" case below is one a looser
pattern would match.

The engine has no `.py` extension, so it is loaded by path.
"""

import importlib.machinery
import importlib.util
import os
import sys

ROOT = os.environ.get("AB_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
TMP = os.environ.get("TEST_TMP") or "/tmp"

PASSES = os.path.join(TMP, ".passes")
FAILURES = os.path.join(TMP, ".failures")


def record(path, label):
    with open(path, "a", encoding="utf-8") as fh:
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
    loader = importlib.machinery.SourceFileLoader(
        "agentbus_engine", os.path.join(ROOT, "bin", "agentbus"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


MASKED = [
    # The two shapes the log actually held.
    ("psql postgresql://postgres:***@localhost:5432/app -c 'select 1'",
     "psql postgresql://postgres:hunter2@localhost:5432/app -c 'select 1'",
     "a password inside a URL, and only the password"),
    ("export PGPASSWORD=*** && psql -h 127.0.0.1",
     "export PGPASSWORD=hunter2 && psql -h 127.0.0.1",
     "an environment variable whose name says it is a password"),
    ('curl -H "Authorization: Bearer ***" localhost:8000',
     'curl -H "Authorization: Bearer abc123token" localhost:8000',
     "a bearer token in a header"),
    # The rest of the family.
    ('PGPASSWORD=*** psql', 'PGPASSWORD="two words" psql',
     "a quoted value is masked whole, not up to its first space"),
    ("SERVICE_TOKEN=*** SECRET_KEY_BASE=*** DB=app",
     "SERVICE_TOKEN=abc123 SECRET_KEY_BASE=abc DB=app",
     "several on one line, and the name that is not a secret's is left"),
    ("GET /api?api_key=***&page=2", "GET /api?api_key=xyz&page=2",
     "a query parameter stops at the next one"),
    ("--password *** --user app", "--password hunter2 --user app",
     "a password flag and its separate value"),
    ("--api-key=***", "--api-key=sk-ant-abcdefghijklmnopqrstu",
     "a key flag with its value attached"),
    ("curl -H 'authorization: token ***'", "curl -H 'authorization: token abc123'",
     "a header in lower case with another scheme"),
    ("using *** now", "using ghp_abcdefghijklmnopqrstuvwxyz0123 now",
     "a GitHub token recognised by its shape"),
    ("key ***", "key AKIAABCDEFGHIJKLMNOP", "an AWS access key id"),
    # A merchant key and an authorization value were pasted into a message on
    # 2026-09-20, and 3.0.1 caught neither: it knew `API_KEY`, not `_KEY`, and
    # looked for `Authorization:` with a colon.
    ("PAYMENT_MERCHANT_KEY=*** PAYMENT_ACK=OK",
     "PAYMENT_MERCHANT_KEY=abc123 PAYMENT_ACK=OK",
     "a name whose last word is KEY"),
    ("PAYMENT_AUTHORIZATION=***\nNEXT=1",
     "PAYMENT_AUTHORIZATION=Basic dGVzdGluZy10ZXN0aW5nLXRlc3Rpbmc=\nNEXT=1",
     "an authorization value, both its scheme and its credential"),
    ("GET /maps?key=***&q=x", "GET /maps?key=abc123&q=x",
     "a bare `key` query parameter"),
    ("jwt ***",
     "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w",
     "a JWT"),
]

LEFT_ALONE = [
    ("MAX_TOKENS=4096", "a name containing TOKENS is a count, not a token"),
    ("tokenizer=bpe", "nor is one that merely starts with token"),
    ("monkey=1 hotkey=f5 KEYBOARD=us", "KEY inside a longer word"),
    ("author=me AUTHOR_NAME=x", "AUTH as the start of another word"),
    ("sorted(names, key=len)", "a Python keyword argument called key"),
    ("GIT_CONFIG_KEY_0=safe.directory KEY_CFG=x", "KEY that is not the last word"),
    ("SSH_AUTH_SOCK=/tmp/agent.sock", "AUTH that is not the last word"),
    ("bypass=1", "`pass` alone is not a password's name"),
    ("PWD=/tmp/x", "PWD is the working directory"),
    ("--token-file ./token", "a flag that names a file holding the secret"),
    ("https://localhost:8080/path@x", "a port is not a password"),
    ("ssh://git@host:22/repo", "a user with no password"),
    ("git@github.com:org/repo.git", "an scp-style remote"),
    ("redis://localhost:6379/0", "a URL with no credentials at all"),
    ("Basic checks passed", "the word Basic in a sentence"),
    ("the token expired an hour ago", "a sentence about a token"),
    ("sk-short", "a prefix too short to be a key"),
    ("", "an empty text"),
]


def main():
    mod = load_engine()

    for expected, given, label in MASKED:
        eq(expected, mod.redact(given), "masked: " + label)
    for given, label in LEFT_ALONE:
        eq(given, mod.redact(given), "left alone: " + label)

    # Masking a masked text changes nothing, so a reason redacted when a lock
    # was taken and again when the lock event is emitted reads the same.
    once = mod.redact(MASKED[1][1])
    eq(once, mod.redact(once), "redacting twice is redacting once")

    # The order that makes truncation safe: 120 characters of this command end
    # inside the password, where the `@` that marks it has already been cut.
    cmd = "psql " + "x" * 81 + " postgresql://postgres:hunter2hunter2@localhost/app"
    eq(False, "hunter2" in mod.redact(cmd)[:120],
       "masked first and cut second, a cut through a password leaks none of it")
    eq(True, "hunter2" in cmd[:120] and "@" not in cmd[:120],
       "(and cut first, it would have: the fixture does cut through it)")

    # ---- the commit gate reads the same table ---------------------------------
    #
    # `tests/check_secrets.py` runs as the pre-commit and commit-msg hooks and
    # in this suite. What it must catch is pinned here, through its `scan`, so a
    # gate that quietly stopped finding anything fails by name.
    loader = importlib.machinery.SourceFileLoader(
        "check_secrets", os.path.join(ROOT, "tests", "check_secrets.py"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    gate = importlib.util.module_from_spec(spec)
    loader.exec_module(gate)

    # Assembled at run time: written out whole, it would be a finding in this
    # very file the moment the gate scanned the repository.
    real = "real" + "value1"
    found = []
    gate.scan(mod, None, "fixture.sh",
              "ok\nexport PGPASS" + "WORD=" + real + " && psql\n", found)
    eq(1, len(found), "the gate finds a real-looking value")
    eq(True, found and found[0].startswith("fixture.sh:2: a secret (PGPASSWORD=)"),
       "and says where it is and what it was")
    eq(True, found and real not in found[0],
       "without printing the value it found")

    found = []
    gate.scan(mod, None, "fixture.sh", "export PGPASSWORD=hunter2 && psql", found)
    eq([], found, "a value listed as a fake passes")

    found = []
    gate.scan(mod, ["acme-internal"], "msg", "Fix\n\nseen in ACME-Internal/x\n",
              found)
    eq(["msg:3: entry 1 of notes/never-publish.txt"], found,
       "a never-publish string is found case-blind, and not echoed")

    return 1 if os.path.exists(FAILURES) and os.path.getsize(FAILURES) else 0


if __name__ == "__main__":
    sys.exit(main())
