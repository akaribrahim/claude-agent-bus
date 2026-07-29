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

# ---- the way out of a block is not itself blocked ---------------------------
#
# The denial above ends in two commands: `agentbus wait db` and, as a last
# resort, `agentbus claim db --steal`. Both name a resource on an agentbus
# command line, so until 2026-07-29 the guard claimed them like any other use
# and refused them — the plugin printing advice it would not let the reader
# follow. Three agents spent an afternoon negotiating turns by hand over the
# message bus because of it, having concluded the locks were unusable.
#
# The lock is still held by sess-a for every assertion here.

for escape in "agentbus wait db --why 'my turn next'" \
              "agentbus release db" \
              "agentbus claim db --steal --why 'they said they were done'"; do
  out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$escape" id=esc)")
  assert_allow "$out" "\`${escape%% --*}\` reaches the CLI while the lock is held"
done
assert_equal 1 "$(locks_held)" "and none of them claimed anything on the way past"

# Riding a real use in on the back of a pass-through verb does not work.
out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" \
  "cmd=agentbus wait db && psql -c 'select 1'" id=esc-2)")
assert_deny "$out" "but a command that really uses it, chained after, is still guarded"

out=$(ab sess-b claim db --steal --why "they said they were done" 2>&1)
assert_contains "$out" "claimed" "and the steal the message advertises actually works"
ab sess-b release db > /dev/null
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

# ---- `run` takes what the resource implies, as the guard already did --------
#
# `agentbus run simulator` used to take the simulator and nothing else, while a
# bare `maestro test` took the simulator *and* everything it implies, because
# the guard expands `implies` and the CLI did not. The careful command was the
# weaker one, and another session could re-serve a bundler mid-run.
#
# Reported from real use: an agent lost six minutes to it twice and then
# negotiated a manual protocol with the other session instead of using the tool.

IMPLIES_CFG='{"resources":[
    {"name":"db","desc":"the shared development database","patterns":["\\bpsql\\b"]},
    {"name":"bundler","desc":"the bundler on :9000","patterns":["\\bmetro\\b"]},
    {"name":"simulator","desc":"the one simulator","implies":["bundler"],
     "patterns":["\\bmaestro\\b"]}]}'
# Both checkouts: a config written only to the main one is invisible to the
# session working in the worktree.
printf '%s' "$IMPLIES_CFG" > "$REPO/.claude/agent-bus.json"
mkdir -p "$WT2/.claude" && printf '%s' "$IMPLIES_CFG" > "$WT2/.claude/agent-bus.json"
ab sess-b doctor > /dev/null

out=$(ab sess-b run simulator -- true 2>&1)
assert_contains "$out" "also taking bundler" "run says what else it is taking"
assert_contains "$out" "implies" "and why"

# While it runs, the other session must not be able to move the bundler.
ab sess-b claim simulator --why "holding for the test" > /dev/null
out=$(ab sess-a claim bundler --why "mine now" 2>&1)
assert_not_contains "$out" "note:" \
  "a resource that implies nothing says nothing extra"
ab sess-a release bundler > /dev/null
ab sess-b release simulator > /dev/null

out=$(ab sess-b claim simulator --why "just the simulator" 2>&1)
assert_contains "$out" "implies bundler" \
  "a deliberate claim is told what it has NOT taken"
assert_contains "$out" "agentbus claim simulator,bundler" "and how to take it"
ab sess-b release simulator > /dev/null

# ---- the log says what was taken, not only what was given back --------------
#
# On 2026-07-29 the day's stream held 219 releases and 7 takes. Every one of the
# 51 `agentbus run` invocations was silent going in and loud coming out: the
# guard takes the lock before the CLI is running, the CLI finds it already its
# own and says nothing, and only the release speaks — four times, once per
# implied resource. Somebody following `agentbus watch` saw a wall of things
# being handed back and not one of them being taken.

before=$(lock_lines | wc -l | tr -d ' ')
ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" \
  "cmd=agentbus run simulator -- true" id=lg-1)" > /dev/null
ab sess-b run simulator -- true > /dev/null 2>&1
new=$(lock_lines | tail -n +$((before + 1)))
assert_equal 1 "$(printf '%s\n' "$new" | grep -c '^took ')" \
  "a deliberate run puts exactly one line in for what it took"
assert_equal 1 "$(printf '%s\n' "$new" | grep -c '^released ')" \
  "and exactly one matching it when the command ends"
assert_contains "$new" "+bundler" "each naming everything that came with it"

before=$(lock_lines | wc -l | tr -d ' ')
ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=lg-2)" > /dev/null
ab_hook post-bash "$(payload post-bash "sid=sess-b" "cwd=$WT2" id=lg-2)" > /dev/null
assert_equal "$before" "$(lock_lines | wc -l | tr -d ' ')" \
  "while an automatic claim for one command says nothing in either direction"

before=$(lock_lines | wc -l | tr -d ' ')
ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=lg-3)" > /dev/null
ab sess-b release db > /dev/null
assert_equal "$before" "$(lock_lines | wc -l | tr -d ' ')" \
  "and handing that one back by hand does not invent a line to answer"

# ---- claim records that nothing will release are swept ---------------------
#
# The shell fast path decides whether PostToolUse is worth an engine start by
# asking whether *any* claim record exists. Twenty-two dead ones were found on
# the author's machine, left by the PostToolUse-on-error hole, and every Bash
# call in every session had been paying an engine start for them since.

out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=sweep-1)")
assert_allow "$out" "a guarded command claims something"
assert_file "$AGENTBUS_HOME/autoclaim/sweep-1.json" "and the claim is recorded"

# One that nothing ever came back for.
cp "$AGENTBUS_HOME/autoclaim/sweep-1.json" "$AGENTBUS_HOME/autoclaim/stale-1.json"
python3 -c "
import os, time
os.utime('$AGENTBUS_HOME/autoclaim/stale-1.json',
         (time.time() - 7200, time.time() - 7200))"

ab sess-b doctor > /dev/null      # any engine run sweeps
assert_no_file "$AGENTBUS_HOME/autoclaim/stale-1.json" \
  "a claim record nothing will release is swept"
assert_file "$AGENTBUS_HOME/autoclaim/sweep-1.json" \
  "while the one belonging to a command still running is left alone"
ab_hook post-bash "$(payload post-bash "sid=sess-b" "cwd=$WT2" id=sweep-1)" > /dev/null

# ---- a session that ends drops what it was holding --------------------------

ab sess-a claim db --why "held across the end of the session" > /dev/null
assert_equal 1 "$(locks_held)" "the claim is held"
end_session sess-a
assert_equal 0 "$(locks_held)" "ending the session released it"
assert_equal 1 "$(cat "$AGENTBUS_HOME/live-count")" "and it is no longer counted live"

finish
