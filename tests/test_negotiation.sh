#!/usr/bin/env bash
# A block is the start of a negotiation, not the end of one.
#
# The bus could always record that somebody was waiting for a lock — `enqueue`
# has done it since the beginning. Two things were missing, and until Claude
# Code shipped session-to-session messaging only one of them could be fixed.
#
#   1. Nothing showed the queue to the party that could act on it. It went into
#      the task ledger, filtered to the WAITER's own row, so the holder — the
#      one agent who could hand the thing over — was the one agent never told.
#   2. Nothing could wake a holder to look. A posted note waited for its next
#      turn, which for an idle session is whenever its human comes back, so
#      "ask them" was advice that could not be taken. On 2026-09-04 a session
#      was blocked on the database at 14:38:31 and stepped past the guard with
#      AGENTBUS_OFF at 14:38:42.
#
# So this file asserts the two halves together: the queue is where the holder
# reads it, and the block tells the blocked agent to queue FIRST and then say
# so — in that order, because a message without a queue entry asks for something
# you have not arranged to receive, and waiting for a reply before queueing
# turns a three-second block into a round trip.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo negrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "the shared development database",
     "patterns": ["\\bpsql\\b", "\\balembic\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT=$(make_worktree "$REPO" negwt)

new_session sess-a "$REPO"     # holds it
new_session sess-b "$WT"       # wants it
A=$(ab sess-a name)
B=$(ab sess-b name)
cc_session sess-a "$A" idle
cc_session sess-b "$B" busy

ab sess-a claim db --why "reseeding personas" > /dev/null

# ---- what the blocked agent is told -----------------------------------------

out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT" \
  "cmd=psql -c 'select 1'" id=n-1)")
assert_deny "$out" "a database another session holds blocks the command"
R=$(json_field "$out" hookSpecificOutput permissionDecisionReason)

assert_contains "$R" "agentbus wait db" "the block offers the queue"
assert_contains "$R" "SendMessage tool → to \"$A\"" \
  "and an address the tool will take, read from Claude Code's own registry"
assert_contains "$R" "(idle)" \
  "with whether anybody is at the keyboard, which decides how long to expect"
assert_contains "$R" "I have queued for db" \
  "and the sentence to send, because asking is only cheap if it is written"

# Order is the argument. `wait` is what ends with the command running, the
# message is what makes it end sooner, and `status` is neither — it used to sit
# above both.
wait_at=$(printf '%s\n' "$R" | grep -n "agentbus wait db" | head -1 | cut -d: -f1)
tell_at=$(printf '%s\n' "$R" | grep -n "SendMessage tool" | head -1 | cut -d: -f1)
status_at=$(printf '%s\n' "$R" | grep -n "agentbus status" | head -1 | cut -d: -f1)
steal_at=$(printf '%s\n' "$R" | grep -n "agentbus claim db --steal" | head -1 | cut -d: -f1)
[ "$wait_at" -lt "$tell_at" ] \
  && _ok "queueing is offered before asking" \
  || _bad "queueing is offered before asking" "wait at $wait_at, tell at $tell_at"
[ "$tell_at" -lt "$status_at" ] \
  && _ok "and asking before merely reading the roster" \
  || _bad "and asking before merely reading the roster" \
          "tell at $tell_at, status at $status_at"
[ "$status_at" -lt "$steal_at" ] \
  && _ok "with taking it by force last of all" \
  || _bad "with taking it by force last of all" \
          "status at $status_at, steal at $steal_at"

# The steal line no longer suggests you can know they have finished without
# asking. You can find out: they answer in seconds.
assert_contains "$R" "when their session is gone" \
  "stealing is for a session that has gone, not for one you have not asked"
assert_not_contains "$R" "only when you know they have finished" \
  "and does not go on implying you could know that without asking"

# ---- and what the holder sees, unasked --------------------------------------

assert_not_contains "$(ab sess-a status)" "waiting:" \
  "with nobody queued, the holder's status says nothing about a queue"

# Queued and still waiting: the state the holder has to be able to see, so the
# waiter runs in the background and is stopped once it has been observed.
ab sess-b wait db --timeout 30 > /dev/null 2>&1 &
waiter=$!
sleep 2

held=$(ab sess-a status)
assert_contains "$held" "waiting: $B" \
  "once somebody queues, the holder can see it without being told"
assert_contains "$held" "reseeding personas" \
  "beside what the holder itself said it was doing"

kill "$waiter" 2>/dev/null
wait "$waiter" 2>/dev/null

# A waiter that gave up is not a waiter. The queue is on somebody's screen now,
# so a stale entry is not a harmless row in a file — it is a request to hand a
# resource over to an agent that has stopped asking for it.
ab sess-b wait db --timeout 1 > /dev/null 2>&1
assert_not_contains "$(ab sess-a status)" "waiting: $B" \
  "a waiter that timed out has left the queue"

# The same for a session that was closed while waiting, which cannot remove
# anything itself.
new_session sess-c "$WT"
C=$(ab sess-c name)
ab sess-c wait db --timeout 1 > /dev/null 2>&1 &
sleep 1
python3 - "$AGENTBUS_HOME" "$(ab sess-a name)" <<'PYEOF'
import json, os, sys
# Put sess-c back in the queue by hand: the point is a queue entry whose session
# is gone, and the CLI removes its own on the way out.
bus = sys.argv[1]
for name in os.listdir(os.path.join(bus, "locks")):
    path = os.path.join(bus, "locks", name)
    lock = json.load(open(path))
    if lock.get("resource") != "db":
        continue
    lock["queue"] = [{"sid": "sess-c", "agent": "ghost", "at": 0}]
    json.dump(lock, open(path, "w"))
PYEOF
assert_contains "$(ab sess-a status)" "waiting: ghost" \
  "a live session's entry is shown"
end_session sess-c
assert_not_contains "$(ab sess-a status)" "waiting: ghost" \
  "and one whose session has ended is not"

# ---- when a subagent is the one holding it ----------------------------------
#
# 64 of the 87 takeovers this plugin has recorded were held by a subagent, and
# SendMessage cannot address one: it reaches sessions. A block that printed the
# subagent's name would be sending the reader to somebody who does not exist as
# far as the tool is concerned.

ab sess-a release db > /dev/null
ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-1 agent_type=general-purpose)" > /dev/null
ab sess-a claim db --as "$A/1" --why "consuming fixtures" > /dev/null

out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT" \
  "cmd=psql -c 'select 1'" id=n-2)")
R=$(json_field "$out" hookSpecificOutput permissionDecisionReason)
assert_contains "$R" "$A/1" "the block names the subagent that is holding it"
assert_contains "$R" "SendMessage tool → to \"$A\"" \
  "and addresses the session, because that is what can be messaged"
assert_contains "$R" "it holds this through $A/1" \
  "saying which of its subagents the reader means"

finish
