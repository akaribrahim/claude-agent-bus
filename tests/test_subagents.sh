#!/usr/bin/env bash
# Subagents: two of them inside one session are two parties, not one.
#
# A subagent launched with the Task tool runs inside its parent's process and
# its hooks carry the parent's session id. Before this, everything that asked
# "is that somebody else?" compared session ids, so two subagents shared an
# identity: a lock one held read as "already yours" to the other and both walked
# straight through. Two agents driving one simulator — the failure this plugin
# exists to stop — happening inside a single session, silently.
#
# What tells them apart is `agent_id`, which Claude Code puts on every hook a
# subagent causes and on none the session itself causes. Verified against 2.1.220:
# SubagentStart, the subagent's own PreToolUse/PostToolUse/PostToolBatch, and
# SubagentStop all carry it.
#
# The parent must never conflict with its own subagent, in either direction: a
# parent that claimed something and then delegated would otherwise deadlock
# against the agent it is waiting for, and a backgrounded subagent would be
# blocked by the session that started it.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo subrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "simulator", "desc": "the one iOS simulator on this machine",
     "why": "One simulator. Two runs at once interleave taps and both fail.",
     "patterns": ["\\bmaestro\\b", "\\bsimctl\\b"]},
    {"name": "db", "desc": "the shared development database",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$REPO"

new_session sess-p "$REPO"      # the parent
new_session sess-other "$REPO"  # an unrelated session, so the guards are awake
P=$(ab sess-p name)

start_sub() {   # <agent id>
  ab_hook subagent-start "$(payload subagent-start "sid=sess-p" "cwd=$REPO" \
    "agent_id=$1" agent_type=general-purpose)" > /dev/null
}
stop_sub() {    # <agent id>
  ab_hook subagent-stop "$(payload subagent-stop "sid=sess-p" "cwd=$REPO" \
    "agent_id=$1")" > /dev/null
}
sub_cmd() {     # <agent id> <command> <tool use id> → the hook's stdout
  ab_hook pre-tool "$(payload bash "sid=sess-p" "cwd=$REPO" "cmd=$2" "id=$3" \
    "agent_id=$1" agent_type=general-purpose)"
}
parent_cmd() {  # <command> <tool use id> → the hook's stdout
  ab_hook pre-tool "$(payload bash "sid=sess-p" "cwd=$REPO" "cmd=$1" "id=$2")"
}
reason_of() { json_field "$1" hookSpecificOutput permissionDecisionReason; }

# ---- they exist, and they are visible --------------------------------------

start_sub sub-aaa
start_sub sub-bbb
assert_equal 2 "$(ls "$AGENTBUS_HOME"/agents/*.json 2>/dev/null | wc -l | tr -d ' ')" \
  "two subagents are registered under one session"

out=$(ab sess-other whois)
assert_contains "$out" "$P/1" "the first shows up in whois, named after its parent"
assert_contains "$out" "$P/2" "and so does the second"
assert_contains "$out" "general-purpose" "with what kind of agent it is"

out=$(ab sess-other status)
assert_contains "$out" "$P/1" "status lists them too"
out=$(ab_hook session-start "$(payload session sid=sess-other "cwd=$REPO" title=x)")
assert_contains "$(json_field "$out" hookSpecificOutput additionalContext)" "$P/1" \
  "and a session opening now is told they are there"

# ---- two subagents are two parties ------------------------------------------

out=$(sub_cmd sub-aaa "maestro test flows/checkout.yaml" t-a1)
assert_allow "$out" "the first subagent takes the simulator"
assert_equal 1 "$(locks_held)" "and the lock is really held"

out=$(sub_cmd sub-bbb "maestro test flows/login.yaml" t-b1)
assert_deny "$out" "the second is refused — this is the whole point"
r=$(reason_of "$out")
assert_contains "$r" "$P/1" "and told which agent has it"
assert_contains "$r" "simulator" "and what it is"
assert_contains "$r" "two agents of the same session" \
  "and framed as what it is — not as a disagreement about checkouts"
assert_contains "$r" "One simulator" "with the resource's own reason, which fits here"

# ---- a parent and its own subagent never block each other -------------------

out=$(parent_cmd "maestro test flows/smoke.yaml" t-p1)
assert_allow "$out" "the parent is not blocked by its own subagent"
out=$(sub_cmd sub-aaa "maestro test flows/again.yaml" t-a2)
assert_allow "$out" "and the subagent is not blocked by its parent"

# A backgrounded subagent whose parent claimed something first is the case that
# would deadlock: the parent is waiting for the agent it is blocking. Nothing
# else may hold it, or what is being measured is the sibling rule instead.
ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" agent_id=sub-aaa \
  "cmd=maestro test" id=t-a2)" > /dev/null
ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" \
  "cmd=maestro test" id=t-p1)" > /dev/null
assert_equal 0 "$(locks_held)" "nothing is held before the parent claims"
ab sess-p claim simulator --why "parent holds it" > /dev/null
out=$(sub_cmd sub-bbb "maestro test flows/x.yaml" t-b2)
assert_allow "$out" "a hard claim by the parent does not block its subagent"
ab sess-p release simulator > /dev/null

# ---- another session is still blocked, as it always was ---------------------

out=$(sub_cmd sub-aaa "maestro test flows/checkout.yaml" t-a3)
assert_allow "$out" "a subagent holds the simulator"
out=$(ab_hook pre-tool "$(payload bash sid=sess-other "cwd=$REPO" \
  "cmd=maestro test flows/other.yaml" id=t-o1)")
assert_deny "$out" "and another session is refused, naming the subagent"
assert_contains "$(reason_of "$out")" "$P/" "by its own name"
ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" \
  "cmd=maestro test" id=t-a3)" > /dev/null

# ---- `agentbus run` is decided in the hook, where the caller is known -------
#
# A subagent's Bash environment is byte-identical to its parent's, so by the
# time `agentbus run` is executing nothing in it knows which subagent is
# calling. If the claim were left to the CLI, two subagents would take the same
# rig and neither would be told.

out=$(sub_cmd sub-aaa "agentbus run simulator -- maestro test flows/a.yaml" t-a4)
assert_allow "$out" "one subagent's \`agentbus run\` takes the resource"
out=$(sub_cmd sub-bbb "agentbus run simulator -- maestro test flows/b.yaml" t-b4)
assert_deny "$out" "and the other's is refused"

out=$(sub_cmd sub-bbb "agentbus claim db --why 'migration'" t-b5)
assert_allow "$out" "a resource named on an agentbus command line is claimed"
assert_equal 2 "$(locks_held)" "so it is genuinely held"
out=$(sub_cmd sub-aaa "agentbus claim db" t-a5)
assert_deny "$out" "and the other subagent cannot take it"

# ---- messages reach a subagent in its own context ---------------------------

# The sibling reads FIRST, deliberately. Each party has its own cursor, and the
# way to prove that is to have somebody else take a turn in between: with one
# cursor per session, whoever read first would advance it past the message and
# the agent it was addressed to would never see it at all.
ab sess-other post --to "$P/1" "the simulator is wedged, reboot it first" > /dev/null
out=$(ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" \
  "agent_id=sub-bbb" agent_type=general-purpose "cmd=ls" id=t-b6)")
assert_not_contains "$(json_field "$out" hookSpecificOutput additionalContext)" \
  "simulator is wedged" "a message for one subagent is not shown to its sibling"

out=$(ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" \
  "agent_id=sub-aaa" agent_type=general-purpose "cmd=ls" id=t-a6)")
ctx=$(json_field "$out" hookSpecificOutput additionalContext)
assert_contains "$ctx" "simulator is wedged" \
  "and still reaches the one it was for, after the sibling has had a turn"
assert_contains "$ctx" "you" "marked as addressed to it"

# A parent can talk to its own subagent, which sharing a session id used to make
# impossible: the message was filtered out as the reader's own.
ab sess-p post --to "$P/2" "skip the login flow, it is being rewritten" > /dev/null
ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" "cmd=ls" id=t-p9)" > /dev/null
out=$(ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" \
  "agent_id=sub-bbb" agent_type=general-purpose "cmd=ls" id=t-b7)")
assert_contains "$(json_field "$out" hookSpecificOutput additionalContext)" \
  "skip the login flow" "a parent can address its own subagent"

# ---- a subagent is told its own name, once ---------------------------------
#
# It has no way to find this out for itself: its Bash environment is its
# parent's, so `agentbus post` is attributed to the parent. The agents on this
# machine had noticed and were writing "(agent /2)" into the body of every
# message by hand. The tool should do that, not the agent.

start_sub sub-ccc
out=$(ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" \
  "agent_id=sub-ccc" agent_type=general-purpose "cmd=ls" id=t-c1)")
ctx=$(json_field "$out" hookSpecificOutput additionalContext)
assert_contains "$ctx" "you are \`$P/3\`" "a subagent is told the name others see"
assert_contains "$ctx" "agentbus post --as $P/3" "and how to sign with it"

out=$(ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" \
  "agent_id=sub-ccc" agent_type=general-purpose "cmd=ls" id=t-c2)")
assert_not_contains "$(json_field "$out" hookSpecificOutput additionalContext)" \
  "on this machine you are" "and told only once"

out=$(ab_hook post-batch "$(payload batch sid=sess-p "cwd=$REPO" "cmd=ls" id=t-p8)")
assert_not_contains "$(json_field "$out" hookSpecificOutput additionalContext)" \
  "on this machine you are" "the session itself is never told this"

# ---- and can sign with it ---------------------------------------------------

ab sess-p post --as "$P/3" "the checkout probe is mine, do not rerun it" > /dev/null
out=$(ab sess-other inbox)
assert_contains "$out" "$P/3" "a message signed as a subagent is attributed to it"
assert_contains "$out" "checkout probe" "with what it said"

out=$(ab sess-p post --as "someone-elses-agent" "not me" 2>&1)
assert_contains "$out" "not you or one of your subagents" \
  "and nobody can speak as an agent that is not theirs"
out=$(ab sess-other inbox)
assert_not_contains "$out" "not me" "so the message is not sent at all"

# ---- when a subagent stops, it lets go --------------------------------------

held_before=$(locks_held)
stop_sub sub-bbb
assert_equal $((held_before - 1)) "$(locks_held)" \
  "stopping a subagent releases what it was holding"
assert_not_contains "$(ab sess-other whois)" "$P/2" "and it is gone from the roster"

out=$(sub_cmd sub-aaa "agentbus claim db" t-a7)
assert_allow "$out" "so the resource is free for the other one"

# ---- and when the session ends, they all go ---------------------------------

end_session sess-p
assert_equal 0 "$(ls "$AGENTBUS_HOME"/agents/*.json 2>/dev/null | wc -l | tr -d ' ')" \
  "ending the session takes its subagents with it"
assert_equal 0 "$(locks_held)" "and everything they held"

finish
