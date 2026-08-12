#!/usr/bin/env bash
# What the bus writes is what the bus reads, on a machine whose locale is not
# UTF-8.
#
# Python picks the encoding for a text file out of the locale when it is not
# told otherwise, and nothing here told it. So on a Turkish Windows the event
# log was written as UTF-8 and read back as cp1254, and every em dash agent-bus
# prints in its own text came back as `â€”`. Reported 2026-08-12, with the
# console ruled out as the cause: it was the read.
#
# The lever below is `LC_ALL=C` with UTF-8 mode and its coercion both switched
# off, which gives an ASCII default — a stricter codepage than the one this was
# reported on and the same defect, reproducible on any machine. Every assertion
# here is about text crossing a locale boundary in one direction or the other,
# because that is what one Windows session and one Mac session sharing a bus
# directory actually is.
#
# The one that is not cosmetic is the rotation. It reads the whole log and
# writes it back, so a character the locale cannot decode does not arrive
# mangled there — it raises, inside a `try` that only catches OSError, on a hook
# that runs every single turn.

. "$AB_ROOT/tests/lib.sh"

# Everything agent-bus prints about itself: an em dash, the middle dot the
# roster indents subagents with, the arrow the board draws, and Turkish
# diacritics. None of them survive an ASCII codepage, and the last group does
# not survive cp1254's neighbours either.
MARK='took the name of its chat — was ölçüm-kolay · dev → prod ≥ 2.5'

# The CLI in a locale that is not UTF-8. `env` and not a bare assignment: for a
# shell function bash would leave the variables set afterwards, and half this
# file has to run in the other locale.
ab_c() {   # <session id> <args…>
  local sid="$1"; shift
  env AGENTBUS_SESSION="$sid" LC_ALL=C LANG=C PYTHONUTF8=0 \
      PYTHONCOERCECLOCALE=0 "$AB_ROOT/bin/agentbus" "$@"
}

hook_c() {   # <event> <payload> → the hook's stdout, in the other locale
  printf '%s' "$2" | env LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 \
    "$AB_ROOT/bin/agentbus" hook "$1"
}

# The lever has to actually bite, or every assertion below passes for the wrong
# reason and this file is decoration.
pref=$(env LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 python3 -c \
       'import locale; print(locale.getpreferredencoding(False))')
case "$pref" in
  UTF-8|utf-8|UTF8|utf8)
    skip_test "this Python will not leave UTF-8 mode ($pref): nothing to test" ;;
esac
assert_not_contains "$pref" "UTF" "the locale lever really is not UTF-8 ($pref)"

REPO=$(make_repo encrepo)
commit_all "$REPO"
new_session sess-a "$REPO"
new_session sess-b "$REPO"

# ---- written in UTF-8, read in the other locale ------------------------------
#
# The reported direction. One session posts, another reads, and on that machine
# the reader was the one whose locale was not UTF-8.

ab sess-a post "$MARK" > /dev/null
out=$(ab_c sess-b status 2>&1)
assert_contains "$out" "$MARK" \
  "an event written as UTF-8 comes back whole in a locale that is not"
assert_not_contains "$out" "â€”" "and not as the mojibake it used to"

# ---- written in the other locale, read in UTF-8 ------------------------------

ab_c sess-b post "$MARK" > /dev/null
out=$(ab sess-a status 2>&1)
assert_equal 2 "$(printf '%s\n' "$out" | grep -c -- "$MARK")" \
  "and the same text posted from that locale is readable from this one"

# The file itself, not just what was printed: both lines have to be UTF-8 on
# disk, because a third machine will read them and it is not either of these.
assert_equal 2 "$(grep -c -- 'ölçüm-kolay' "$AGENTBUS_HOME/events.jsonl")" \
  "both events are UTF-8 on disk, whoever wrote them"

# ---- the rotation, which is the one that does not fail quietly ---------------
#
# `rotate_events` reads the whole log and writes it back, and runs on every
# prompt-submit. Below ROTATE_AT it never opens the file, so this has to be a
# real log of the real size: 6000 lines and over 600 KB, with the text inside
# the last 1000 that a rotation keeps.

python3 - "$AGENTBUS_HOME/events.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    for i in range(6000):
        fh.write(json.dumps({
            "ts": 1, "sid": "pad", "agent": "pad", "repo": "r", "kind": "note",
            "i": 100000 + i,
            "text": "padding so the log is over the rotation threshold " * 2,
        }, ensure_ascii=False) + "\n")
PY

before=$(wc -l < "$AGENTBUS_HOME/events.jsonl" | tr -d " ")
ab_c sess-b post "$MARK — the line the rotation must keep" > /dev/null

out=$(hook_c prompt-submit "$(payload session sid=sess-a "cwd=$REPO")" 2>&1)
rc=$?
assert_equal 0 "$rc" \
  "the hook that rotates the log survives a log it cannot decode by locale"

after=$(wc -l < "$AGENTBUS_HOME/events.jsonl" | tr -d " ")
assert_equal 1000 "$after" "the log was actually rotated, not skipped"
[ "$before" -gt "$after" ] \
  && _ok "and it shrank, so the read-and-write-back path really ran" \
  || _bad "and it shrank, so the read-and-write-back path really ran" \
          "$before -> $after"

assert_contains "$(cat "$AGENTBUS_HOME/events.jsonl")" \
  "the line the rotation must keep" "the kept lines are still there"
assert_contains "$(cat "$AGENTBUS_HOME/events.jsonl")" "ölçüm-kolay" \
  "and the rotation wrote them back as UTF-8 rather than persisting mojibake"

# ---- a path is text too ------------------------------------------------------
#
# The write log stores file paths, one per line, and a filesystem will hand out
# any character at all. Same two functions, same defect, and it decides what a
# handoff says this session touched.

FILE="$REPO/ölçüm-günlüğü.txt"
printf 'x\n' > "$FILE"
hook_c record-write "$(payload write sid=sess-a "cwd=$REPO" "path=$FILE")" \
  > /dev/null
end_session sess-a
out=$(ab sess-b status 2>&1)
assert_contains "$out" "ölçüm-günlüğü.txt" \
  "a written path with diacritics in it survives into the handoff"

# ---- a byte-order mark on a file a person edited ----------------------------
#
# PowerShell and Notepad both put a BOM on what they write, so on Windows any
# JSON somebody has touched has one — and `json.loads` refuses it outright, at
# the first character. Two files are in that position. `~/.claude/settings.json`
# is the one that was found: the installer read it, failed, and told the user
# their settings were not valid JSON when they were. The one below is the same
# file in the same position and costs more, because a repository config that
# does not parse is every guard in that repository quietly not existing.
#
# Not a regression from spelling the encoding out — `cp1254` refused a BOM too,
# with a vaguer message. Reported from Windows 10 on 2026-08-12.

head3() {   # <path> → its first three bytes as hex, single-spaced
  od -An -tx1 -N3 "$1" | tr -s ' ' | sed 's/^ //; s/ $//'
}

BOMREPO=$(make_repo bomrepo)
mkdir -p "$BOMREPO/.claude"
printf '\357\273\277' > "$BOMREPO/.claude/agent-bus.json"
cat >> "$BOMREPO/.claude/agent-bus.json" <<'JSON'
{"resources": [{"name": "bomdb", "desc": "the shared development database",
                "patterns": ["\\bpsql\\b"]}]}
JSON
commit_all "$BOMREPO"
new_session sess-c "$BOMREPO"

assert_equal "ef bb bf" "$(head3 "$BOMREPO/.claude/agent-bus.json")" \
  "the fixture really does start with a byte-order mark"
out=$(ab sess-c status 2>&1)
assert_contains "$out" "bomdb" \
  "a repository config a Windows editor wrote is still read"
assert_not_contains "$out" "No shared resources declared" \
  "rather than leaving the repository looking like it declares nothing"

# The same on the write side: what this reads back it must not have BOM'd itself,
# or every file it owns grows one more mark per pass.
ab sess-c post "$MARK" > /dev/null
assert_not_contains "$(head3 "$AGENTBUS_HOME/events.jsonl")" "ef bb bf" \
  "and nothing this plugin writes gets a mark of its own"

# ---- reading the repository, in that locale ----------------------------------
#
# `init-repo` reads a project's own files to find its services. Those are files
# nobody here wrote and their encoding is not this plugin's to choose, so the
# only requirement is that one of them cannot take the command down.

printf '{"name": "ölçüm", "scripts": {"dev": "vite --port 5173"}}\n' \
  > "$REPO/package.json"
out=$(cd "$REPO" && ab_c sess-b init-repo --dry-run 2>&1)
rc=$?
assert_equal 0 "$rc" "reading a project file in that locale does not raise"
assert_contains "$out" "5173" "and the port it was read for is still found"

finish
