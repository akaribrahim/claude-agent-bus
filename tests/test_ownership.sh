#!/usr/bin/env bash
# Declared ownership: saying up front which part of the tree is yours.
#
# The file guard that already existed is reactive — it blocks a write to a file
# somebody touched in the last fifteen minutes. That is one edit too late, and
# it cannot say "stay out of api/" before anybody has been there. This is the
# declared form, and the two halves that have to work are enforcement and
# expiry: a declaration nobody can see is theatre, and one that outlives the
# session that made it is a trap for whoever comes next.
#
# The verdict differs by checkout on purpose. Two sessions editing one path in
# two branches is what branches are for, so that is a note; inside one checkout
# it is a genuine overwrite, so that is a denial. `--strict` is how an owner
# says the cross-worktree case matters to them too.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo ownrepo)
mkdir -p "$REPO/api/inner" "$REPO/web"
commit_all "$REPO"
WT2=$(make_worktree "$REPO" ownwt2)
mkdir -p "$WT2/api/inner" "$WT2/web"

new_session sess-a "$REPO"     # the owner
new_session sess-b "$REPO"     # same checkout as the owner
new_session sess-c "$WT2"      # a different checkout of the same repo
A=$(ab sess-a name)
assert_equal 3 "$(cat "$AGENTBUS_HOME/live-count")" "three sessions"

edit() {   # <session id> <cwd> <absolute path> → the hook's stdout
  ab_hook pre-tool "$(payload file "sid=$1" "cwd=$2" "path=$3")"
}

# Straight into the engine, skipping the shell fast path — the route Windows
# takes, where nothing gates the guard. Some of what follows cannot be seen
# through `edit` at all: a session's own declaration is deliberately left out of
# its own hot-for file, so the fast path exits before the engine is ever asked
# and an assertion about the owner would pass without the code being reached.
edit_direct() {   # <session id> <cwd> <absolute path> → the hook's stdout
  ab_engine pre-tool "$(payload file "sid=$1" "cwd=$2" "path=$3")"
}
reason_of() { json_field "$1" hookSpecificOutput permissionDecisionReason; }
note_of()   { json_field "$1" hookSpecificOutput additionalContext; }

# ---- before anyone declares anything, nothing is guarded --------------------

out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_allow "$out" "an unclaimed file is not guarded"
assert_empty "$out" "and nothing is said about it"

# ---- declaring a scope ------------------------------------------------------

out=$(ab sess-a own "api/**" --why "backend rebuild" 2>&1)
assert_contains "$out" "you now own" "own reports back"
assert_contains "$out" "api/**" "and says what"
assert_contains "$out" "backend rebuild" "and why"
assert_file "$AGENTBUS_HOME/owns/sess-a.json" "the declaration is recorded"

# The fast path greps a tool payload against hot-for/<sid> and stops there when
# nothing matches. Unless a declaration puts its fixed prefix in that file, the
# engine is never woken and the guard never runs — so this is not a detail.
assert_contains "$(cat "$AGENTBUS_HOME/hot-for/sess-b")" "api/" \
  "the fast path is told to wake the engine for this scope"

# ---- inside one checkout it is a denial -------------------------------------

out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_deny "$out" "another session in the same checkout is denied"
r=$(reason_of "$out")
assert_contains "$r" "$A" "the denial names the owner"
assert_contains "$r" "api/**" "and the glob they claimed"
assert_contains "$r" "backend rebuild" "and their reason"
assert_contains "$r" "branch main" "and their branch"
assert_contains "$r" "agentbus post --to $A" "and offers asking them"
assert_contains "$r" "agentbus claim 'file:" "and offers taking it once agreed"

out=$(edit sess-b "$REPO" "$REPO/api/inner/deep.py")
assert_deny "$out" "the scope covers subdirectories"

out=$(edit sess-b "$REPO" "$REPO/web/page.tsx")
assert_allow "$out" "a file outside the scope is untouched"
assert_empty "$out" "and nothing is said about it"

# ---- the owner is not blocked by their own declaration ----------------------

out=$(edit sess-a "$REPO" "$REPO/api/service.py")
assert_allow "$out" "the owner writes freely"
assert_empty "$out" "with nothing said"

# The one above is answered by the fast path exiting, so it would pass even if
# the engine blocked the owner. This asks the engine directly, which is what
# every hook does on a host without bash.
out=$(edit_direct sess-a "$REPO" "$REPO/api/service.py")
assert_allow "$out" "the owner writes freely with no fast path either"
assert_empty "$out" "and the engine says nothing to them"

out=$(edit_direct sess-b "$REPO" "$REPO/api/service.py")
assert_deny "$out" "while the engine still blocks everyone else"

# ---- a different worktree is warned, not stopped ----------------------------

out=$(edit sess-c "$WT2" "$WT2/api/service.py")
assert_allow "$out" "a different worktree is allowed through"
n=$(note_of "$out")
assert_contains "$n" "$A" "but is told who declared it"
assert_contains "$n" "different worktree" "and why it is only a warning"
assert_contains "$n" "merge time" "and what it will cost later"

# ---- exactly one thing is ever printed --------------------------------------
#
# The reactive collision check would have its own note for this file too: the
# owner wrote it recently, in another worktree of the same repository. If both
# spoke, stdout would carry two JSON documents and the session's view of the
# hook result would be corrupt. `ab_hook` parses every hook's output on every
# call in this suite, so a second document fails here rather than in somebody's
# session.

# A file of its own: recording a write against one the later cases use would
# put it inside the reactive guard's fifteen-minute window too, and those cases
# would then pass or fail for a reason that has nothing to do with ownership.
ab_hook record-write "$(payload write sid=sess-a "cwd=$REPO" \
  "path=$REPO/api/overlap.py")" > /dev/null
out=$(edit sess-c "$WT2" "$WT2/api/overlap.py")
assert_allow "$out" "the overlapping case is still allowed"
assert_contains "$(note_of "$out")" "declared" \
  "and it is the ownership note that speaks, not the collision one"
assert_equal 1 "$(printf '%s' "$out" | grep -c 'hookSpecificOutput')" \
  "exactly one hook result is printed"

# ---- --strict extends the denial across worktrees ---------------------------

ab sess-a own "api/**" --why "restructuring, do not touch" --strict > /dev/null
out=$(edit sess-c "$WT2" "$WT2/api/service.py")
assert_deny "$out" "--strict blocks the other worktree too"
r=$(reason_of "$out")
assert_contains "$r" "restructuring" "with the owner's reason"
assert_contains "$r" "not yours" "and an explicit note that the checkout differs"
assert_contains "$r" "strict" "and why that is not the end of the matter"

out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_deny "$out" "and the same checkout is still denied"

# ---- an explicit file claim is the agreed way through -----------------------

ab sess-b claim "file:$REPO/api/service.py" --why "agreed with $A" > /dev/null
out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_allow "$out" "taking the file explicitly lifts the block"
ab sess-b release "file:$REPO/api/service.py" > /dev/null
out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_deny "$out" "and giving it back restores the block"
assert_contains "$(reason_of "$out")" "declared this part of the tree" \
  "and it is the ownership block that came back, not some other one"

# ---- what everyone can see --------------------------------------------------

out=$(ab sess-b own --list)
assert_contains "$out" "$A" "own --list names the owner"
assert_contains "$out" "api/** (strict)" "and shows the declaration"

out=$(ab sess-b status)
assert_contains "$out" "Declared ownership:" "status has an ownership section"
assert_contains "$out" "api/**" "listing the scope"

out=$(ab_hook session-start "$(payload session sid=sess-b "cwd=$REPO" title=x)")
assert_contains "$(json_field "$out" hookSpecificOutput additionalContext)" \
  "owns: api/**" "a session starting up is told what is spoken for"

# ---- disown gives it back ---------------------------------------------------

out=$(ab sess-a disown "api/**")
assert_contains "$out" "released" "disown reports back"
assert_no_file "$AGENTBUS_HOME/owns/sess-a.json" "the last declaration is removed"
out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_allow "$out" "and the block is gone"

ab sess-a own "api/**" "web/*.tsx" --why "two scopes" > /dev/null
out=$(ab sess-a disown --all)
assert_contains "$out" "api/**" "disown --all names what it dropped"
assert_contains "$out" "web/*.tsx" "including the second scope"
out=$(edit sess-b "$REPO" "$REPO/web/page.tsx")
assert_allow "$out" "and both blocks are gone"

# ---- a glob with no wildcard means the directory ----------------------------
#
# `agentbus own api` is what a person types when they mean the whole of api/.
# Owning exactly one file called `api` and nothing under it would be a silent
# no-op — the worst outcome for a guard somebody believed they had set.

ab sess-a own api --why "plain directory" > /dev/null
out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_deny "$out" "a wildcard-free glob covers the directory under it"
out=$(edit sess-b "$REPO" "$REPO/web/page.tsx")
assert_allow "$out" "and nothing else"
ab sess-a disown --all > /dev/null

# ---- ownership dies with the session ----------------------------------------

ab sess-a own "api/**" --why "held to the end" > /dev/null
out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_deny "$out" "the declaration is in force"
end_session sess-a
assert_no_file "$AGENTBUS_HOME/owns/sess-a.json" \
  "ending the session removes the declaration"
out=$(edit sess-b "$REPO" "$REPO/api/service.py")
assert_allow "$out" "and the block dies with it"

finish
