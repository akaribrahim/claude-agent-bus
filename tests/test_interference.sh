#!/usr/bin/env bash
# The interference guard: a failure that blames somebody else's in-flight edit.
#
# This is the failure people running several agents actually report. Session A
# is halfway through editing a file; session B runs the build, sees the type
# error A's half-written code produced, and "helpfully" repairs a file it does
# not own. Now both sessions are fighting over one file and neither knows why.
#
# The guard has to be conservative in both directions, so most of this file is
# about what must NOT produce a note. A false accusation is worse than silence:
# an agent that catches the bus being wrong about who owns what is an agent that
# starts working around it.
#
# Note that this repository declares no resources at all. Interference does not
# depend on any configuration — two live sessions is the whole prerequisite.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo interfrepo)
mkdir -p "$REPO/api"
commit_all "$REPO"

new_session sess-a "$REPO"
new_session sess-b "$REPO"
A=$(ab sess-a name)
assert_equal 2 "$(cat "$AGENTBUS_HOME/live-count")" "two sessions in one checkout"

wrote() {   # <session id> <absolute path>
  ab_hook record-write "$(payload write "sid=$1" "cwd=$REPO" "path=$2")" > /dev/null
}

# A finished batch of tool calls, carrying what the command printed. This is
# the event the guard reads: Claude Code does not fire PostToolUse when a tool
# call errors, so a failing build never arrives there at all.
failed() {   # <session id> <output text> → the hook's stdout
  ab_hook post-batch "$(payload batch "sid=$1" "cwd=$REPO" \
    "cmd=python3 -m py_compile api/service.py" "out=$2")"
}

note_of() {  # <hook output> → the injected context, or empty
  json_field "$1" hookSpecificOutput additionalContext
}

# The guard shares PostToolBatch with message delivery, so "said nothing" has to
# mean "produced no interference note" rather than "printed nothing at all" — a
# handoff arriving in the same block is a different feature working correctly.
assert_no_note() {   # <hook output> <label>
  assert_not_contains "$(note_of "$1")" "editing right now" "$2"
}

# ---- a failure naming a file the other session just wrote -------------------

wrote sess-a "$REPO/api/service.py"

TYPE_ERROR="api/service.py:12:5 - error TS2304: Cannot find name 'resolveUser'.
Found 1 error in api/service.py:12"

out=$(failed sess-b "$TYPE_ERROR")
note=$(note_of "$out")
assert_contains "$note" "editing right now" "the failure produces a note"
assert_contains "$note" "api/service.py" "the note names the file"
assert_contains "$note" "$A" "the note names the session that owns it"
assert_contains "$note" "Do not fix them" "the note says what to do instead"
assert_contains "$note" "agentbus post --to $A" "the note offers the way to ask"
assert_contains "$note" "service.py breaks my build" \
  "the suggested message names the file"

# That note arrived with no lock involved anywhere: until the interference
# guard, the fast path only woke the engine when a command had claimed
# something, and a build broken by somebody else's edit claims nothing.
assert_equal 0 "$(locks_held)" "no resource was claimed by any of this"

# ---- a command that succeeded says nothing, however it is worded ------------

out=$(failed sess-b "PASS api/service.py (1.2s)
Test Suites: 1 passed, 1 total")
assert_no_note "$out" "a passing run mentioning the same file is silent"

out=$(failed sess-b "compiled api/service.py -> dist/service.js
Build complete in 840ms")
assert_no_note "$out" "a successful build mentioning it is silent"

# ---- a failure that names somebody else's file ------------------------------

out=$(failed sess-b "api/billing.py:4:1 - error TS2304: Cannot find name 'x'.")
assert_no_note "$out" "a failure naming a file nobody else wrote is silent"

out=$(failed sess-b "")
assert_no_note "$out" "an empty output is silent"

# ---- a file this session touched too is its own problem ---------------------

wrote sess-a "$REPO/api/shared.py"
wrote sess-b "$REPO/api/shared.py"
out=$(failed sess-b "api/shared.py:9:2 - error: unexpected indent")
assert_no_note "$out" \
  "a file this session also edited is not blamed on the other one"

# The other session's file is still reported in the same output, so the drop
# above is about that one file and not about giving up on the whole check.
out=$(failed sess-b "api/shared.py:9:2 - error: unexpected indent
api/service.py:12:5 - error TS2304: Cannot find name 'resolveUser'.")
note=$(note_of "$out")
assert_contains "$note" "api/service.py" "the other session's file is still named"
assert_not_contains "$note" "api/shared.py" "the shared one is not"

# ---- a bare basename has to be worth trusting -------------------------------

wrote sess-a "$REPO/api/x.ts"
out=$(failed sess-b "x.ts:3:1 - error TS1005: ';' expected.")
assert_no_note "$out" \
  "a short basename alone is a coincidence, not a mention"

wrote sess-a "$REPO/api/userprofile.py"
out=$(failed sess-b "ImportError while loading conftest: userprofile.py, line 4")
assert_contains "$(note_of "$out")" "api/userprofile.py" \
  "a long basename with an extension is a mention"

# An absolute path is how a traceback names a file.
wrote sess-a "$REPO/api/loader.py"
out=$(failed sess-b "Traceback (most recent call last):
  File \"$REPO/api/loader.py\", line 8, in <module>")
assert_contains "$(note_of "$out")" "api/loader.py" \
  "an absolute path in a traceback is a mention"

# ---- at most three files, newest first --------------------------------------

for f in alpha_one beta_two gamma_three delta_four; do
  wrote sess-a "$REPO/api/$f.py"
done
out=$(failed sess-b "error: build failed
  api/alpha_one.py
  api/beta_two.py
  api/gamma_three.py
  api/delta_four.py")
note=$(note_of "$out")
listed=$(printf '%s\n' "$note" | grep -c ' ago$')
assert_equal 3 "$listed" "at most three files are named"

# ---- the automatic claim is still given back --------------------------------
#
# The fast path used to run the engine for post-bash only when an auto-claim
# file existed. That gate is gone, so the release path has to be re-proved
# here rather than assumed.

set_config "$REPO" <<'JSON'
{"resources": [{"name": "db", "desc": "the shared development database",
                "patterns": ["\\bpsql\\b"]}]}
JSON

# A config that has just been written is not live yet: the shell fast path
# filters on `guard-tokens`, which the engine derives from the config the last
# time it ran. `init-repo` refreshes it on the way out; a hand-edited config
# waits for the session's next turn. Worth stating as behaviour rather than
# discovering it as a flaky test.
assert_empty "$(cat "$AGENTBUS_HOME/guard-tokens")" \
  "before the refresh the fast path has nothing to filter on"
ab sess-b doctor > /dev/null
assert_contains "$(cat "$AGENTBUS_HOME/guard-tokens")" "psql" \
  "the next engine run picks the new config up"

out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$REPO" "cmd=psql -l" id=if-1)")
assert_allow "$out" "a guarded command still runs"
assert_equal 1 "$(locks_held)" "and still claims the resource"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$REPO" id=if-1)" > /dev/null
assert_equal 0 "$(locks_held)" "and gives it back when it succeeds"

# A command that FAILS never reaches PostToolUse. Without the batch releasing
# it too, the claim would be held for its full soft TTL and the other session
# would wait a quarter of an hour for a command that is already over.
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$REPO" "cmd=psql -l" id=if-2)")
assert_allow "$out" "a guarded command that is about to fail still runs"
assert_equal 1 "$(locks_held)" "and claims the resource"
ab_hook post-batch "$(payload batch sid=sess-b "cwd=$REPO" \
  "cmd=psql -l" id=if-2 "out=Exit code 2
psql: error: connection refused")" > /dev/null
assert_equal 0 "$(locks_held)" "and gets it back even though it failed"

# ---- whatever shape the host puts the output in -----------------------------
#
# `tool_response` is not the same object everywhere: a dict of stdout/stderr
# here, a bare string elsewhere, a list of content blocks for some tools,
# absent when a command was interrupted. The first constraint on this plugin is
# that a hook must never be the reason a session breaks, so every shape has to
# come back exit 0 with either nothing or valid JSON — which `ab_hook` asserts
# on every call in this file.

out=$(ab_hook post-batch "$(payload batch sid=sess-b "cwd=$REPO" \
  "cmd=make build" "out=$TYPE_ERROR")")
assert_contains "$(note_of "$out")" "api/service.py" \
  "a string tool_response is read"

# Whatever else a host puts there, the hook must come back exit 0 with nothing
# or valid JSON — which ab_hook asserts on every call in this file.
for odd in dict list null number; do
  out=$(ab_hook post-batch "$(python3 "$AB_ROOT/tests/oddbatch.py" sess-b "$REPO" "$odd")")
  assert_no_note "$out" "an odd tool_response ($odd) is survived quietly"
done

out=$(ab_hook post-batch "$(payload batch sid=sess-b "cwd=$REPO")")
assert_no_note "$out" "a batch with no tool calls is survived quietly"

# ---- a session in another repository cannot have caused this ---------------
#
# Sessions in unrelated projects share nothing but the machine, so an edit of
# theirs that happens to carry a name this build also prints is a coincidence.
# Naming it would be exactly the false accusation this guard must not make.

REPO2=$(make_repo otherrepo)
mkdir -p "$REPO2/api"
commit_all "$REPO2"
new_session sess-c "$REPO2"
assert_equal 3 "$(cat "$AGENTBUS_HOME/live-count")" "a third session, another repo"

wrote sess-c "$REPO2/api/foreign.py"
out=$(failed sess-b "api/foreign.py:1:1 - error: unexpected token")
assert_no_note "$out" \
  "a session in another repository is never blamed for this build"

# …while the same shape inside this repository still is, so the filter above is
# about the repository and not about having quietly stopped working.
wrote sess-a "$REPO/api/domestic.py"
out=$(failed sess-b "api/domestic.py:1:1 - error: unexpected token")
assert_contains "$(note_of "$out")" "api/domestic.py" \
  "a session in this repository still is"

# ---- what a batch that ran no command costs ---------------------------------
#
# With somebody else live, the engine now runs on every batch that ran a Bash
# command: it has to read what those commands printed. A batch of nothing but
# edits cannot have printed anybody's build failure, and an agent editing files
# produces a great many of those, so it still has to short-circuit in the shell.

EDITS=$(python3 -c "
import json, sys
calls = [{'tool_name': 'Edit', 'tool_use_id': 'e%d' % i,
          'tool_input': {'file_path': '$REPO/api/f%d.py' % i},
          'tool_response': {'filePath': 'x', 'oldString': 'a' * 4000,
                            'newString': 'b' * 4000}} for i in range(8)]
print(json.dumps({'session_id': 'sess-b', 'cwd': '$REPO',
                  'hook_event_name': 'PostToolBatch', 'tool_calls': calls}))")
# The same batch with one Bash call in it, which the engine must look at.
WITHBASH=$(python3 -c "
import json, sys
calls = [{'tool_name': 'Edit', 'tool_use_id': 'e%d' % i,
          'tool_input': {'file_path': '$REPO/api/f%d.py' % i},
          'tool_response': {'filePath': 'x', 'oldString': 'a' * 4000,
                            'newString': 'b' * 4000}} for i in range(8)]
calls.append({'tool_name': 'Bash', 'tool_use_id': 'bb',
              'tool_input': {'command': 'make build'},
              'tool_response': 'Compiled 42 files in 1.2s'})
print(json.dumps({'session_id': 'sess-b', 'cwd': '$REPO',
                  'hook_event_name': 'PostToolBatch', 'tool_calls': calls}))")

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
batch_ms() {   # <payload> → the best of three runs of twenty calls
  local best="" started elapsed
  for _batch in 1 2 3; do
    started=$(now_ms)
    for _ in $(seq 1 20); do
      printf '%s' "$1" | bash "$AB_ROOT/bin/ab-hook" post-batch > /dev/null 2>&1
    done
    elapsed=$(( $(now_ms) - started ))
    if [ -z "$best" ] || [ "$elapsed" -lt "$best" ]; then best="$elapsed"; fi
  done
  printf '%d' "$best"
}

ab_hook post-batch "$EDITS" > /dev/null      # let the cursor catch up first
edits_ms=$(batch_ms "$EDITS")
bash_ms=$(batch_ms "$WITHBASH")

# Compared rather than budgeted: both pay for bash slurping a large payload,
# which is unavoidable because the session id is in it, and an absolute figure
# would only be measuring how busy the machine was. What is being asserted is
# that one of them wakes the engine and the other does not.
if [ "$edits_ms" -lt "$(( bash_ms * 3 / 4 ))" ]; then
  _ok "an edit-only batch is cheaper than one that ran a command (${edits_ms}ms vs ${bash_ms}ms per 20)"
else
  _bad "an edit-only batch is cheaper than one that ran a command (${edits_ms}ms vs ${bash_ms}ms per 20)" \
    "a batch that ran no command is waking the engine for nothing"
fi

# ---- alone, none of this happens --------------------------------------------

end_session sess-a
end_session sess-c
assert_equal 1 "$(cat "$AGENTBUS_HOME/live-count")" "one session left"
out=$(failed sess-b "$TYPE_ERROR")
assert_no_note "$out" "alone, a failure is nobody else's doing"

finish
