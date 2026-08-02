#!/usr/bin/env bash
# Who a message reaches — the three scopes, and the line between them.
#
# There are exactly three, and until this file existed none of them was tested
# directly. That is not a hypothetical gap: an agent updating this plugin posted
# three times to tell every session on the machine that the engine underneath
# them had changed, read "posted to everyone on this repo" as the broadcast it
# is not, and reached nobody at all. Every other session was in a different
# project. Nothing was wrong with the code and nothing failed; the message was
# simply delivered to the one session that already knew.
#
#   plain      everybody in the sender's repository, and nobody else. The
#              default, and the reason the bus is readable at all: another
#              project's chatter never arrives.
#   --to       one named agent, wherever they are. Crosses repositories,
#              because you had to know the name to type it.
#   --all      every live session on the machine. For things that are true of
#              the MACHINE and not of a repository — one simulator two projects
#              both drive, a database being reseeded, this plugin being replaced
#              under everybody.
#
# The asymmetry `--all` closes: presence was already machine-wide (`agentbus
# status` lists every session in every project) while messages were repository-
# wide, so an agent could see somebody it had no way to speak to.
#
# Delivered messages are asserted through `additionalContext` on the hook that
# injects them, not by reading the event file: what matters is what reaches a
# session's context, and the event being written is not that.

. "$AB_ROOT/tests/lib.sh"

# Two SEPARATE repositories, not two worktrees of one. Worktrees of a repository
# share a repo key, so they could not tell the plain and machine scopes apart —
# every assertion below would pass with the scope check deleted.
ONE=$(make_repo msgone)
TWO=$(make_repo msgtwo)

new_session sess-a "$ONE"     # sender
new_session sess-b "$ONE"     # same repository as the sender
new_session sess-c "$TWO"     # another project entirely
A=$(ab sess-a name)
B=$(ab sess-b name)
C=$(ab sess-c name)

# What a session is shown on its next turn, and only what it has not seen: the
# cursor advances, so each call answers "since last time".
inbox() {   # <sid> <cwd> → the text injected into that session's context
  json_field "$(ab_hook prompt-submit \
    "$(payload session "sid=$1" "cwd=$2")")" hookSpecificOutput additionalContext
}

# Drain anything the fixtures themselves emitted, so each case below reads only
# its own message.
inbox sess-a "$ONE" > /dev/null
inbox sess-b "$ONE" > /dev/null
inbox sess-c "$TWO" > /dev/null

# ---- plain: the sender's repository, and no further -------------------------

out=$(ab sess-a post "the fixtures are reseeded")
assert_contains "$out" "everyone on this repo" \
  "a plain post says the scope it actually has"

assert_contains "$(inbox sess-b "$ONE")" "the fixtures are reseeded" \
  "plain: a session in the same repository is told"
assert_not_contains "$(inbox sess-c "$TWO")" "the fixtures are reseeded" \
  "plain: a session in another project is NOT — this is the line --all crosses"
assert_not_contains "$(inbox sess-a "$ONE")" "the fixtures are reseeded" \
  "plain: and the sender is not told its own news"

# ---- --to: one agent, wherever they are -------------------------------------

out=$(ab sess-a post --to "$C" "your branch broke the shared migration")
assert_contains "$out" "posted to $C" "a directed post names its one reader"

assert_contains "$(inbox sess-c "$TWO")" "your branch broke the shared migration" \
  "--to: reaches an agent in another project, because you had to know the name"
assert_not_contains "$(inbox sess-b "$ONE")" "your branch broke the shared migration" \
  "--to: and nobody else, not even in the sender's own repository"

# ---- --all: every session on the machine ------------------------------------

out=$(ab sess-a post --all "the simulator is mine for the next hour")
assert_contains "$out" "every session on this machine" \
  "--all says so, rather than repeating the repo-scoped wording"
assert_contains "$out" "2 others" "and counts who will see it"
assert_contains "$out" "1 in another project" \
  "and how many of those are somewhere the plain form could not have reached"

b=$(inbox sess-b "$ONE")
c=$(inbox sess-c "$TWO")
assert_contains "$b" "the simulator is mine" "--all: the sender's own repository is told"
assert_contains "$c" "the simulator is mine" "--all: and so is another project"
assert_not_contains "$(inbox sess-a "$ONE")" "the simulator is mine" \
  "--all: the sender still does not hear itself"

# The reader in another project has no idea who this is without it: a sentence
# from a codebase you are not in is noise until it says which codebase.
assert_contains "$c" "(in $(session_field sess-a repo_label))" \
  "--all: a reader elsewhere is told which project it came from, by name"
assert_not_contains "$b" "(in " \
  "--all: and a reader in the sender's own repository is not — it already knows"

# ---- the two flags mean different things ------------------------------------

out=$(ab sess-a post --to "$C" --all "which is it" 2>&1)
assert_contains "$out" "Pick one" "--to and --all together are refused rather than guessed at"
assert_not_contains "$(inbox sess-c "$TWO")" "which is it" \
  "and nothing is sent while the sender decides"

finish
