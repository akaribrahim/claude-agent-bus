#!/usr/bin/env bash
# Per-command claims: taken by the guard, given back by PostToolUse, and never
# handed to two sessions at once.
#
# The last case is the one that matters most. Two independent reviews of the
# pre-1.0 code found that the "is anybody holding this?" check ran outside the
# mutex and its answer was thrown away, so two sessions issuing a guarded
# command in the same tick both proceeded — silently, which is the worst way for
# a lock to fail. Forty concurrent pairs must produce exactly forty denials.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo lockrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db",
     "desc": "the shared development database",
     "why": "One database for every worktree.",
     "patterns": ["\\bpsql\\b", "\\balembic\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT2=$(make_worktree "$REPO" lockwt2)

new_session sess-a "$REPO"
new_session sess-b "$WT2"

A=$(ab sess-a name)
B=$(ab sess-b name)
assert_equal 2 "$(cat "$AGENTBUS_HOME/live-count")" "both sessions are live"

CMD='psql -c "select 1"'

# ---- a guarded command takes the resource for as long as it runs -------------

out=$(ab_hook pre-tool "$(payload bash "sid=sess-a" "cwd=$REPO" "cmd=$CMD" id=tu-1)")
assert_allow "$out" "the first session's guarded command is allowed"
assert_equal 1 "$(locks_held)" "running it took the lock"
assert_file "$AGENTBUS_HOME/autoclaim/tu-1.json" \
  "the claim is recorded against the tool call that made it"

# ---- while it is held, the other session is refused with a reason ------------

out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=tu-2)")
assert_deny "$out" "the second session is denied while the first holds it"
reason=$(json_field "$out" hookSpecificOutput permissionDecisionReason)
assert_contains "$reason" "$A" "the denial names who is holding it"
assert_contains "$reason" "development database" "the denial says what it is"
assert_contains "$reason" "agentbus wait db" "the denial offers a way forward"
assert_equal 1 "$(locks_held)" "a denied command leaves nothing claimed behind it"

# ---- PostToolUse gives it straight back -------------------------------------

out=$(ab_hook post-bash "$(payload post-bash "sid=sess-a" "cwd=$REPO" id=tu-1)")
assert_equal 0 "$(locks_held)" "the claim is released when the command ends"
assert_no_file "$AGENTBUS_HOME/autoclaim/tu-1.json" "the record of it is cleaned up"

out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=tu-3)")
assert_allow "$out" "the second session gets it once the first has finished"
ab_hook post-bash "$(payload post-bash "sid=sess-b" "cwd=$WT2" id=tu-3)" > /dev/null

# ---- an explicit claim outranks an automatic one ----------------------------

ab sess-a claim db --why "long migration" > /dev/null
out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=tu-4)")
assert_deny "$out" "an explicit claim blocks the other session too"
reason=$(json_field "$out" hookSpecificOutput permissionDecisionReason)
assert_contains "$reason" "long migration" "the denial quotes why it was claimed"
ab sess-a release db > /dev/null
assert_equal 0 "$(locks_held)" "releasing it frees the resource"

# ---- forty concurrent pairs, exactly one denial each ------------------------

PA=$(payload bash "sid=sess-a" "cwd=$REPO" "cmd=$CMD" id=__ID__)
PB=$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=__ID__)

both=0
neither=0
for i in $(seq 1 40); do
  "$AB_ROOT/bin/agentbus" hook pre-tool <<< "${PA/__ID__/ca-$i}" > "$TEST_TMP/a.$i" 2>/dev/null &
  pa=$!
  "$AB_ROOT/bin/agentbus" hook pre-tool <<< "${PB/__ID__/cb-$i}" > "$TEST_TMP/b.$i" 2>/dev/null &
  pb=$!
  wait $pa
  wait $pb
  n=0
  grep -q '"deny"' "$TEST_TMP/a.$i" && n=$((n + 1))
  grep -q '"deny"' "$TEST_TMP/b.$i" && n=$((n + 1))
  [ "$n" -eq 2 ] && both=$((both + 1))
  [ "$n" -eq 0 ] && neither=$((neither + 1))
  "$AB_ROOT/bin/agentbus" hook post-bash \
    <<< "$(payload post-bash "sid=sess-a" "cwd=$REPO" "id=ca-$i")" > /dev/null
  "$AB_ROOT/bin/agentbus" hook post-bash \
    <<< "$(payload post-bash "sid=sess-b" "cwd=$WT2" "id=cb-$i")" > /dev/null
done

assert_equal 0 "$neither" "no concurrent pair was allowed through twice"
assert_equal 0 "$both" "no concurrent pair was refused twice"
assert_equal 0 "$(locks_held)" "nothing is left claimed after the race"

# ---- a session that ends drops what it was holding --------------------------

ab sess-a claim db --why "held across the end of the session" > /dev/null
assert_equal 1 "$(locks_held)" "the claim is held"
end_session sess-a
assert_equal 0 "$(locks_held)" "ending the session released it"
assert_equal 1 "$(cat "$AGENTBUS_HOME/live-count")" "and it is no longer counted live"

finish
