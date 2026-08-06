#!/usr/bin/env bash
# One working copy, one repository key.
#
# The key is not a label. Locks are filed as `<repo_key>__<resource>.json` and
# `contending_locks` looks them up under the caller's OWN key; `interesting_to`
# gates every plain message on the sender's key matching the reader's; the board
# enumerates services per key. So two sessions in the same checkout that
# disagree about their key do not contend for the same database, cannot hear
# each other, and are each told the shared resource is free — which is the exact
# silent collision this plugin exists to prevent, produced by the plugin itself.
#
# That is what was on the live bus on 2026-08-06. `git rev-parse
# --git-common-dir` answers with a path relative to the CWD it was run from —
# `../../.git` from two directories down — and `git_facts` resolved it against
# the repository ROOT instead. A session whose cwd was N directories below its
# root therefore got its key and its label from a directory N levels ABOVE the
# repository: one session working in a subdirectory was keyed under the name of
# the folder holding the whole projects tree, while three sessions at the root of
# the same working copy held the real key.
#
# Nothing looked wrong because the ROOT it reported was correct throughout — the
# derivation only mishandled the common dir, and `--show-toplevel` is absolute.
# Only the key and the label were wrong, and those are the two fields nobody
# reads with their eyes.
#
# The invariant, stated once: every party working in the same repository has the
# same repo_key, whatever directory below it they happen to stand in, and
# whichever worktree of it they are in.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo keyrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db",
     "desc": "the shared development database",
     "why": "One database for every worktree.",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$REPO"

# A subdirectory of the working copy, and one three deep, because the wrong
# derivation climbed exactly as far above the root as the cwd was below it — so
# a one-level fixture and a three-level fixture fail with DIFFERENT wrong keys
# and a test that only tried one depth could be satisfied by an off-by-one fix.
mkdir -p "$REPO/packages/api/src"
SUB="$REPO/packages/api"
DEEP="$REPO/packages/api/src"

new_session sess-root "$REPO"
new_session sess-sub "$SUB"
new_session sess-deep "$DEEP"

ROOT_KEY=$(session_field sess-root repo_key)

# ---- the derivation ---------------------------------------------------------

# Asserted against the ROOT session's key rather than against a literal, so the
# assertion says the invariant ("these are one repository") and not the hash.
assert_equal "$ROOT_KEY" "$(session_field sess-sub repo_key)" \
  "a session two directories below the root has the root session's repo key"
assert_equal "$ROOT_KEY" "$(session_field sess-deep repo_key)" \
  "a session three directories below the root has it too"

assert_equal keyrepo "$(session_field sess-sub repo_label)" \
  "its label is the repository's own directory, not a component above it"
assert_equal keyrepo "$(session_field sess-deep repo_label)" \
  "and the same three directories down"

# `path:<sha>` is the honest answer for a directory that is not a repository at
# all. A subdirectory of a checkout is a repository, so reaching the fallback
# would be a different bug wearing the same clothes.
case "$(session_field sess-sub repo_key)" in
  path:*) _bad "a subdirectory of a checkout is not keyed by the path fallback" ;;
  *)      _ok  "a subdirectory of a checkout is not keyed by the path fallback" ;;
esac

# The root is what always looked right, so assert it stayed right: a fix that
# corrected the key by moving the recorded root would break every guard that
# compares checkouts, and would pass every assertion above.
assert_equal "$REPO" "$(session_field sess-sub root)" \
  "the recorded root is still the worktree root, not the subdirectory"
assert_equal "$SUB" "$(session_field sess-sub cwd)" \
  "and the recorded cwd is still the subdirectory the session is in"

# Asserted HERE, straight out of SessionStart, and not at the end of the file:
# only `register` can have written this, because no other hook has run yet. The
# same assertion further down passed with the stamp deleted, because by then the
# healing pass had stamped the record itself — it measured nothing.
assert_equal 2 "$(session_field sess-sub keyrev)" \
  "the derivation records which revision of itself wrote those fields"

# ---- what the wrong key cost: locks ----------------------------------------

# The failure as the agents met it. Not a restatement of the key comparison
# above: this goes through `lock_name` and `contending_locks`, which are what
# actually file and find a lock, and it is the assertion that would have caught
# the bug on the live bus.
# The precondition, asserted on the lock the command took rather than on the
# absence of a denial. `assert_allow` here would measure nothing: nobody holds
# the database at this point, so no mutation of the engine can make this one
# command be refused, and it would be green whatever broke. The lock count says
# the same thing and can fail.
ab_hook pre-tool "$(payload bash "sid=sess-root" "cwd=$REPO" \
  'cmd=psql -c "select 1"' id=tu-1)" > /dev/null
assert_equal 1 "$(locks_held)" \
  "the root session's guarded command takes the database"

out=$(ab_hook pre-tool "$(payload bash "sid=sess-sub" "cwd=$SUB" \
  'cmd=psql -c "select 1"' id=tu-2)")
assert_deny "$out" \
  "a session in a subdirectory contends for the database with one at the root"
reason=$(json_field "$out" hookSpecificOutput permissionDecisionReason)
assert_contains "$reason" "$(ab sess-root name)" \
  "and is told which session is holding it"

out=$(ab_hook pre-tool "$(payload bash "sid=sess-deep" "cwd=$DEEP" \
  'cmd=psql -c "select 1"' id=tu-3)")
assert_deny "$out" "so does a session three directories down"

ab_hook post-bash "$(payload post-bash "sid=sess-root" "cwd=$REPO" id=tu-1)" > /dev/null
assert_equal 0 "$(locks_held)" "the claim is given back"

# ---- what the wrong key cost: messages -------------------------------------

inbox() {   # <sid> <cwd> → the text injected into that session's context
  json_field "$(ab_hook prompt-submit \
    "$(payload session "sid=$1" "cwd=$2")")" hookSpecificOutput additionalContext
}
inbox sess-root "$REPO" > /dev/null      # start both cursors at the end
inbox sess-sub "$SUB" > /dev/null

ab sess-sub post "the fixtures are reseeded" > /dev/null
assert_contains "$(inbox sess-root "$REPO")" "the fixtures are reseeded" \
  "a plain post from a subdirectory reaches a session at the root"

ab sess-root post "the migration is running" > /dev/null
assert_contains "$(inbox sess-sub "$SUB")" "the migration is running" \
  "and a plain post from the root reaches the session in the subdirectory"

# ---- and what a wrong fix would cost: worktrees -----------------------------
#
# The key is derived from the common git dir precisely so that every worktree of
# one repository shares it — one index, one database, one key. The cheap way to
# make everything above pass is to derive the key from the root instead, and
# that silently un-shares it between worktrees, which is the failure the common
# dir was chosen to avoid. Nothing asserted this before; it is asserted here so
# the two halves cannot be traded against each other.
WT=$(make_worktree "$REPO" keywt)
mkdir -p "$WT/packages/api"
new_session sess-wt "$WT"
new_session sess-wtsub "$WT/packages/api"

assert_equal "$ROOT_KEY" "$(session_field sess-wt repo_key)" \
  "a linked worktree shares the repository key with the main worktree"
assert_equal "$ROOT_KEY" "$(session_field sess-wtsub repo_key)" \
  "and so does a subdirectory of that linked worktree"
assert_equal "$WT" "$(session_field sess-wt root)" \
  "while still recording its own root, which is how checkouts stay distinct"

# A separate repository must NOT collide, or "one key per repository" would be
# satisfied by handing every repository on the machine the same key.
#
# This is the same bug's other face, and the worse-sounding half. The wrong
# derivation climbed to a directory ABOVE the repository, so two unrelated
# projects side by side in one folder, each with a session at the same depth
# below its own root, both keyed under the folder that merely contains them:
# `<projects>/appA/packages/api` and `<projects>/appB/packages/api` became ONE
# key. That is false contention — appA's session blocked on appB's database lock
# — and it crossed `interesting_to` too, so each project's messages were
# delivered into the other's context.
OTHER=$(make_repo otherrepo)
mkdir -p "$OTHER/packages/api"
new_session sess-other "$OTHER/packages/api"
if [ "$ROOT_KEY" = "$(session_field sess-other repo_key)" ]; then
  _bad "a different repository gets a different key"
else
  _ok  "a different repository gets a different key"
fi
# Compared against the SUBDIRECTORY session, at the same depth under a shared
# parent, which is the pair that actually collided. Against the root session's
# key it did not, which is why the check above passed on the broken code.
if [ "$(session_field sess-sub repo_key)" = "$(session_field sess-other repo_key)" ]; then
  _bad "two projects with sessions at the same depth do not share a key"
else
  _ok  "two projects with sessions at the same depth do not share a key"
fi
assert_equal otherrepo "$(session_field sess-other repo_label)" \
  "and its own label, from its own directory"

# ---- the records already on the bus ----------------------------------------
#
# Fixing the derivation is not enough by itself. `register` runs at SessionStart
# and otherwise only when a session has no record at all, and `_follow_cwd`
# returns early when the payload's cwd equals the one on the record — which for
# a session that is not moving is every payload. So a chat that registered under
# the old derivation would carry its wrong key, and its immunity from its
# neighbours' locks, until its human closed it.
#
# The stale record is written directly here, which no other test in this suite
# does and which needs saying: it is the one thing that cannot be produced from
# the engine's own entry points, because the code that produced it no longer
# exists. Everything above goes through a hook or a verb.
stale() {   # <sid> — make a record look as the old derivation left it
  python3 -c "
import json, sys
p = '$AGENTBUS_HOME/sessions/$1.json'
rec = json.load(open(p))
rec['repo_key'] = 'Above:deadbe'
rec['repo_label'] = 'Above'
rec.pop('keyrev', None)
json.dump(rec, open(p, 'w'))
"
}

stale sess-sub
assert_equal Above:deadbe "$(session_field sess-sub repo_key)" \
  "the fixture really did leave a wrong key on the record"

# The next hook the session causes, with the cwd it already has on file — the
# case `_follow_cwd` used to return early from.
ab_hook prompt-submit "$(payload session "sid=sess-sub" "cwd=$SUB")" > /dev/null
assert_equal "$ROOT_KEY" "$(session_field sess-sub repo_key)" \
  "a wrong key already on a record is corrected on the session's next hook"
assert_equal keyrepo "$(session_field sess-sub repo_label)" \
  "and so is the label that came with it"

# "Correcting a derivation is not a relocation" is asserted on the PINNED record
# below and not here. Checked by mutation: a healer that moved an unpinned
# record's cwd is repaired by `_follow_cwd` on the very same call, which then
# re-derives from the payload's cwd — so an assertion here that the cwd had not
# moved could not be made to fail, and a green assertion that cannot fail is
# worth less than no assertion. A pin is what stops that repair, so a pinned
# record is the only place the property is observable.

# A pin is a statement about which directory the work is in. The key is not a
# statement at all — it is git's answer about that directory — so healing must
# survive a pin rather than be blocked by one, and must leave the pin standing.
ab sess-deep here "$DEEP" > /dev/null
assert_equal True "$(session_field sess-deep pinned)" "the session is pinned"
stale sess-deep
ab_hook prompt-submit "$(payload session "sid=sess-deep" "cwd=$DEEP")" > /dev/null
assert_equal "$ROOT_KEY" "$(session_field sess-deep repo_key)" \
  "a pinned session's wrong key is corrected too"
assert_equal True "$(session_field sess-deep pinned)" \
  "and it is still pinned afterwards"
assert_equal "$DEEP" "$(session_field sess-deep cwd)" \
  "in the directory it declared"

# Healed once, not on every hook. Re-deriving unconditionally would cost a git
# subprocess (~11ms) on every tool call in every session on the machine, for an
# answer that cannot change once it is right — and this plugin's shell fast path
# exists precisely because 40ms a call was judged too much to spend. So the stamp
# has to be TRUSTED, and the way to assert that is to leave a record's stamp
# current while making its key wrong: a healer that re-derived every time would
# repair it, and this one must not.
assert_equal 2 "$(session_field sess-sub keyrev)" \
  "the healed record carries the revision that repaired it"
python3 -c "
import json
p = '$AGENTBUS_HOME/sessions/sess-sub.json'
rec = json.load(open(p))
rec['repo_key'] = 'Above:deadbe'     # wrong key, but the stamp stays current
json.dump(rec, open(p, 'w'))
"
ab_hook prompt-submit "$(payload session "sid=sess-sub" "cwd=$SUB")" > /dev/null
assert_equal Above:deadbe "$(session_field sess-sub repo_key)" \
  "a record already carrying the current stamp is not re-derived again"

# ---- a cwd that is no longer there -----------------------------------------
#
# A worktree can be removed while the chat that was working in it is still open,
# and then the directory the record names does not exist. `git_facts` cannot run
# there and answers with the `path:` fallback — which would replace a key that is
# merely UNVERIFIABLE with one that is definitely wrong, and take the recorded
# root with it, pointing every guard at a checkout that is gone. So a record
# whose cwd has vanished is left exactly as it is.
GONE="$REPO/packages/temporary"
mkdir -p "$GONE"
new_session sess-gone "$GONE"
assert_equal "$ROOT_KEY" "$(session_field sess-gone repo_key)" \
  "a session in a directory that still exists is keyed normally"
rm -rf "$GONE"
python3 -c "
import json
p = '$AGENTBUS_HOME/sessions/sess-gone.json'
rec = json.load(open(p))
rec.pop('keyrev', None)      # force a heal attempt, key left correct
json.dump(rec, open(p, 'w'))
"
ab_hook prompt-submit "$(payload session "sid=sess-gone" "cwd=$GONE")" > /dev/null
assert_equal "$ROOT_KEY" "$(session_field sess-gone repo_key)" \
  "a record whose directory has been deleted keeps its key rather than guessing"
assert_equal "$REPO" "$(session_field sess-gone root)" \
  "and keeps the root, so the guards still compare against a real checkout"

# ---- and one level down, where nothing else would ever re-derive ------------
#
# A subagent's record is written once at SubagentStart, and `register_agent` is
# reached again only when the record has gone missing. So there is no equivalent
# of `register`'s SessionStart pass to fall back on: a subagent launched into a
# subdirectory would carry a wrong key for its whole life, take locks its own
# parent did not contend with, and be unable to hear the session that spawned it.
ab_hook subagent-start "$(payload subagent-start "sid=sess-root" "cwd=$SUB" \
  agent_id=sub-a agent_type=general-purpose)" > /dev/null
assert_equal "$ROOT_KEY" "$(agent_field sess-root sub-a repo_key)" \
  "a subagent in a subdirectory is keyed with the repository, not above it"

python3 -c "
import glob, json
for p in glob.glob('$AGENTBUS_HOME/agents/*.json'):
    rec = json.load(open(p))
    if rec.get('agent_id') != 'sub-a':
        continue
    rec['repo_key'] = 'Above:deadbe'
    rec['repo_label'] = 'Above'
    rec.pop('keyrev', None)
    json.dump(rec, open(p, 'w'))
"
assert_equal Above:deadbe "$(agent_field sess-root sub-a repo_key)" \
  "the fixture really did leave a wrong key on the subagent's record"

# Its own next hook, carrying the cwd already on its record.
ab_hook pre-tool "$(payload bash "sid=sess-root" "cwd=$SUB" cmd=ls id=tu-sub \
  agent_id=sub-a agent_type=general-purpose)" > /dev/null
assert_equal "$ROOT_KEY" "$(agent_field sess-root sub-a repo_key)" \
  "a subagent's wrong key is corrected on its own next hook"

finish
