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
# The line it prints is one that runs. It used to be `agentbus claim
# simulator,bundler`, a comma list `explicit_resources` splits and `resolve_lock`
# does not — so it wrote a lock called literally `simulator,bundler` and took
# neither of them.
assert_contains "$out" "agentbus claim bundler" "and how to take it"
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

# ---- the CLI locks the same key the guard does ------------------------------
#
# A `scope: "worktree"` resource is one lock per checkout, so the guard files it
# as `<name>@<digest of the root>`. Every CLI verb used the bare name, and the
# two therefore never met: `agentbus claim worktree` wrote a lock nothing
# consulted, a `git add` in the same checkout sailed straight past it, and
# `agentbus wait worktree` answered "claimed" while the block it was queueing
# for stood exactly where it was. The deny message's own last-resort advice,
# `agentbus claim <res> --steal`, was a no-op for these — and `worktree` is the
# one resource `agentbus init-repo` writes into every repository there is.

WT_CFG='{"resources":[
    {"name":"db","desc":"the shared development database","patterns":["\\bpsql\\b"]},
    {"name":"worktree","desc":"this checkout tree and index","scope":"worktree",
     "patterns":["\\bgit\\s+(add|commit|stash|reset)\\b"]}]}'
printf '%s' "$WT_CFG" > "$REPO/.claude/agent-bus.json"
mkdir -p "$WT2/.claude" && printf '%s' "$WT_CFG" > "$WT2/.claude/agent-bus.json"
ab sess-a doctor > /dev/null

# A worktree-scoped lock is per checkout, so the session contending for it has
# to be IN that checkout — the CLI decides from the session's own root, not from
# a cwd handed to it on a payload.
new_session sess-c "$REPO"

ab sess-a claim worktree --why "long rebase" > /dev/null
out=$(ab_hook pre-tool "$(payload bash "sid=sess-a" "cwd=$REPO" "cmd=git add -A" id=wt-1)")
assert_allow "$out" "the session that claimed it may still use it"
out=$(ab_hook pre-tool "$(payload bash "sid=sess-c" "cwd=$REPO" "cmd=git add -A" id=wt-2)")
assert_deny "$out" "and a session in the SAME checkout is now actually blocked"
assert_contains "$(json_field "$out" hookSpecificOutput permissionDecisionReason)" \
  "long rebase" "with the reason the claim was made for"

# Per checkout, so the other worktree is untouched — that is the whole point of
# the scope, and the fix must not have quietly made it global.
out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=git add -A" id=wt-3)")
assert_allow "$out" "while the same command in another checkout is not"
ab_hook post-bash "$(payload post-bash "sid=sess-b" "cwd=$WT2" id=wt-3)" > /dev/null

# The advice a block gives has to work, and `wait` must not report success
# against a lock it never looked at.
out=$(ab sess-c wait worktree --timeout 1 2>&1)
assert_contains "$out" "is held by" "wait queues against the real lock"
assert_not_contains "$out" "claimed 'worktree'" "rather than claiming instantly"
out=$(ab sess-c claim worktree --steal --why "they said they were done" 2>&1)
assert_contains "$out" "claimed" "and the steal the deny message advertises works"
out=$(ab_hook pre-tool "$(payload bash "sid=sess-a" "cwd=$REPO" "cmd=git add -A" id=wt-4)")
assert_deny "$out" "so the block really did change hands"

# Said in the vocabulary a person typed, not the key it is filed under.
assert_contains "$(lock_lines)" "took 'worktree'" "the log names the resource"
assert_not_contains "$(lock_lines)" "worktree@" "and never its internal key"

ab sess-c release worktree > /dev/null
assert_equal 0 "$(locks_held)" "releasing by name releases the scoped lock"

# A name that is not a declared resource stays literal: this is how a single
# file is taken, and that key is deliberately verbatim. It also has to reach the
# shell fast path — an explicit file claim is not a recent write and not a
# declared glob, so before this it was absent from hot-for and the block it is
# supposed to produce never fired at all outside Windows. Taking the file
# explicitly is exactly what every file-collision message tells the reader to do.
ab sess-a claim "file:$REPO/one.py" --why "mine" > /dev/null
out=$(ab_hook pre-tool "$(payload file "sid=sess-b" "cwd=$REPO" "path=$REPO/one.py")")
assert_deny "$out" "an explicit file claim still blocks the other session"
ab sess-a release "file:$REPO/one.py" > /dev/null

printf '%s' "$IMPLIES_CFG" > "$REPO/.claude/agent-bus.json"
printf '%s' "$IMPLIES_CFG" > "$WT2/.claude/agent-bus.json"
ab sess-a doctor > /dev/null

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

# ---- the escape hatch the block message offers actually works ---------------
#
# Every denial ends by offering `AGENTBUS_OFF=1 <command>`, and until
# 2026-08-01 that did nothing: the assignment takes effect in the shell that
# runs the command, and the hook has already decided by then, in another
# process, with the session's own environment. An agent reached for a staging
# database in another country, was queued behind a lock on the local one,
# read the message, followed it exactly — and was refused a second time. It
# was right and the tool was wrong.

ab sess-a claim db --why "seeding" > /dev/null
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" "cmd=$CMD" id=off-1)")
assert_deny "$out" "the command is refused, as it should be"
assert_contains "$(json_field "$out" hookSpecificOutput permissionDecisionReason)" \
  "AGENTBUS_OFF=1 <your command>" "and the message offers the way past"

out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=AGENTBUS_OFF=1 $CMD" id=off-2)")
assert_allow "$out" "and taking that offer really does get past"
assert_equal 1 "$(locks_held)" "without claiming anything on the way"

# It is an override, not a hole: the others can see it was taken.
assert_contains "$(ab sess-a inbox)$(lock_lines)$(ab sess-a status)" \
  "ran past the guard" "and stepping over a guard leaves a trace on the bus"

# A value that means "off" is not an opt-out.
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=AGENTBUS_OFF=0 $CMD" id=off-3)")
assert_deny "$out" "AGENTBUS_OFF=0 is not an opt-out"
ab sess-a release db > /dev/null

# ---- a resource can say when a command is not about it ----------------------
#
# `patterns` recognise the tool; a `db` resource describing the local Postgres
# matches every `psql` there is, including one aimed at staging. `unless` is how
# the config says which uses are not the guarded thing.

UNLESS_CFG='{"resources":[
    {"name":"db","desc":"the shared development database","patterns":["\\bpsql\\b"],
     "unless":["\\.postgres\\.database\\.azure\\.com"]}]}'
printf '%s' "$UNLESS_CFG" > "$REPO/.claude/agent-bus.json"
printf '%s' "$UNLESS_CFG" > "$WT2/.claude/agent-bus.json"
ab sess-a doctor > /dev/null

ab sess-a claim db --why "seeding" > /dev/null
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=psql \"postgresql://u@mkg.postgres.database.azure.com/db\" -c 'select 1'" id=un-1)")
assert_allow "$out" "a psql aimed at a host the config excludes is not guarded"
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=psql -h localhost -c 'select 1'" id=un-2)")
assert_deny "$out" "while the local one still is"
ab sess-a release db > /dev/null

printf '%s' "$IMPLIES_CFG" > "$REPO/.claude/agent-bus.json"
printf '%s' "$IMPLIES_CFG" > "$WT2/.claude/agent-bus.json"
ab sess-a doctor > /dev/null


# ---- one resource, several of the thing --------------------------------------
#
# A resource is one thing per machine, and sometimes the machine has three of
# them. On 2026-07-31 three agents shot a screen tour on three simulators, each
# with its own device, and the bus — holding one `simulator` lock — serialised
# work that did not contend at all. All three ran their Maestro commands with
# AGENTBUS_OFF=1 and said so on the bus: the tool right in principle, wrong in
# fact, and switched off by the people it was for.

KEY_CFG='{"resources":[
    {"name":"simulator","desc":"an iOS simulator","patterns":["\\bmaestro\\b"],
     "key":"--udid\\s+(\\S+)"}]}'
printf '%s' "$KEY_CFG" > "$REPO/.claude/agent-bus.json"
printf '%s' "$KEY_CFG" > "$WT2/.claude/agent-bus.json"
ab sess-a doctor > /dev/null

out=$(ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" \
  "cmd=maestro --udid 9E75406B test a.yaml" id=k-1)")
assert_allow "$out" "one agent takes one device"
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=maestro --udid 120A9276 test b.yaml" id=k-2)")
assert_allow "$out" "and another takes a different one, without waiting"
assert_equal 2 "$(locks_held)" "so both are held at once"

out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=maestro --udid 9E75406B test c.yaml" id=k-3)")
assert_deny "$out" "reaching for a device somebody else has is still refused"

# Not naming a device is not a way past: it means you do not know which one you
# are about to drive, which is a reason to wait rather than to proceed.
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=maestro test d.yaml" id=k-4)")
assert_deny "$out" "and a command naming no device contends with all of them"

# The whole resource can still be taken, and then it covers every instance.
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=k-1)" > /dev/null
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=k-2)" > /dev/null
assert_equal 0 "$(locks_held)" "the rig is free again"
ab sess-a claim simulator --why "all of them, for a long run" > /dev/null
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=maestro --udid FD8DA3E4 test e.yaml" id=k-5)")
assert_deny "$out" "claiming the resource itself covers every device"
ab sess-a release simulator > /dev/null

printf '%s' "$IMPLIES_CFG" > "$REPO/.claude/agent-bus.json"
printf '%s' "$IMPLIES_CFG" > "$WT2/.claude/agent-bus.json"
ab sess-a doctor > /dev/null

# ---- a session that ends drops what it was holding --------------------------

ab sess-a claim db --why "held across the end of the session" > /dev/null
assert_equal 1 "$(locks_held)" "the claim is held"
end_session sess-a
assert_equal 0 "$(locks_held)" "ending the session released it"
assert_equal 2 "$(cat "$AGENTBUS_HOME/live-count")" "and it is no longer counted live"


finish
