#!/usr/bin/env bash
# The Python fast path decides exactly what the bash one decides.
#
# Windows has no shell to gate hooks with, so `bin/hook.py` does the same job
# in Python: answer "nothing to do here" without loading the engine. That is
# worth having — measured on a Windows 10 host with endpoint scanning, a hook
# with nothing to do cost 281 ms, of which 178 ms was spent getting ready to
# decide there was nothing to do — but it is also a second implementation of
# the one thing in this plugin that must never be wrong twice.
#
# So the point of this file is parity, not behaviour: every case is put through
# both entry points and their answers compared. A guard that fires on macOS and
# not on Windows is worse than one that fires on neither, because nobody looks
# for it.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo pyrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "the shared development database",
     "why": "One database for every worktree.",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT2=$(make_worktree "$REPO" pywt2)

# Compare the two entry points on one payload. Both are asked; both are held to
# the exit-0-and-valid-JSON invariant by their helpers; then the decisions are
# compared rather than the wording.
same() {   # <label> <event> <payload>
  local sh py d_sh d_py
  sh=$(ab_hook "$2" "$3")
  py=$(ab_pyhook "$2" "$3")
  d_sh=$(json_field "$sh" hookSpecificOutput permissionDecision)
  d_py=$(json_field "$py" hookSpecificOutput permissionDecision)
  assert_equal "${d_sh:-none}" "${d_py:-none}" "$1"
}

# ---- alone: both stay out of the way ----------------------------------------

new_session sess-a "$REPO"
CMD='psql -c "select 1"'

same "alone, a guarded command: both allow" pre-tool \
  "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$CMD" id=py-1)"
assert_equal 0 "$(locks_held)" "and neither claimed anything"

out=$(ab_pyhook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=ls -la" id=py-2)")
assert_empty "$out" "an unguarded command says nothing"

# ---- two sessions: both guard -----------------------------------------------

new_session sess-b "$WT2"
assert_equal 2 "$(cat "$AGENTBUS_HOME/live-count")" "both sessions are live"

out=$(ab_pyhook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$CMD" id=py-3)")
assert_allow "$out" "the python path lets the first session through"
assert_equal 1 "$(locks_held)" "and really takes the lock"

same "the second session: both deny" pre-tool \
  "$(payload bash sid=sess-b "cwd=$WT2" "cmd=$CMD" id=py-4)"
reason=$(json_field "$(ab_pyhook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=$CMD" id=py-5)")" hookSpecificOutput permissionDecisionReason)
assert_contains "$reason" "development database" "with the same explanation"
assert_equal 1 "$(locks_held)" "and a denied command claims nothing"

ab_pyhook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=py-3)" > /dev/null
assert_equal 0 "$(locks_held)" "post-bash gives it back"

# The token pre-filter is the cheap gate both share: a command with none of the
# configured literals in it must not reach the engine at all.
same "a command matching no token: both allow" pre-tool \
  "$(payload bash sid=sess-b "cwd=$WT2" "cmd=echo nothing to see" id=py-6)"

# ---- writes are recorded, and pushed into the other session's filter --------

W="$REPO/service.py"
ab_pyhook record-write "$(payload write sid=sess-a "cwd=$REPO" "path=$W")" > /dev/null
assert_contains "$(cat "$AGENTBUS_HOME/writes/sess-a.log")" "$W" \
  "the python path records a write"
assert_contains "$(cat "$AGENTBUS_HOME/hot-for/sess-b")" "$W" \
  "and pushes it into the other session's filter"

# ---- an edit against a file somebody else just wrote ------------------------

same "an edit onto a fresh write: both deny" pre-tool \
  "$(payload file sid=sess-b "cwd=$REPO" "path=$W" tool=Edit)"

# A file nobody has touched is not in hot-for, so neither wakes the engine.
same "an edit elsewhere: both allow" pre-tool \
  "$(payload file sid=sess-b "cwd=$REPO" "path=$REPO/untouched.py" tool=Edit)"

# ---- messages are delivered ------------------------------------------------

ab sess-a post "the python path should carry this" > /dev/null
out=$(ab_pyhook post-batch "$(payload batch sid=sess-b "cwd=$WT2" "cmd=ls" id=py-7)")
assert_contains "$(json_field "$out" hookSpecificOutput additionalContext)" \
  "should carry this" "a message reaches the other session through hook.py"

out=$(ab_pyhook post-batch "$(payload batch sid=sess-b "cwd=$WT2" "cmd=ls" id=py-8)")
assert_empty "$out" "and is not delivered twice"

# ---- the payload shapes that break a naive reader ---------------------------
#
# PowerShell prepends a UTF-8 BOM when piping to a native executable, and this
# file scans the payload as text rather than parsing it — so both the BOM and
# whitespace around the colons have to be tolerated, or the gate silently
# decides there is nothing to do.

ab_pyhook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$CMD" id=py-hold)" > /dev/null
assert_equal 1 "$(locks_held)" "the first session is holding it again"

P=$(payload bash sid=sess-b "cwd=$WT2" "cmd=$CMD" id=py-9)
out=$(printf '\357\273\277%s' "$P" | python3 "$AB_ROOT/bin/hook.py" pre-tool)
assert_deny "$out" "a payload with a UTF-8 BOM is still guarded"

COMPACT=$(python3 -c "
import json, sys
print(json.dumps(json.loads(sys.argv[1]), separators=(',', ':')))" "$P")
out=$(printf '%s' "$COMPACT" | python3 "$AB_ROOT/bin/hook.py" pre-tool)
assert_deny "$out" "and so is one with no spaces around its colons"
ab_pyhook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=py-hold)" > /dev/null

# ---- the reason this file exists: the bytecode cache ------------------------
#
# Python writes no bytecode for a script it runs as __main__, so calling the
# engine directly recompiles five thousand lines on every hook. hook.py imports
# it as a module instead, which is cached — 4 ms against 30 ms here, and 71 ms
# on the Windows host this was written for.

rm -rf "$AB_ROOT/bin/__pycache__"
ab_pyhook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" "cmd=$CMD" id=py-10)" > /dev/null
assert_file "$AB_ROOT/bin/__pycache__" \
  "waking the engine through hook.py leaves a bytecode cache behind"

# ---- and it never loads the engine when there is nothing to do --------------
#
# The whole saving is here: on a host with no fast path the engine was loaded
# to discover it had no work. If this stops being true the cost comes back and
# nothing else in the suite would notice.

# The pre-filter greps the WHOLE payload, cwd included — and this suite runs
# under a directory called `agentbus-tests…`, so a payload from inside it
# always contains a token and always wakes the engine. That is correct
# behaviour and a fair warning about paths, but it makes the fixture unable to
# measure the saving, so this one is asked from somewhere neutral.
rm -rf "$AB_ROOT/bin/__pycache__"
NEUTRAL=$(python3 -c "
import json
print(json.dumps({'session_id': 'sess-b', 'cwd': '/tmp',
                  'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                  'tool_input': {'command': 'echo hello'},
                  'tool_use_id': 'py-11'}))")
printf '%s' "$NEUTRAL" | python3 "$AB_ROOT/bin/hook.py" pre-tool > /dev/null
assert_no_file "$AB_ROOT/bin/__pycache__" \
  "a command with nothing to guard never loads the engine at all"

ab_pyhook record-write "$(payload write sid=sess-a "cwd=$REPO" "path=$REPO/x.py")" > /dev/null
assert_no_file "$AB_ROOT/bin/__pycache__" \
  "and neither does recording a write, which it does by itself"

finish
