# agent-bus — test helpers.  Sourced by every tests/test_*.sh.
#
# Two things this file exists to guarantee, because everything else depends on
# them:
#
#   1. No test ever touches the live bus. AGENTBUS_HOME is set by run.sh to a
#      throwaway directory and the guard below refuses to run if it is not.
#   2. Every hook invocation is checked against the invariant that the whole
#      plugin rests on — exit 0, and print either nothing or valid JSON. That
#      check is inside `ab_hook` rather than in each test, so a test cannot
#      forget it.
#
# Assertion counts live in files, not shell variables: `out=$(ab_hook ...)` runs
# in a subshell, and a failure recorded in a variable there would be lost.

: "${AB_ROOT:?run tests through tests/run.sh}"
: "${TEST_TMP:?run tests through tests/run.sh}"
: "${AGENTBUS_HOME:?run tests through tests/run.sh}"

case "$AGENTBUS_HOME" in
  "$HOME"/.claude/agent-bus | "$HOME"/.claude/agent-bus/*)
    echo "REFUSING TO RUN: AGENTBUS_HOME points at the live bus ($AGENTBUS_HOME)" >&2
    exit 99
    ;;
esac

PASSES="$TEST_TMP/.passes"
FAILURES="$TEST_TMP/.failures"

# ------------------------------------------------------------- reporting ----

_ok() {
  printf '%s\n' "$1" >> "$PASSES"
  # To stderr, like _bad, and for a harder reason than symmetry: almost every
  # assertion in this suite is made inside `out=$(ab_hook …)`, so an `ok` line
  # on stdout lands *inside* the captured hook output and `json_field` then
  # parses the test harness's own chatter as the hook's JSON. VERBOSE=1 is
  # documented as the way to inspect assertions; on stdout it was instead the
  # way to make them lie — `VERBOSE=1 tests/run.sh test_subagents.sh` failed 22
  # of 118 on a tree where the same file passed 118 of 118 without it.
  [ -n "${VERBOSE:-}" ] && printf '    ok   %s\n' "$1" >&2
  return 0
}

_bad() {
  printf '%s\n' "$1" >> "$FAILURES"
  printf '    FAIL %s\n' "$1" >&2
  if [ $# -gt 1 ]; then
    printf '%s\n' "$2" | sed 's/^/         /' >&2
  fi
  return 0
}

# Stop the file early with a reason run.sh will report as a skip rather than a
# pass. Used when the host lacks something the test genuinely needs.
skip_test() {
  printf '%s' "$1" > "$TEST_TMP/.skip"
  exit 0
}

finish() {
  if [ -s "$FAILURES" ]; then
    exit 1
  fi
  exit 0
}

# ------------------------------------------------------------ assertions ----

assert_equal() {   # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then
    _ok "$3"
  else
    _bad "$3" "expected: [$1]
actual:   [$2]"
  fi
}

assert_contains() {   # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) _ok "$3" ;;
    *) _bad "$3" "expected to contain: $2
--- actual ---
$1" ;;
  esac
}

assert_not_contains() {   # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) _bad "$3" "expected NOT to contain: $2
--- actual ---
$1" ;;
    *) _ok "$3" ;;
  esac
}

assert_empty() {   # <text> <label>
  if [ -z "$1" ]; then _ok "$2"; else _bad "$2" "expected no output, got:
$1"; fi
}

assert_file() {    # <path> <label>
  if [ -e "$1" ]; then _ok "$2"; else _bad "$2" "missing: $1"; fi
}

assert_no_file() { # <path> <label>
  if [ -e "$1" ]; then _bad "$2" "should not exist: $1"; else _ok "$2"; fi
}

# A PreToolUse deny is the only thing that stops a tool call, so it is asserted
# on the decision field rather than on the wording of the message.
assert_deny() {    # <hook output> <label>
  local d; d=$(json_field "$1" hookSpecificOutput permissionDecision)
  if [ "$d" = "deny" ]; then
    _ok "$2"
  else
    _bad "$2" "expected a PreToolUse deny; got:
${1:-(no output)}"
  fi
}

assert_allow() {   # <hook output> <label>
  local d; d=$(json_field "$1" hookSpecificOutput permissionDecision)
  if [ "$d" = "deny" ]; then
    _bad "$2" "expected the command to be allowed; got a deny:
$1"
  else
    _ok "$2"
  fi
}

# ---------------------------------------------------------------- engine ----

json_field() {  # <json text> <key> [<key> …] → the value, or empty
  [ -n "$1" ] || return 0
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    cur = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1:]:
    if not isinstance(cur, dict):
        sys.exit(0)
    cur = cur.get(k)
    if cur is None:
        sys.exit(0)
print(cur)' "${@:2}" 2>/dev/null
}

_hook_checked() {  # <event> <rc> <output>
  if [ "$2" -ne 0 ]; then
    _bad "hook $1 exits 0" "exit code $2"
  else
    _ok "hook $1 exits 0"
  fi
  if [ -n "$3" ]; then
    if printf '%s' "$3" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      _ok "hook $1 prints valid JSON"
    else
      _bad "hook $1 prints valid JSON" "$3"
    fi
  fi
}

# Feed a payload to the shell fast path, exactly as Claude Code does.
ab_hook() {   # <event> [<json payload>] → the hook's stdout
  local ev="$1" payload='{}' out rc
  [ $# -gt 1 ] && payload="$2"
  out=$(printf '%s' "$payload" | bash "$AB_ROOT/bin/ab-hook" "$ev")
  rc=$?
  _hook_checked "$ev" "$rc" "$out"
  printf '%s' "$out"
}

# The Python fast path — what Windows actually runs. It has to make the same
# decisions as the bash one; anything else is a guard that exists on one
# platform and not the other.
ab_pyhook() {   # <event> [<json payload>] → the hook's stdout
  local ev="$1" payload='{}' out rc
  [ $# -gt 1 ] && payload="$2"
  out=$(printf '%s' "$payload" | python3 "$AB_ROOT/bin/hook.py" "$ev")
  rc=$?
  _hook_checked "py $ev" "$rc" "$out"
  printf '%s' "$out"
}

# Same, but straight into the Python engine — the path Windows uses, where
# there is no fast path to gate anything.
ab_engine() {  # <event> [<json payload>] → the hook's stdout
  local ev="$1" payload='{}' out rc
  [ $# -gt 1 ] && payload="$2"
  out=$(printf '%s' "$payload" | "$AB_ROOT/bin/agentbus" hook "$ev")
  rc=$?
  _hook_checked "engine $ev" "$rc" "$out"
  printf '%s' "$out"
}

# Run the CLI as a given session, the way Claude Code's own Bash tool does.
ab() {   # <session id> <args…>
  local sid="$1"; shift
  AGENTBUS_SESSION="$sid" "$AB_ROOT/bin/agentbus" "$@"
}

payload() {   # <kind> <k=v…> → a hook payload on stdout
  python3 "$AB_ROOT/tests/mkpayload.py" "$@"
}

# --------------------------------------------------------------- fixtures ----

new_session() {   # <session id> <cwd>
  ab_hook session-start "$(payload session "sid=$1" "cwd=$2")" > /dev/null
}

end_session() {   # <session id>
  ab_hook session-end "$(payload session-end "sid=$1" cwd=/)" > /dev/null
}

make_repo() {   # <name> → the worktree root, resolved
  local dir="$TEST_TMP/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q > /dev/null 2>&1
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "agent-bus tests"
  git -C "$dir" config commit.gpgsign false
  printf 'fixture\n' > "$dir/README"
  (cd "$dir" && pwd -P)
}

# The config is committed so that `git worktree add` gives every checkout the
# same guards — which is the whole point of keeping it in the repository.
set_config() {   # <repo root> <json on stdin>
  mkdir -p "$1/.claude"
  cat > "$1/.claude/agent-bus.json"
}

commit_all() {   # <repo root>
  git -C "$1" add -A > /dev/null 2>&1
  git -C "$1" commit -qm "fixture" > /dev/null 2>&1
}

make_worktree() {   # <repo root> <name> [<branch>] → the new worktree root
  local branch="${3:-$2}"
  git -C "$1" worktree add -q -b "$branch" "$TEST_TMP/$2" > /dev/null 2>&1
  (cd "$TEST_TMP/$2" && pwd -P)
}

free_port() {
  python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# Kill anything agent-bus started for this test. Only ever touches pids agent-bus
# itself recorded in this run's own throwaway state directory.
stop_services() {
  local f pid
  for f in "$AGENTBUS_HOME"/serves/*.json; do
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

session_field() {   # <session id> <key> → one field of a session record
  python3 -c "
import json, sys
try:
    print(json.load(open('$AGENTBUS_HOME/sessions/$1.json')).get('$2', ''))
except Exception:
    pass"
}

agent_field() {   # <session id> <agent id> <key> → one field of a subagent record
  python3 -c "
import glob, json, os, sys
for path in glob.glob('$AGENTBUS_HOME/agents/*.json'):
    try:
        rec = json.load(open(path))
    except Exception:
        continue
    if rec.get('sid') == '$1' and rec.get('agent_id') == '$2':
        print(rec.get('$3', ''))
        break"
}

lock_lines() {   # → the text of every lock event so far, one per line
  python3 -c "
import json
try:
    fh = open('$AGENTBUS_HOME/events.jsonl')
except OSError:
    raise SystemExit
for line in fh:
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get('kind') == 'lock':
        print(rec.get('text', ''))"
}

read_seq() {
  local n=0
  [ -r "$AGENTBUS_HOME/events.seq" ] && read -r n < "$AGENTBUS_HOME/events.seq"
  printf '%s' "${n:-0}"
}

locks_held() {
  local n=0 f
  for f in "$AGENTBUS_HOME"/locks/*.json; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%d' "$n"
}
