#!/usr/bin/env bash
# Who a notice reaches, and who it does not.
#
# Until 3.0.0 this file tested three message scopes — one agent, one repository,
# the whole machine — because `agentbus post` had all three and none of them was
# tested. The verb is gone: messages between sessions are Claude Code's own
# SendMessage now, which wakes the reader, which the bus never could.
#
# What the bus still delivers is narrower and it is not messages. It is the small
# set of facts that silently invalidate what a session is in the middle of doing:
# somebody took a lock away from it, somebody declared part of the tree theirs,
# a service moved to another checkout, a name changed under the address its peers
# are holding. Nobody writes those sentences; the state does.
#
# Two scopes survive, and the line between them is still worth a file of its own:
#
#   addressed   the one party the fact is about — and a party is not a session,
#               because a lock taken by a subagent is held by that subagent
#   repository  everybody in the sender's repository, and nobody else
#
# Delivered notices are asserted through `additionalContext` on the hook that
# injects them, not by reading the event file: what matters is what reaches a
# session's context, and the event being written is not that.

. "$AB_ROOT/tests/lib.sh"

# Two SEPARATE repositories, not two worktrees of one. Worktrees share a repo
# key, so they could not tell "this repository" from "this machine" — every
# assertion below would pass with the scope check deleted.
ONE=$(make_repo msgone)
set_config "$ONE" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "the shared development database",
     "patterns": ["\\bpsql\\b", "\\balembic\\b"]}
  ]
}
JSON
commit_all "$ONE"
TWO=$(make_repo msgtwo)
set_config "$TWO" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "that project's own database",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$TWO"

new_session sess-a "$ONE"
new_session sess-b "$ONE"
new_session sess-c "$TWO"     # another project entirely
A=$(ab sess-a name)
B=$(ab sess-b name)
C=$(ab sess-c name)

# All three are in Claude Code's registry, because the redirect's whole job is
# to print an address that works and there is no address without one.
cc_session sess-a "$A"
cc_session sess-b "$B" busy
cc_session sess-c "$C"

# What a session is shown on its next turn, and only what it has not seen: the
# cursor advances, so each call answers "since last time".
inbox() {   # <sid> <cwd> → the text injected into that session's context
  json_field "$(ab_hook prompt-submit \
    "$(payload session "sid=$1" "cwd=$2")")" hookSpecificOutput additionalContext
}

inbox sess-a "$ONE" > /dev/null
inbox sess-b "$ONE" > /dev/null
inbox sess-c "$TWO" > /dev/null

# ---- the repository, and no further -----------------------------------------

ab sess-a own "migrations/**" --why "rewriting every one of them" > /dev/null

assert_contains "$(inbox sess-b "$ONE")" "migrations/**" \
  "a session in the same repository is told what somebody claimed"
assert_not_contains "$(inbox sess-c "$TWO")" "migrations/**" \
  "a session in another project is not — that is the line"
assert_not_contains "$(inbox sess-a "$ONE")" "migrations/**" \
  "and nobody is told their own news"

# ---- addressed: the party it is about, and only that party ------------------

ab sess-b claim db --why "loading fixtures" > /dev/null
inbox sess-a "$ONE" > /dev/null
inbox sess-b "$ONE" > /dev/null

ab sess-a claim db --steal --why "the migration cannot wait" > /dev/null

b=$(inbox sess-b "$ONE")
assert_contains "$b" "took 'db'" \
  "the party whose lock was taken is told, because it is about to act on a lie"
assert_contains "$b" "→ you" "and told that it is about them"
assert_not_contains "$(inbox sess-c "$TWO")" "took 'db'" \
  "a takeover in one repository is not another project's business"

# A lock nobody took from is not news: the ordinary claim above was not
# delivered to anybody, or every scoped run would cost two injections.
assert_not_contains "$b" "loading fixtures" \
  "an ordinary claim is not delivered — that is lock churn, not a fact about you"

# ---- what the reader is told this is ----------------------------------------

ab sess-a own "docs/**" > /dev/null
out=$(inbox sess-b "$ONE")
assert_contains "$out" "changed under you while you were working" \
  "the heading says what these are: not messages, but things that moved"
assert_not_contains "$out" "new message" \
  "and does not go on calling them messages"

# ---- read once -------------------------------------------------------------

assert_not_contains "$(inbox sess-b "$ONE")" "docs/**" \
  "what a session has been shown once is not shown again"

# ---- and the verb that used to do all this ----------------------------------
#
# `post` is kept for one release precisely so that an agent still carrying the
# habit is told where messages went, rather than meeting an unknown command.
# What it must never do again is look like it delivered something.

before=$(read_seq)
out=$(ab sess-a post "the fixtures are reseeded" 2>&1)
rc=$?
assert_equal 2 "$rc" "post refuses, rather than half-working"
assert_equal "$before" "$(read_seq)" "and writes nothing to the log at all"
assert_contains "$out" "no longer carries messages" "it says so"
assert_contains "$out" "SendMessage" "and names what does carry them"
assert_not_contains "$(inbox sess-b "$ONE")" "fixtures are reseeded" \
  "so nobody is told, which is the whole point of refusing loudly"

# The broadcast is the one shape SendMessage does not have, and the redirect says
# so with the addresses rather than pretending otherwise: this is the reseed
# case, which is exactly what the bus is for and exactly what it can no longer
# announce in one call.
assert_contains "$out" "one session at a time" \
  "the redirect admits a broadcast is now several calls"
assert_contains "$out" "$B" "and lists who would have heard it"
assert_not_contains "$out" "$C" \
  "scoped like the post it replaces: another project is not in the list"

out=$(ab sess-a post --all "the simulator is mine for an hour" 2>&1)
assert_contains "$out" "$C" "--all still means the machine, and lists it too"

out=$(ab sess-a post --to "$C" "your branch broke the shared migration" 2>&1)
assert_contains "$out" "SendMessage" "a directed post prints the call to make"
assert_contains "$out" "$C" "addressed to the name that was asked for"
assert_contains "$out" "your branch broke" \
  "carrying the text, so it can be pasted rather than retyped"

out=$(ab sess-a post --to "nobody-by-that-name" "hello" 2>&1)
assert_contains "$out" "ListAgents" \
  "and a name nothing answers to is sent to the tool that knows every name"

# ---- inbox, which is now a question with a different answer ------------------

out=$(ab sess-a inbox 2>&1)
assert_equal 2 "$?" "inbox refuses too"
assert_contains "$out" "arrives in this conversation" \
  "because that is where a message from another session actually lands"

# ---- and the conversation that replaced it is at least visible ---------------
#
# The bus stopped carrying messages; what it must not do is stop being the place
# a person can see the machine talking. `agentbus watch` and the board were that
# place, and a conversation leaving no trace anywhere is one nobody can review
# afterwards. So a SendMessage is recorded on its way past — recorded, never
# delivered a second time and never denied: a guard that can refuse a message is
# one that can wedge two agents mid-negotiation.

before=$(read_seq)
out=$(ab_hook pre-tool "$(payload sendmessage sid=sess-a "cwd=$ONE" \
  "to=$B" "text=the fixtures are reseeded, every id changed")")
assert_empty "$out" "a message is never denied, delayed or answered by the guard"
assert_equal $((before + 1)) "$(read_seq)" "and it is recorded once"

seen=$(events)
assert_contains "$seen" "msg" "under a kind of its own"
assert_contains "$seen" "→ $B" "naming who it was sent to"
assert_contains "$seen" "every id changed" "and what was said"

# Recorded is not delivered. The recipient has it already — it arrived in their
# conversation — and putting it in their context a second time would be exactly
# the duplication this release exists to remove.
assert_not_contains "$(inbox sess-b "$ONE")" "every id changed" \
  "and is not injected into the recipient's context on top of it"
assert_not_contains "$(inbox sess-c "$TWO")" "every id changed" \
  "nor anybody else's"

# A call with nothing to address is not a message.
before=$(read_seq)
ab_hook pre-tool "$(payload sendmessage sid=sess-a "cwd=$ONE" "text=hello")" \
  > /dev/null
assert_equal "$before" "$(read_seq)" \
  "a call with no recipient writes nothing rather than a row nobody can read"

finish
