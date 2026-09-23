#!/usr/bin/env bash
# A guard stops a command once. The first try is refused with who is in the way
# and how to ask them; the same party trying again on the same thing goes
# through, holding nothing, and whoever it lands on is told.
#
# Since 3.1.0. Until then every guard refused outright, and from 2026-08-18 to
# 2026-09-22 the log recorded 139 lock and serving refusals against 212 steps
# over them with AGENTBUS_OFF, and 25 port refusals against 51. The stop is kept
# for what it is worth — the moment an agent learns who else is there and how to
# reach them — and the refusal that agents walked around anyway is gone.

# The window the engine ships with; lib.sh sets it to 0 for every other file.
export AGENTBUS_TOLD_FOR=1800
. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo oncerepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db",
     "desc": "the shared development database",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT2=$(make_worktree "$REPO" oncewt2)

new_session sess-a "$REPO"
new_session sess-b "$WT2"
new_session sess-c "$WT2"
A=$(ab sess-a name)
B=$(ab sess-b name)

reason_of() { json_field "$1" hookSpecificOutput permissionDecisionReason; }
pre() {      # <sid> <cwd> <cmd> <tool use id> → the hook's stdout
  ab_hook pre-tool "$(payload bash "sid=$1" "cwd=$2" "cmd=$3" "id=$4")"
}

# ---- the first try is stopped, and says who to ask --------------------------

ab sess-a claim db --why "reseeding personas" > /dev/null
out=$(pre sess-b "$WT2" 'psql -c "select 1"' once-1)
assert_deny "$out" "the first try on a held resource is stopped"
reason=$(reason_of "$out")
assert_contains "$reason" "STOPPED ONCE" "and the stop says it is a first one"
assert_contains "$reason" "SendMessage" "it says how to ask the holder"
assert_contains "$reason" "is it all right if I go ahead" \
  "and suggests asking permission, not announcing a queue"
assert_contains "$reason" "<your command>" "it offers the second try"
assert_contains "$reason" "$A is told" "and says the holder will hear of it"
assert_not_contains "$reason" "AGENTBUS_OFF" \
  "it no longer sends anybody to the opt-out"
assert_equal 1 "$(locks_held)" "stopping it claimed nothing"

# ---- the second try goes through, and the holder is told --------------------
#
# A different spelling of the same command: an agent that comes back with its
# output piped has heeded the same stop, so it is keyed by what was in the way
# and not by the command line.

out=$(pre sess-b "$WT2" 'psql -c "select 1" 2>&1 | tail -3' once-2)
assert_allow "$out" "the second try by the same party goes through"
assert_equal 1 "$(locks_held)" "holding nothing — the lock is still only the holder's"
assert_contains "$(ab sess-a status)" "reseeding personas" \
  "and it is still the holder's lock, with the holder's reason"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=once-2)" > /dev/null

held_told=$(told sess-a "$REPO")
assert_contains "$held_told" "went ahead on 'db' on a second try" \
  "the holder is told somebody went ahead"
assert_contains "$held_told" "$B" "and who"
assert_not_contains "$(told sess-c "$WT2")" "went ahead on 'db'" \
  "and it is told to the holder, not announced to everybody"

# Going through once is not a pass for good: the next command on the same stop
# goes through too, for as long as it is the same stop.
out=$(pre sess-b "$WT2" 'psql -c "select 2"' once-3)
assert_allow "$out" "a later command on the same stop goes through as well"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=once-3)" > /dev/null

# ---- being told is one party's, not the machine's ---------------------------

out=$(pre sess-c "$WT2" 'psql -c "select 1"' once-4)
assert_deny "$out" "another session trying the same thing is stopped on its own first try"

out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  'cmd=psql -c "select 1"' agent_id=sub-one agent_type=general-purpose id=once-5)")
assert_deny "$out" "and so is a subagent of the session that was told"

# ---- a different stop is told again -----------------------------------------

ab sess-a release db > /dev/null
ab sess-a claim db --why "reseeding again" > /dev/null
out=$(pre sess-b "$WT2" 'psql -c "select 1"' once-6)
assert_deny "$out" \
  "a lock let go and taken again is a new stop, even by the same holder"
out=$(pre sess-b "$WT2" 'psql -c "select 1"' once-7)
assert_allow "$out" "which the second try gets past in turn"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=once-7)" > /dev/null

# ---- and the same stop, after long enough, is told again --------------------

for f in "$AGENTBUS_HOME"/told/*.json; do
  python3 -c "
import os, sys, time
os.utime(sys.argv[1], (time.time() - 7200, time.time() - 7200))
import json
rec = json.load(open(sys.argv[1]))
rec['at'] = time.time() - 7200
json.dump(rec, open(sys.argv[1], 'w'))" "$f"
done
out=$(pre sess-b "$WT2" 'psql -c "select 1"' once-8)
assert_deny "$out" "a stop heeded two hours ago is told again"
ab sess-a release db > /dev/null

# ---- once the thing is free, there is nothing to stop -----------------------

out=$(pre sess-b "$WT2" 'psql -c "select 1"' once-9)
assert_allow "$out" "a free resource is taken as ever, with no stop at all"
assert_equal 1 "$(locks_held)" "and it is claimed for the command, as ever"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=once-9)" > /dev/null

# ---- an edit is stopped once as well ----------------------------------------

new_session sess-d "$REPO"
mkdir -p "$REPO/api" && : > "$REPO/api/service.py"
ab sess-a own "api/**" --why "backend rebuild" > /dev/null
edit() {   # <sid> <cwd> <path> <tool use id>
  ab_hook pre-tool "$(payload file "sid=$1" "cwd=$2" "path=$3" "id=$4")"
}
out=$(edit sess-d "$REPO" "$REPO/api/service.py" once-10)
assert_deny "$out" "an edit in somebody's declared scope is stopped the first time"
assert_contains "$(reason_of "$out")" "make the same edit again" \
  "and the stop says the second try goes through"
out=$(edit sess-d "$REPO" "$REPO/api/service.py" once-11)
assert_allow "$out" "and the second try at the same edit goes through"
assert_contains "$(told sess-a "$REPO")" "edited api/service.py on a second try" \
  "and the owner is told"
ab sess-a disown "api/**" > /dev/null 2>&1

# ---- and the owner of the machine can have the old refusal back -------------

ab sess-a claim db --why "strict this time" > /dev/null
out=$(AGENTBUS_TOLD_FOR=0 pre sess-b "$WT2" 'psql -c "select 1"' once-12)
assert_deny "$out" "with AGENTBUS_TOLD_FOR=0 the first try is stopped"
out=$(AGENTBUS_TOLD_FOR=0 pre sess-b "$WT2" 'psql -c "select 1"' once-13)
assert_deny "$out" "and so is the second: every stop refuses, as before 3.1.0"
ab sess-a release db > /dev/null

finish
