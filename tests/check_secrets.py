#!/usr/bin/env python3
"""The gate that keeps a secret, or the private repository's name, out of git.

This repository is public, and it is developed against a private one by agents
reading that one's logs and transcripts. Both halves of what this checks have
already happened: on 2026-07-30 the private repository's name was found in 20
of 24 public commits, and on 2026-09-23 it was in four unpublished commits
again, and a test fixture was written with the real development password, port
and bearer value copied out of the log. The scan before a push caught those,
but only because somebody remembered to run it.

  check_secrets.py                  every tracked file    (the suite, and CI)
  check_secrets.py --staged         what is being committed  (pre-commit hook)
  check_secrets.py --message FILE   a commit message         (commit-msg hook)

Two kinds of finding:

  A secret, by the engine's own `SECRETS` table — the one that masks the event
  log, so the two cannot drift apart — unless the value is one of the fakes in
  `FAKES` below, which are the fixtures that test that table.

  A string from `notes/never-publish.txt`, one per line: the private
  repository's name, its worktree and branch names, chat names that describe
  its features, development credentials. That file is gitignored on purpose,
  because the list is itself what must not be published. Where it is absent —
  CI, a fresh clone — this half is skipped and says so.

A finding prints the file, the line and what matched, with the line masked;
never the value or the listed string. `ok <what>` per clean check, as
`check_syntax.py` does.
"""

import importlib.machinery
import importlib.util
import os
import subprocess
import sys

ROOT = os.environ.get("AB_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
NEVER_PUBLISH = os.path.join(ROOT, "notes", "never-publish.txt")

# Values that are allowed to look like secrets, because they are made up. Each
# is here for a fixture or a docstring example; a real value must never be.
FAKES = {
    "hunter2", "hunter2hunter2", "s3cret", "abc123", "abc123token", "abc",
    "xyz", "two words", "PASSWORD", "VALUE",
    "sk-ant-abcdefghijklmnopqrstu",
    "ghp_abcdefghijklmnopqrstuvwxyz0123",
    "AKIAABCDEFGHIJKLMNOP",
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w",
    "Basic dGVzdGluZy10ZXN0aW5nLXRlc3Rpbmc=",
}


def load_engine():
    loader = importlib.machinery.SourceFileLoader(
        "agentbus_engine", os.path.join(ROOT, "bin", "agentbus"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def never_publish():
    try:
        with open(NEVER_PUBLISH, encoding="utf-8") as fh:
            return [l.strip().lower() for l in fh
                    if l.strip() and not l.lstrip().startswith("#")]
    except OSError:
        return None


def git(*args):
    return subprocess.run(["git", "-C", ROOT] + list(args),
                          capture_output=True).stdout


def secrets_in(engine, text):
    """(name, masked line) for each thing in `text` the table calls a secret."""
    for pattern, _ in engine.SECRETS:
        for m in pattern.finditer(text):
            label = m.group(1) if pattern.groups and m.group(1) else ""
            value = m.group(0)[len(label):].strip("\"'").rstrip(".,;:)`")
            if value in FAKES or len(value) < 4 or value.startswith(("$", "<", "*")):
                continue
            yield (label.strip() or "a token by its shape"), m.start()


def scan(engine, listed, where, text, found):
    lines = text.split("\n")
    starts, pos = [], 0
    for line in lines:
        starts.append(pos)
        pos += len(line) + 1

    def line_at(offset):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo

    for name, offset in secrets_in(engine, text):
        n = line_at(offset)
        found.append("%s:%d: a secret (%s): %s"
                     % (where, n + 1, name, engine.redact(lines[n]).strip()[:120]))
    if listed:
        low = [l.lower() for l in lines]
        for i, entry in enumerate(listed):
            for n, line in enumerate(low):
                if entry in line:
                    found.append("%s:%d: entry %d of notes/never-publish.txt"
                                 % (where, n + 1, i + 1))


def tracked():
    for path in git("ls-files", "-z").split(b"\0"):
        if path:
            yield path.decode("utf-8", "replace"), os.path.join(
                ROOT, path.decode("utf-8", "replace"))


def main(argv):
    engine = load_engine()
    listed = never_publish()
    found = []
    if "--message" in argv:
        path = argv[argv.index("--message") + 1]
        with open(path, encoding="utf-8", errors="replace") as fh:
            # Git's own comment lines are the template, not the message.
            text = "\n".join(l for l in fh.read().split("\n")
                             if not l.startswith("#"))
        scan(engine, listed, "commit message", text, found)
        what = "commit message"
    elif "--staged" in argv:
        names = git("diff", "--cached", "--name-only", "-z",
                    "--diff-filter=ACMR").split(b"\0")
        for raw in names:
            if not raw:
                continue
            name = raw.decode("utf-8", "replace")
            data = git("show", ":" + name)
            if b"\0" in data:
                continue
            scan(engine, listed, name, data.decode("utf-8", "replace"), found)
        what = "staged files"
    else:
        for name, path in tracked():
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if b"\0" in data:
                continue
            scan(engine, listed, name, data.decode("utf-8", "replace"), found)
        what = "tracked files"

    if found:
        print("FAIL %s: %d finding%s" % (what, len(found),
                                         "" if len(found) == 1 else "s"))
        for f in found:
            print("  " + f)
        print("\nMask it, or replace it with a made-up value. A fake that "
              "a fixture needs goes in FAKES in tests/check_secrets.py.")
        return 1
    print("ok no secrets in %s" % what)
    if listed is None:
        print("ok private names not checked: no notes/never-publish.txt here")
    else:
        print("ok none of the %d never-publish entries in %s"
              % (len(listed), what))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
