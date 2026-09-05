#!/usr/bin/env bash
# What the session-start banner tells an agent about the others.
#
# Since 3.0.0 the banner has one job it did not have before: hand the reader an
# address that Claude Code's `SendMessage` tool accepts. Everything the new block
# messages promise rests on that address being right, and the way it goes wrong
# is silent — a message sent to a name nobody answers to, by an agent that
# believes it has asked and is waiting for a reply that cannot come.
#
# The falsifier for the whole address change is in here: the DIVERGENT session.
# The bus names a session from its branch when its chat has no title; Claude Code
# names it from its directory. On the machine this was written for, four of five
# sessions matched and the fifth did not — and the fifth is the one a wrong
# implementation still gets wrong while every other assertion passes.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo rosterrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "the shared development database",
     "patterns": ["\\bpsql\\b", "\\balembic\\b"]}
  ]
}
JSON
commit_all "$REPO"

new_session sess-mine "$REPO"
new_session sess-same "$REPO"
new_session sess-diff "$REPO"
new_session sess-none "$REPO"

SAME=$(session_field sess-same agent)
DIFF=$(session_field sess-diff agent)

# Two of the three peers are in Claude Code's registry: one under the name the
# bus gave it, one under a different one. The third is in no registry at all,
# which is what a session Claude Code has not registered looks like.
cc_session sess-same "$SAME" idle
cc_session sess-diff "a-different-name" busy
cc_session sess-stranger "somebody-else" idle

out=$(ab_hook session-start "$(payload session sid=sess-mine "cwd=$REPO")")
BANNER=$(json_field "$out" hookSpecificOutput additionalContext)

assert_contains "$BANNER" "SendMessage → to \"$SAME\"" \
  "a peer whose two names agree is addressed by that name"
assert_contains "$BANNER" 'SendMessage → to "a-different-name"' \
  "a peer whose names diverge is addressed by Claude Code's name"

# The falsifier, stated as its own assertion rather than left implicit: the bus's
# own name for that session must not appear as an address, because sending to it
# reaches nobody.
assert_not_contains "$BANNER" "SendMessage → to \"$DIFF\"" \
  "and never by the name only this plugin uses"

assert_contains "$BANNER" "run ListAgents" \
  "a peer with no registry entry is not given an invented address"

assert_contains "$BANNER" "(idle)" \
  "the roster says whether a peer will read a message soon"
assert_contains "$BANNER" "(busy)" \
  "and reports each peer's own status, not one summary"

# A live session this bus has never heard of can still be messaged, so leaving it
# out would tell the reader the machine is emptier than it is.
assert_contains "$BANNER" "somebody-else" \
  "a live session with no bus record is named as reachable"
assert_contains "$BANNER" "ListAgents knows the full list" \
  "and the roster admits it is not the whole world"

# The rules paragraph is where an agent learns where messages go. If it still
# advertises the bus's own verb, every session on the machine learns the wrong
# thing at start-up — which is how the old habit would outlive the change.
assert_contains "$BANNER" "SendMessage tool" \
  "the rules say which tool carries messages"
assert_not_contains "$BANNER" "agentbus post" \
  "and do not advertise the verb that no longer delivers"
assert_contains "$BANNER" "agentbus wait" \
  "the rules point at the queue, which is what replaces asking and waiting"
assert_contains "$BANNER" "subagent" \
  "and warn that a subagent is reached through its session"

# `agentbus status` is the other place an agent looks, and it has to carry the
# same address. A roster that names somebody without saying how to reach them is
# a roster that gets a message sent to a name nobody answers to.
ST=$(ab sess-mine status)
assert_contains "$ST" "SendMessage → to \"$SAME\"" \
  "status prints the address beside the peer it names"
assert_contains "$ST" 'SendMessage → to "a-different-name"' \
  "including for the session whose two names disagree"
assert_not_contains "$ST" "SendMessage → to \"$DIFF\"" \
  "and never the name only this plugin uses"

finish
