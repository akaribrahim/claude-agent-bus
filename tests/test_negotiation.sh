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
# reads it, and the stop tells the stopped agent to ask. Until 3.1.0 it said
# queue first and then say so, because the stop refused every time and the
# queue was the only thing that ended with the command running. Since then a
# second try goes through, so what the holder is asked is whether that would be
# all right — and the one who can answer that is asked before anything else.

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
assert_contains "$R" "is it all right if I go ahead now" \
  "and the sentence to send, because asking is only cheap if it is written"

# Order is the argument. Asking first, because the holder is the one who knows
# whether going ahead would break what they are doing; then the second try,
# which is what going ahead is; then the queue, for a command that can wait;
# and `status` last, because it changes nothing.
tell_at=$(printf '%s\n' "$R" | grep -n "SendMessage tool" | head -1 | cut -d: -f1)
again_at=$(printf '%s\n' "$R" | grep -n "<your command>" | head -1 | cut -d: -f1)
wait_at=$(printf '%s\n' "$R" | grep -n "agentbus wait db" | head -1 | cut -d: -f1)
status_at=$(printf '%s\n' "$R" | grep -n "agentbus status" | head -1 | cut -d: -f1)
[ "$tell_at" -lt "$again_at" ] \
  && _ok "asking is offered before going ahead" \
  || _bad "asking is offered before going ahead" "tell at $tell_at, again at $again_at"
[ "$again_at" -lt "$wait_at" ] \
  && _ok "and going ahead before queueing" \
  || _bad "and going ahead before queueing" "again at $again_at, wait at $wait_at"
[ "$wait_at" -lt "$status_at" ] \
  && _ok "and reading the roster last of all" \
  || _bad "and reading the roster last of all" "wait at $wait_at, status at $status_at"

# Taking it by force is not offered to somebody who can simply go ahead. It is
# still what the command-line refusal offers, where there is no second try — and
# there it is for a session that has gone, not for one you have not asked.
assert_not_contains "$R" "--steal" "a stop does not offer a takeover"
refused=$(ab sess-b claim db --why "mine" 2>&1)
assert_contains "$refused" "when their session is gone" \
  "the command-line refusal keeps it, for a session that has gone"
assert_not_contains "$refused" "only when you know they have finished" \
  "and does not go on implying you could know that without asking"
# Nor does it promise the answer. Measured 2026-09-05: a session quiet for fifty
# minutes ran the command it was sent twenty seconds after the message arrived,
# and then reported to its human instead of writing back. The wake is what this
# release rests on; the reply is the recipient's own judgement.
assert_not_contains "$R" "they answer" \
  "and does not promise a reply, which is not ours to promise"

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
