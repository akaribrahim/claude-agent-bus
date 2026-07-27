#!/usr/bin/env bash
# agent-bus — test runner.
#
#   tests/run.sh [filter]
#
# Every test file gets its own throwaway AGENTBUS_HOME and its own throwaway
# git repositories, so a test run can never see, change or delete the state of
# the live sessions on this machine. That is not a nicety: the hooks under test
# are the same ones running in every Claude Code session on this Mac.
#
# Exits non-zero if any assertion in any file failed, and prints which.
#
#   VERBOSE=1   print every assertion, not just failures
#   KEEP=1      leave the temporary directories behind for inspection

set -u

AB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
export AB_ROOT

FILTER="${1:-}"

# Whatever the caller's shell was attached to must not leak into the fixtures:
# an inherited session id would make the engine report on a real live session.
unset AGENTBUS_HOME AGENTBUS_SESSION AGENTBUS_OFF CLAUDE_CODE_SESSION_ID
export CLAUDE_PID=$$   # every fixture session claims this pid, so none look dead
export GIT_TERMINAL_PROMPT=0

command -v python3 > /dev/null 2>&1 || {
  echo "tests: no python3 on PATH" >&2
  exit 1
}

TMPROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentbus-tests.XXXXXX")" && pwd -P)
cleanup() {
  [ -n "${KEEP:-}" ] && { echo "kept: $TMPROOT"; return; }
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

files_run=0
files_failed=0
files_skipped=0
assertions=0
failures=0

line() {   # <status> <name> <seconds> <detail>
  printf '  %-5s %-18s %3ds  %s\n' "$1" "$2" "$3" "$4"
}

# `grep -c` prints 0 and exits 1 on an empty file, so the exit status is not
# usable here — only the number it printed is.
count_lines() {   # <path>
  local n=0
  [ -f "$1" ] && n=$(grep -c . "$1" 2>/dev/null)
  printf '%d' "${n:-0}"
}

# The syntax gate. Nothing below is meaningful if the engine does not compile,
# and a hook that does not parse is the one failure mode that breaks other
# people's sessions rather than this test run.
run_syntax() {
  local t0=$SECONDS out rc n
  out=$(python3 "$AB_ROOT/tests/check_syntax.py" 2>&1)
  rc=$?
  files_run=$((files_run + 1))
  n=$(printf '%s\n' "$out" | grep -c '^ok ')
  assertions=$((assertions + n))
  if [ "$rc" -ne 0 ]; then
    files_failed=$((files_failed + 1))
    failures=$((failures + 1))
    line FAIL syntax $((SECONDS - t0)) ""
    printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  line ok syntax $((SECONDS - t0)) "$n checks"
}

# Kill anything a test left listening. Only pids agent-bus itself recorded in
# that test's own state directory — nothing else is ever signalled.
reap_services() {   # <bus dir>
  local f pid
  for f in "$1"/serves/*.json; do
    [ -f "$f" ] || continue
    pid=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("pid") or "")
except Exception:
    pass' "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
}

run_file() {   # <path>
  local file="$1" name t0 rc dir log np nf
  name=$(basename "$file")
  t0=$SECONDS
  dir=$(cd "$(mktemp -d "$TMPROOT/${name%.*}.XXXXXX")" && pwd -P)
  log="$dir/output.log"
  mkdir -p "$dir/bus"

  case "$file" in
    *.py) (cd "$AB_ROOT" && TEST_TMP="$dir" AGENTBUS_HOME="$dir/bus" \
             TEST_NAME="$name" python3 "$file") > "$log" 2>&1 ;;
    *)    (cd "$AB_ROOT" && TEST_TMP="$dir" AGENTBUS_HOME="$dir/bus" \
             TEST_NAME="$name" bash "$file") > "$log" 2>&1 ;;
  esac
  rc=$?

  reap_services "$dir/bus"
  np=$(count_lines "$dir/.passes")
  nf=$(count_lines "$dir/.failures")
  assertions=$((assertions + np + nf))
  failures=$((failures + nf))
  files_run=$((files_run + 1))

  if [ -f "$dir/.skip" ]; then
    files_skipped=$((files_skipped + 1))
    line skip "$name" $((SECONDS - t0)) "$(cat "$dir/.skip")"
  elif [ "$rc" -ne 0 ] || [ "$nf" -gt 0 ]; then
    files_failed=$((files_failed + 1))
    [ "$rc" -ne 0 ] && [ "$nf" -eq 0 ] && failures=$((failures + 1))
    line FAIL "$name" $((SECONDS - t0)) "$nf failed of $((np + nf))"
    sed 's/^/       /' < "$log"
  else
    line ok "$name" $((SECONDS - t0)) "$np assertions"
    [ -n "${VERBOSE:-}" ] && sed 's/^/       /' < "$log"
  fi
  [ -n "${KEEP:-}" ] || rm -rf "$dir"
  return 0
}

printf 'agent-bus tests — %s, bash %s\n' \
  "$(python3 -V 2>&1)" "${BASH_VERSION%%(*}"

run_syntax

for f in "$AB_ROOT"/tests/test_*; do
  [ -f "$f" ] || continue
  if [ -n "$FILTER" ]; then
    case "$(basename "$f")" in
      *"$FILTER"*) ;;
      *) continue ;;
    esac
  fi
  run_file "$f"
done

printf '\n%d file%s, %d assertion%s, %d failure%s' \
  "$files_run" "$([ "$files_run" = 1 ] || echo s)" \
  "$assertions" "$([ "$assertions" = 1 ] || echo s)" \
  "$failures" "$([ "$failures" = 1 ] || echo s)"
[ "$files_skipped" -gt 0 ] && printf ', %d skipped' "$files_skipped"
printf '\n'

[ "$files_failed" -eq 0 ] || exit 1
exit 0
