#!/usr/bin/env bash
# Who is acting, and where they are working — the two precedence orders, one
# case per rule.
#
# Thirteen functions in the engine used to answer those two questions between
# them, each added to close one defect and none of them removing another. Six of
# the twenty-two defects this plugin has produced came from that spine. This file
# states the answers as two orders and pins them rule by rule, so that the
# refactor which collapsed the thirteen into `resolve_party` either kept every
# rule or failed here by name. It is still the specification: the orders live
# here and in that one function, and nowhere a third time.
#
#   WHO IS ACTING.  The `agent_id` on the payload, if there is one. Otherwise an
#   explicit `--as <name>` naming one of this session's own subagents, honoured
#   by the verb rather than by the resolver. Otherwise the party hint the guard
#   left for this exact command line, if the caller is the command-line tool and
#   a hint exists. Otherwise the session.
#
#   WHERE THEY ARE WORKING.  A path the command itself names (`git -C <path>`),
#   for that command only, without moving any record, and above every
#   declaration below it. Otherwise, if the acting party is a subagent, that
#   subagent's own recorded root — the tree it declared with `agentbus here --as
#   <name>`, or else the tree inferred for it, updated when a payload's cwd
#   differs both from the record and from the parent's cwd, because a cwd equal
#   to the parent's is what a subagent reports when it has never changed
#   directory and therefore carries no information. Either way it outranks the
#   session's pin. Otherwise the root pinned by `agentbus here`, until `here` is
#   run elsewhere. Otherwise the payload's cwd, which for an unpinned session is
#   authoritative and moves the record. Otherwise the record as it stands.
#
# EVERY case asserts through a decision the guard actually made — the name a
# lock appears under on disk, or a `permissionDecision`, or who a denial says
# holds the thing. Never on the session record alone. That is not a stylistic
# preference: `agentbus here` shipped with an assertion that only ever asked the
# record, and it passed green for the entire time the guard was locking and
# judging the session in the tree its payload named. The record was right and
# the decision was wrong, and only the record was being read. Where a record
# assertion appears below it is marked as supporting context and there is a
# guard assertion beside it carrying the rule.
#
# Location is asserted through a `scope: "worktree"` resource, because its lock
# name carries a digest of the root the guard decided on. A wrong answer about
# where somebody is working therefore shows up as a different file in
# `locks/` — which is the only place the guard's answer is visible from outside.
#
# Three cases here contradicted the order above when this file was written, and
# M0 pinned all three as DIVERGENCE — the behaviour characterised first and
# changed afterwards, in a commit saying which of the two was wrong. M1 settled
# them, one commit each, and the label is gone from all three. One went the
# code's way and two went the prose's:
#
#   A pinned session used to ignore `git -C`. The pin was applied inside
#   `_caller_view`, which is also the function the guard calls to apply `git -C`,
#   so the pin swallowed it on the way through. `git -C <path>` is a statement
#   about one command and a pin is a statement about a session, and the narrower
#   one wins — which is what the order above said all along, so the CODE moved.
#
#   A subagent's own root beats its parent's pin, and the ORDER now says so.
#
#   `--as` beats the party hint, and the ORDER now says that too.
#
# The reasoning for each is at the case that pins it, not here.
#
# The lettered sections below are in the order they were written, which is no
# longer the order above: the hint is (b) and `--as` is (c), and the case that
# settles which of the two wins is at the end of (c).

. "$AB_ROOT/tests/lib.sh"

# --------------------------------------------------------------- helpers ----
#
# None of these are in lib.sh. `reason_of` is copied from test_subagents.sh;
# the other four are new and exist because the assertions here are about
# things the guard wrote rather than about hook output.

reason_of() { json_field "$1" hookSpecificOutput permissionDecisionReason; }

# The name a `scope: "worktree"` resource is locked under in a given checkout.
# Recomputed here rather than read back out of the engine: asking the engine
# what it thinks it did would agree with itself however wrong it was.
wt_lock() {   # <checkout> → e.g. worktree@3f9c1a
  python3 -c '
import hashlib, os, sys
print("worktree@" + hashlib.sha1(
    os.path.realpath(sys.argv[1]).encode()).hexdigest()[:6])' "$1"
}

# Every lock on disk, by the name it is filed under, sorted and space
# separated. This is the guard's decision made visible.
held_locks() {
  python3 -c "
import glob, json
names = []
for p in glob.glob('$AGENTBUS_HOME/locks/*.json'):
    try:
        rec = json.load(open(p))
    except Exception:
        continue
    if rec.get('resource'):
        names.append(rec['resource'])
print(' '.join(sorted(names)))"
}

# Every file on the bus that carries the marker `resolve_party` puts on a view.
# A record on disk with `_view` on it is a view that was persisted, wherever it
# came from — including from a write site nobody has thought to check.
views_on_disk() {
  python3 -c "
import glob, json, os
bad = []
for p in glob.glob(os.path.join('$AGENTBUS_HOME', '**', '*.json'), recursive=True):
    try:
        rec = json.load(open(p))
    except Exception:
        continue
    if isinstance(rec, dict) and '_view' in rec:
        bad.append(os.path.basename(p))
print(' '.join(sorted(bad)))"
}

# The checkout the guard recorded on a lock when it took it. Same decision as
# the digest in the name, in a form a failure message can be read from.
lock_worktree() {   # <lock name> → the root the guard resolved
  python3 -c "
import glob, json, sys
for p in glob.glob('$AGENTBUS_HOME/locks/*.json'):
    try:
        rec = json.load(open(p))
    except Exception:
        continue
    if rec.get('resource') == sys.argv[1]:
        print(rec.get('worktree', ''))
        break" "$1"
}

# ---------------------------------------------------------------- fixture ----

REPO=$(make_repo idrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "simulator", "desc": "the one iOS simulator on this machine",
     "why": "One simulator. Two runs at once interleave taps and both fail.",
     "patterns": ["\\bmaestro\\b"]},
    {"name": "worktree", "desc": "this checkout's tree and index",
     "scope": "worktree",
     "patterns": ["\\bgit\\s+add\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT=$(make_worktree "$REPO" idwt)

# Two live sessions, because the guard short-circuits when a session is alone:
# with nothing to collide with there is no decision to characterise. They are
# in different checkouts so their generated names are not prefixes of each
# other, which `assert_not_contains` would otherwise read wrong.
new_session sess-a "$REPO"
new_session sess-b "$WT"
A=$(ab sess-a name)
B=$(ab sess-b name)

pre() {      # <sid> <cwd> <cmd> <tool use id> → the hook's stdout
  ab_hook pre-tool "$(payload bash "sid=$1" "cwd=$2" "cmd=$3" "id=$4")"
}
apre() {     # <sid> <agent id> <cwd> <cmd> <tool use id> → the hook's stdout
  ab_hook pre-tool "$(payload bash "sid=$1" "cwd=$3" "cmd=$4" "id=$5" \
    "agent_id=$2" agent_type=general-purpose)"
}
free_all() {   # everything handed back, so the next case starts from nothing
  local s
  for s in "$@"; do ab "$s" release --all > /dev/null 2>&1; done
}

ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-one agent_type=general-purpose)" > /dev/null
ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-two agent_type=general-purpose)" > /dev/null
ONE="$A/1"
TWO="$A/2"

# ==============================================================================
# WHO IS ACTING
# ==============================================================================

# ---- (a) the `agent_id` on the payload --------------------------------------
#
# It is the first rule because it is the only one that cannot be faked or
# guessed: Claude Code puts it on every hook a subagent causes and on none the
# session itself causes. The three payloads below differ in nothing but that
# field, so whatever the guard does differently between them is that field
# deciding.

out=$(apre sess-a sub-one "$REPO" "maestro test flows/checkout.yaml" w-a1)
assert_allow "$out" "agent_id (a): a subagent's own call takes the resource"
assert_equal "simulator" "$(held_locks)" \
  "agent_id (a): and the lock is really on disk"

out=$(apre sess-a sub-two "$REPO" "maestro test flows/checkout.yaml" w-a2)
assert_deny "$out" \
  "agent_id (a): the sibling is refused — the payloads differ only in agent_id"
assert_contains "$(reason_of "$out")" "$ONE" \
  "agent_id (a): and the denial names the agent, not the session"

# Same session id, same cwd, same command, no agent_id — and now it is a
# different party, one that a parent never contends with.
out=$(pre sess-a "$REPO" "maestro test flows/checkout.yaml" w-a3)
assert_allow "$out" \
  "agent_id (a): dropping agent_id from the payload makes it the session again"

free_all sess-a

# ---- (b) the party hint the guard left for this exact command line ----------
#
# A subagent's Bash environment is byte-identical to its parent's, so by the
# time the command-line tool is running nothing in it knows which subagent is
# calling. The guard saw the same command a few milliseconds earlier and did
# know, so it leaves the answer under a key computed from the command's argv.
#
# `agentbus wait` is used rather than `claim` deliberately: `wait` is a
# passthrough verb, so the guard does not take the resource itself. Whatever
# name the lock ends up under was therefore decided by the hint and by nothing
# else.

out=$(apre sess-a sub-one "$REPO" "agentbus wait simulator --why queueing" w-b1)
assert_allow "$out" "hint (b): the guard lets a passthrough verb through"
ab sess-a wait simulator --why queueing > /dev/null

out=$(apre sess-a sub-one "$REPO" "maestro test flows/one.yaml" w-b2)
assert_allow "$out" \
  "hint (b): the lock the CLI took is the subagent's, so the subagent may use it"
out=$(apre sess-a sub-two "$REPO" "maestro test flows/two.yaml" w-b3)
assert_deny "$out" "hint (b): and its sibling may not"
assert_contains "$(reason_of "$out")" "$ONE" \
  "hint (b): the sibling is told which agent the hint identified"

free_all sess-a

# "For this exact command line" is load-bearing, not incidental: the key is a
# digest over the whole argv, and the two halves compute it independently. A
# command line the guard never saw has no hint, and the lock then has to admit
# it cannot name its party — which, with two subagents live, blocks even the
# agent that took it.
out=$(apre sess-a sub-one "$REPO" "agentbus wait simulator --why phrasing" w-b4)
assert_allow "$out" "hint (b): the guard sees one phrasing of the command"
ab sess-a wait simulator > /dev/null      # a different argv: a different key

out=$(apre sess-a sub-one "$REPO" "maestro test flows/three.yaml" w-b5)
assert_deny "$out" \
  "hint (b): a hint left for a different command line is not picked up"
assert_contains "$(reason_of "$out")" "took this through a shell" \
  "hint (b): and the guard says it cannot tell, rather than guessing"

free_all sess-a

# A hint is one session's. Two sessions running the identical command line
# compute the identical key, and reading somebody else's would hand a lock to
# the wrong session — silently, because both answers look plausible.
out=$(apre sess-a sub-one "$REPO" "agentbus wait simulator --why crossing" w-b6)
assert_allow "$out" "hint (b): a hint is left for this session's subagent"
ab sess-b wait simulator --why crossing > /dev/null   # same argv, other session

out=$(apre sess-a sub-one "$REPO" "maestro test flows/four.yaml" w-b7)
assert_deny "$out" "hint (b): the other session's claim still blocks"
assert_contains "$(reason_of "$out")" "$B" \
  "hint (b): and it is attributed to that session, which took it"
assert_not_contains "$(reason_of "$out")" "$ONE" \
  "hint (b): not to the subagent whose hint was sitting under the same key"

free_all sess-a sess-b

# "If the caller is the command-line tool" is the other half of the rule, and it
# is not decoration: a hook is TOLD who is acting, so a hint left under the same
# command line must not be allowed to overrule the payload in front of it. The
# only way to see that from outside is a claiming verb, which the guard takes
# for itself — so the same command line is run twice, once by the subagent and
# once by the session, and the second lock must be the session's.
out=$(apre sess-a sub-one "$REPO" "agentbus claim simulator --why hooked" w-b8)
assert_allow "$out" "hint (b): a subagent's claim leaves a hint under this argv"
free_all sess-a

out=$(pre sess-a "$REPO" "agentbus claim simulator --why hooked" w-b9)
assert_allow "$out" "hint (b): the session runs the identical command line"
out=$(apre sess-a sub-two "$REPO" "maestro test flows/eleven.yaml" w-b10)
assert_allow "$out" \
  "hint (b): the hook ignored the hint — the lock is the session's, so a subagent passes"

free_all sess-a

# ---- (c) an explicit `--as <name>`, honoured by the verb --------------------
#
# The last resort in the sense that nothing else can identify this caller. An
# `agentbus claim` buried in a runner script never reaches the guard, so there
# is no hint to pick up and no agent_id anywhere — and on 2026-07-29 three
# subagents of one session each took the simulator that way and each was told it
# held it alone. Saying the name outright is what is left. Last in the file, but
# not last in the order: where a hint also exists, this is what wins.

ab sess-a claim simulator --as "$ONE" --why "batch 1: 7 flows" > /dev/null
out=$(apre sess-a sub-one "$REPO" "maestro test flows/five.yaml" w-c1)
assert_allow "$out" \
  "--as (c): a claim the guard never saw is still the named agent's"
out=$(apre sess-a sub-two "$REPO" "maestro test flows/six.yaml" w-c2)
assert_deny "$out" "--as (c): and the sibling is refused by that name"
assert_contains "$(reason_of "$out")" "$ONE" \
  "--as (c): which the denial states"

free_all sess-a

# Where the two meet, and the case the order used to get backwards. The hint is
# applied in `resolve_party` and `acting` then overwrites it, so `--as` wins.
# M1 settled it by correcting the order rather than the code: a hint is an
# inference the guard made from a command line — two subagents running the
# identical line can already swap hints, which `take_party_hint` accepts as the
# smaller error — and `--as <name>` is a declaration by the caller, checked
# against that session's own subagents. A declaration beats an inference.
#
# It is also the only thing that makes the block advice work. The
# unidentified-party block tells a blocked agent to name itself, and naming
# yourself is worth nothing if a hint sitting under the same argv outranks it.
out=$(apre sess-a sub-one "$REPO" "agentbus wait simulator --as $TWO --why over" w-c3)
assert_allow "$out" "--as (c): the guard leaves a hint naming the caller"
ab sess-a wait simulator --as "$TWO" --why over > /dev/null

out=$(apre sess-a sub-two "$REPO" "maestro test flows/seven.yaml" w-c4)
assert_allow "$out" \
  "--as (c) vs hint (b): --as overrides the hint, so the lock is the named agent's"
out=$(apre sess-a sub-one "$REPO" "maestro test flows/eight.yaml" w-c5)
assert_deny "$out" \
  "--as (c) vs hint (b): and the agent the hint named is the one refused"
assert_contains "$(reason_of "$out")" "$TWO" \
  "--as (c) vs hint (b): by the name on the command line"

free_all sess-a

# ---- (d) otherwise the session ----------------------------------------------

out=$(pre sess-a "$REPO" "maestro test flows/nine.yaml" w-d1)
assert_allow "$out" "session (d): a payload with no agent_id acts as the session"
out=$(pre sess-b "$WT" "maestro test flows/ten.yaml" w-d2)
assert_deny "$out" "session (d): and another session is refused by it"
r=$(reason_of "$out")
assert_contains "$r" "$A" "session (d): the denial names the session that holds it"
assert_not_contains "$r" "$ONE" "session (d): not one of its subagents"
assert_not_contains "$r" "$TWO" "session (d): nor the other"

free_all sess-a sess-b

# ==============================================================================
# WHERE THEY ARE WORKING
# ==============================================================================
#
# From here on the resource is `worktree`, whose lock name carries a digest of
# the root the guard settled on. Two checkouts of one repository therefore
# produce two different locks, and reading which one appeared is reading the
# guard's answer to "where is this party working" directly.

assert_equal "" "$(held_locks)" "nothing is held before the location cases"

# ---- (a) a path the command itself names ------------------------------------
#
# `git -C <path>` is how a chat works on a worktree it never changes into, and
# everything that infers a tree from cwd then places it in the repository it was
# launched in, permanently. Reported from Windows on 2026-07-31: four chats
# rendered on one branch in one worktree and one of them was somewhere else.

out=$(pre sess-a "$REPO" "git -C $WT add -A" l-a1)
assert_allow "$out" "git -C (a): a command that names a checkout is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "git -C (a): and locked in the checkout it names, not the one the payload says"
assert_equal "$WT" "$(lock_worktree "$(wt_lock "$WT")")" \
  "git -C (a): the lock records that checkout as the tree it was taken for"

# The proof that this is a decision and not a coincidence: the session that is
# actually standing in that checkout is now blocked by it.
out=$(pre sess-b "$WT" "git add -A" l-a2)
assert_deny "$out" \
  "git -C (a): a session working in the named checkout is blocked by that lock"

# "For that command only, without moving any record."
assert_equal "$REPO" "$(session_field sess-a root)" \
  "git -C (a): the session's record did not move   [supporting]"
free_all sess-a sess-b
out=$(pre sess-a "$REPO" "git add -A" l-a3)
assert_allow "$out" "git -C (a): the next command names no checkout"
assert_equal "$(wt_lock "$REPO")" "$(held_locks)" \
  "git -C (a): and is locked in the session's own tree again"

free_all sess-a

# ---- (b) the root pinned by `agentbus here` ---------------------------------
#
# Claude Code returns the shell to the directory the chat opened in between tool
# calls, so a session working in another checkout has every payload afterwards
# saying the old tree. An agent in exactly that position on 2026-07-31 was told
# it was in a checkout it had left, blocked from services it had started itself,
# and ran the rest of its work with AGENTBUS_OFF=1.
#
# This is the case that must contradict the record deliberately, because the
# assertion that shipped with the pin did not: it asked the record, which was
# right, while `_caller_view` — which is what the guard decides from — had no
# pin check at all and went on locking the tree the payload named. The evidence at
# the time was
#
#     pinned record : worktree@fefd30
#     caller_view   : worktree@c4f9c3
#     lock the guard actually wrote: repo_8d18a7__worktree_c4f9c3.json
#
# so a lock name is exactly what this asserts on.

new_session sess-pin "$REPO"
( cd "$WT" && ab sess-pin here > /dev/null )

out=$(pre sess-pin "$REPO" "git add -A" l-b1)
assert_allow "$out" "pin (b): a pinned session's command is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "pin (b): and locked in the PINNED checkout, though the payload named the other"
assert_equal "$WT" "$(lock_worktree "$(wt_lock "$WT")")" \
  "pin (b): the lock records the pinned checkout as the tree it was taken for"
assert_equal "$WT" "$(session_field sess-pin root)" \
  "pin (b): which is what the record says too   [supporting]"

# The decisive pair. If the pin is being honoured, the session standing in the
# pinned tree collides and the one standing in the tree the payload named does
# not; if it is being ignored, both answers flip.
out=$(pre sess-b "$WT" "git add -A" l-b2)
assert_deny "$out" "pin (b): a session in the pinned checkout is blocked by it"
out=$(pre sess-a "$REPO" "git add -A" l-b3)
assert_allow "$out" \
  "pin (b): and one in the checkout the payload named is not — it is a free tree"
assert_contains "$(held_locks)" "$(wt_lock "$REPO")" \
  "pin (b): so the two sessions hold two different checkouts' locks"

free_all sess-a sess-b sess-pin

# The two statements meet here, and the narrower one wins. `git -C <path>` is
# about one command; a pin is about a session. Until M1 the pin took it:
# `_command_worktree`'s answer is applied by calling `_caller_view`, whose pin
# short-circuit returned before the path was looked at, so the function that was
# supposed to apply `git -C` was the function that discarded it.
out=$(pre sess-pin "$REPO" "git -C $REPO add -A" l-b4)
assert_allow "$out" "pin (b) vs git -C (a): the command names the unpinned checkout"
assert_equal "$(wt_lock "$REPO")" "$(held_locks)" \
  "pin (b) vs git -C (a): and git -C wins — it is a statement about one command"
assert_equal "$WT" "$(session_field sess-pin root)" \
  "pin (b) vs git -C (a): the pin itself did not move   [supporting]"

free_all sess-pin

# The other half of "one command": the same session, still pinned to the same
# tree, running a command that names no path. Without this pair the change above
# is indistinguishable from the pin having stopped working.
out=$(pre sess-pin "$REPO" "git add -A" l-b4b)
assert_allow "$out" "pin (b): the next command names no checkout"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "pin (b): so the pin governs it again — git -C moved that one command and no more"

free_all sess-pin

# A subagent of a pinned session is caught by the same rule, and has to be freed
# by the same one: `_party_view` builds its view with `dict(me)`, so the parent's
# `pinned` is copied into it and the short-circuit fires on the subagent's path
# too. Rooted in the pinned tree deliberately — then the only thing that can put
# the lock in the other checkout is the path the command names.
ab_hook subagent-start "$(payload subagent-start sid=sess-pin "cwd=$WT" \
  agent_id=sub-p agent_type=general-purpose)" > /dev/null
out=$(apre sess-pin sub-p "$WT" "git -C $REPO add -A" l-b4c)
assert_allow "$out" \
  "pin (b) vs git -C (a): a subagent of a pinned session names a checkout"
assert_equal "$(wt_lock "$REPO")" "$(held_locks)" \
  "pin (b) vs git -C (a): and git -C wins for it too, through its parent's pin"

free_all sess-pin

# A pin is a statement, not a cage: saying it somewhere else moves it, and the
# guard has to move with it rather than with the record alone.
( cd "$REPO" && ab sess-pin here > /dev/null )
out=$(pre sess-pin "$WT" "git add -A" l-b5)
assert_allow "$out" "pin (b): \`here\` elsewhere is allowed"
assert_equal "$(wt_lock "$REPO")" "$(held_locks)" \
  "pin (b): and the guard locks the newly pinned checkout"

free_all sess-pin

# A pin survives the chat going quiet, which is the case that made the
# declaration cosmetic a second time. A chat left idle for three hours is
# reaped — ABANDONED_BEAT retires a session even while its process is alive —
# and until 2.8.0 the reap deleted the record, so the next thing the chat did
# re-registered it from nothing and the guard went back to judging it wherever
# the payload's cwd pointed. Which for a chat that declared another checkout is
# the wrong one, every time, silently.
#
# Reaped by ANOTHER session's turn, deliberately: that is how it happens on a
# machine running several chats, and it is what makes reading the record inside
# `register` no fix at all — by then it is already gone.

new_session sess-idle "$REPO"
( cd "$WT" && ab sess-idle here > /dev/null )
out=$(pre sess-idle "$REPO" "git add -A" l-b6)
assert_allow "$out" "pin (b) idle: the pinned session's command is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "pin (b) idle: and locked in the declared checkout to begin with"
free_all sess-idle

# The beat is the only thing that measures idleness, and the pid stays alive:
# this is a chat somebody left open, not one that died.
python3 -c "
import os, time
beat = os.path.join('$AGENTBUS_HOME', 'sessions', 'sess-idle.beat')
old = time.time() - 4 * 3600            # > ABANDONED_BEAT (3h)
os.utime(beat, (old, old))"
ab_hook prompt-submit "$(payload session sid=sess-a "cwd=$REPO")" > /dev/null
assert_no_file "$AGENTBUS_HOME/sessions/sess-idle.json" \
  "pin (b) idle: another session's turn reaps the quiet one, record and all"
assert_file "$AGENTBUS_HOME/declared/sess-idle.json" \
  "pin (b) idle: but what it declared is kept where the reap cannot reach it"

# Typed into again. The payload says $REPO, as every payload has all along.
ab_hook prompt-submit "$(payload session sid=sess-idle "cwd=$REPO")" > /dev/null
out=$(pre sess-idle "$REPO" "git add -A" l-b7)
assert_allow "$out" "pin (b) idle: the resumed session's command is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "pin (b) idle: and STILL locked in the checkout it declared before it went quiet"
assert_equal "$WT" "$(session_field sess-idle root)" \
  "pin (b) idle: which is what the rebuilt record says too   [supporting]"
assert_no_file "$AGENTBUS_HOME/declared/sess-idle.json" \
  "pin (b) idle: and the copy it was rebuilt from is not left lying about"

free_all sess-idle

# ---- (c) the subagent's own recorded root -----------------------------------
#
# A subagent's record is written at SubagentStart from whatever directory it was
# launched in, which is its parent's rather than the tree it was told to work
# in. On 2026-07-29 an agent that had itself pointed a service at its own
# worktree was refused permission to use it, and carried on with AGENTBUS_OFF=1
# rather than argue — the one outcome this plugin cannot afford.

new_session sess-sub "$REPO"
ab_hook subagent-start "$(payload subagent-start sid=sess-sub "cwd=$REPO" \
  agent_id=sub-w agent_type=general-purpose)" > /dev/null

out=$(apre sess-sub sub-w "$WT" "git add -A" l-c1)
assert_allow "$out" "subagent (c): a subagent working in another tree is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "subagent (c): and locked in the tree its payload demonstrated, not its parent's"
assert_equal "$WT" "$(agent_field sess-sub sub-w root)" \
  "subagent (c): its own record followed it   [supporting]"
assert_equal "$REPO" "$(session_field sess-sub root)" \
  "subagent (c): without dragging the session out of its checkout   [supporting]"

free_all sess-sub

# The conjunct that is easy to lose in a refactor: a cwd equal to the PARENT's
# is not an observation. It is what a subagent's payload says when it has never
# changed directory, whatever tree it was told to work in — so it says nothing
# about where the work is, and treating it as evidence would overwrite the
# subagent's own root on its very next tool call, every time.
out=$(apre sess-sub sub-w "$REPO" "git add -A" l-c2)
assert_allow "$out" "subagent (c): a payload carrying its parent's cwd is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "subagent (c): and does NOT move it — the guard still locks its own tree"
assert_equal "$WT" "$(agent_field sess-sub sub-w root)" \
  "subagent (c): its record is untouched by it   [supporting]"

# Two parties of one session, in two checkouts, at the same moment. This is the
# thing a single per-session root cannot express, and the reason the subagent's
# own record sits in the order at all.
out=$(pre sess-sub "$REPO" "git add -A" l-c3)
assert_allow "$out" "subagent (c): the parent is judged in its own tree meanwhile"
assert_contains "$(held_locks)" "$(wt_lock "$WT")" \
  "subagent (c): the subagent holds one checkout's lock"
assert_contains "$(held_locks)" "$(wt_lock "$REPO")" \
  "subagent (c): and the parent the other's, in the same session"

free_all sess-sub

# The order used to put the pin ABOVE the subagent's own root, which read
# strictly means a session pinned to one tree drags its subagents into it — the
# two-parties-two-checkouts case the assertions just above exist to express,
# undone by one `agentbus here`. M1 settled it the other way and corrected the
# order rather than the code, which is why this is no longer marked DIVERGENCE.
#
# A subagent's record tracks where that subagent demonstrably is:
# `_follow_agent_cwd` moves it only on positive evidence, and `_party_view` hands
# the subagent that root for every other purpose. The parent's pin is a
# statement about the parent. And a subagent that wants to state its own
# location now has a way to — `agentbus here --as <name>`, asserted below —
# so what beats an inference here is a declaration by the same party, not a
# declaration by another one.
( cd "$REPO" && ab sess-sub here > /dev/null )
out=$(apre sess-sub sub-w "$REPO" "git add -A" l-c4)
assert_allow "$out" "subagent (c) vs pin (b): the parent pins itself elsewhere"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "subagent (c) vs pin (b): the subagent's own root still wins, over its parent's pin"

free_all sess-sub

# A subagent's DECLARATION, which is a different thing from the inferred root
# above and is now as durable as the session's. Until M1 the `--as` branch of
# `agentbus here` wrote the same five location fields as the session branch and
# no flag, so the only thing standing between a stated root and a payload was
# the guard above — a cwd equal to the parent's. Any OTHER cwd walked over it.
# The arrangement here is exactly that: the agent declares the main checkout,
# its parent is sitting in the main checkout, and the next payload names the
# worktree — neither the record nor the parent's tree, so it used to be read as
# an observation and the declaration lasted one tool call. A session's
# declaration had a flag; a subagent's had a coincidence.
SUBP=$(ab sess-sub name)
SUBW="$SUBP/1"
ab sess-sub here "$REPO" --as "$SUBW" > /dev/null
out=$(apre sess-sub sub-w "$WT" "git add -A" l-c5)
assert_allow "$out" "subagent (c): a subagent that declared its checkout is allowed"
assert_equal "$(wt_lock "$REPO")" "$(held_locks)" \
  "subagent (c): and locked where it DECLARED, not where the payload puts it"
assert_equal "$REPO" "$(agent_field sess-sub sub-w root)" \
  "subagent (c): the payload did not overwrite the declaration   [supporting]"

free_all sess-sub

# And it is a statement rather than a cage one level down too, the same way
# `agentbus here` is for a session.
ab sess-sub here "$WT" --as "$SUBW" > /dev/null
out=$(apre sess-sub sub-w "$REPO" "git add -A" l-c6)
assert_allow "$out" "subagent (c): declaring it somewhere else is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "subagent (c): and the guard follows to the newly declared checkout"

free_all sess-sub

# ---- (d) otherwise the payload's cwd, which moves the record ----------------
#
# The rule that catches Claude Code moving a session into a worktree it created
# under `.claude/worktrees/`. For a session that has declared nothing, the cwd
# on its own payload is the best evidence there is, and it is authoritative:
# unlike a subagent's, it moves the record.

new_session sess-free "$REPO"
out=$(pre sess-free "$WT" "git add -A" l-d1)
assert_allow "$out" "payload cwd (d): an unpinned session's command is allowed"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "payload cwd (d): and locked in the tree the payload named"
assert_equal "$WT" "$(session_field sess-free root)" \
  "payload cwd (d): the record moved with it   [supporting]"

out=$(pre sess-b "$WT" "git add -A" l-d2)
assert_deny "$out" \
  "payload cwd (d): the session standing in that tree is blocked by the lock"

free_all sess-free sess-b

# ---- (e) otherwise the record as it stands ----------------------------------
#
# The fall-through. A payload with no cwd on it leaves nothing to infer from,
# and the answer is whatever was last established — here, the move (d) just
# made. Every branch above has a `not cwd` guard for this reason; without one
# the guard would ask git about the empty string and place the session wherever
# the hook process happened to be started.

out=$(pre sess-free "" "git add -A" l-e1)
assert_allow "$out" "record (e): a payload with no cwd at all is still guarded"
assert_equal "$(wt_lock "$WT")" "$(held_locks)" \
  "record (e): and locked where the record stands, which is where (d) left it"

free_all sess-free

# ==============================================================================
# AND ONE ANSWER IS NEVER WRITTEN OVER THE OTHER
# ==============================================================================
#
# `resolve_party` answers twice: the session's own record, which is safe to
# write back, and the acting party's view of it, which is not. Four verbs write
# what they are handed straight to the session file — `rename_session`,
# `follow_chat_title`, `agentbus name` and `agentbus doing` — and every other
# verb wants the view, so handing one value to all of them is the obvious
# simplification and it is wrong. Persisting a view was the first thing tried
# and it was worse than a stale record: two subagents dragged the session's root
# back and forth between them on every tool call, so it was not even
# consistently wrong. A subagent's `agentbus here --as` would likewise pin its
# parent, one field carrying two meanings.
#
# Nothing above would catch it. Every case in this file drives one party at a
# time, and a view written into the session record still describes a real
# checkout — it is only wrong for the OTHER party, on the next call.

new_session sess-v "$REPO"
ab_hook subagent-start "$(payload subagent-start sid=sess-v "cwd=$REPO" \
  agent_id=sub-v agent_type=general-purpose)" > /dev/null

# A shell becomes a subagent only through the hint, so the declaration below is
# made by the agent and handled by a verb that writes.
out=$(apre sess-v sub-v "$REPO" "agentbus here $WT" w-v1)
assert_allow "$out" "record vs view: the guard leaves a hint for the declaring agent"
( cd "$REPO" && ab sess-v here "$WT" > /dev/null )
assert_equal "$WT" "$(agent_field sess-v sub-v root)" \
  "record vs view: the agent the hint named is the one that got the declaration"

# The guard assertion the section turns on. If the agent's view had been written
# to the session file, the parent would now be judged in the agent's checkout —
# and would collide with the session that is actually standing there.
out=$(pre sess-v "$REPO" "git add -A" w-v2)
assert_allow "$out" "record vs view: the parent's own command is allowed"
assert_equal "$(wt_lock "$REPO")" "$(held_locks)" \
  "record vs view: and locked in the parent's checkout, not the one its agent declared"
assert_equal "$REPO" "$(session_field sess-v root)" \
  "record vs view: the session record never moved   [supporting]"
assert_equal "" "$(session_field sess-v agent_id)" \
  "record vs view: nor took on the identity of the party that ran the verb   [supporting]"
free_all sess-v

# And the two verbs whose whole job is to write the record. `name` and `doing`
# are not verbs the guard leaves hints for, so nothing here can identify a
# party — which is the point: the wrong value is available and must not be the
# one taken.
ab sess-v name idv > /dev/null
ab sess-v doing "checking what gets written" > /dev/null
out=$(pre sess-v "$REPO" "git add -A" w-v3)
assert_allow "$out" "record vs view: a renamed session is still guarded"
assert_equal "$(wt_lock "$REPO")" "$(held_locks)" \
  "record vs view: in the same checkout it was in before it was written to"
free_all sess-v

assert_equal "" "$(views_on_disk)" \
  "record vs view: and no file on the bus carries a party view at all"

finish
