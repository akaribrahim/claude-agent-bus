#!/usr/bin/env bash
# Which checkout a service is actually answering for.
#
# This is the failure the whole plugin exists for, so it is tested against a
# real service on a real port rather than against a mocked record: two worktrees
# of one repository, each holding a file that says which tree it is, and a
# server that serves whichever tree it was started in. A lock cannot fix this —
# holding "server" does not make the port answer with your code — so what is
# asserted is the answer coming back over the socket.

. "$AB_ROOT/tests/lib.sh"

# Attributing a port to a checkout needs the platform to say who is listening.
if ! command -v lsof > /dev/null 2>&1 && ! command -v netstat > /dev/null 2>&1; then
  skip_test "no lsof or netstat: cannot tell which checkout a port serves"
fi

trap stop_services EXIT

PORT=$(free_port)
PORT2=$(free_port)
REPO=$(make_repo servrepo)
python3 - "$REPO/.claude/agent-bus.json" "$PORT" "$PORT2" <<'PY'
import json, os, sys
path, port, port2 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"resources": [{
    "name": "web",
    "desc": "the demo server on :%d" % port,
    "why": "It serves the tree it was started in, so a request answers with "
           "THAT checkout's files.",
    "port": port,
    "start": "python3 -m http.server %d --bind 127.0.0.1" % port,
    "patterns": [r"\bhttp\.server\b", r":%d\b" % port],
}, {
    "name": "forked",
    "desc": "the same thing, started so the shell cannot exec it",
    "port": port2,
    # The trailing `; true` is the point: no shell will replace itself with
    # this, so the recorded pid is the shell's and the listener is its child.
    "start": "python3 -m http.server %d --bind 127.0.0.1 ; true" % port2,
    "patterns": [r":%d\b" % port2],
}, {
    # Per checkout, which is what makes `git -C <path>` worth reading: the lock
    # it takes has to be the named tree's, not the caller's.
    "name": "worktree",
    "desc": "this checkout's tree and index",
    "scope": "worktree",
    "patterns": [r"\bgit\s+add\b"],
}]}, open(path, "w"), indent=2)
PY
commit_all "$REPO"
WT2=$(make_worktree "$REPO" servwt2)

printf 'wt1\n' > "$REPO/which.txt"
printf 'wt2\n' > "$WT2/which.txt"

new_session sess-a "$REPO"
new_session sess-b "$WT2"
A=$(ab sess-a name)

fetch() {
  python3 -c "
import sys, urllib.request
try:
    print(urllib.request.urlopen('http://127.0.0.1:$PORT/which.txt',
                                 timeout=5).read().decode().strip())
except Exception as exc:
    print('unreachable: %s' % exc)"
}

# ---- agent-bus starts it, so it knows whose tree it is serving ---------------

out=$(ab sess-a serve web 2>&1)
assert_contains "$out" "restarted from your worktree" "the first session starts it"
assert_equal wt1 "$(fetch)" "the port answers with the first worktree's file"

out=$(ab sess-a serves)
assert_contains "$out" "agent-bus" "agent-bus knows it started the service"

# …and still knows when the shell did not exec the command it was given.
#
# `shell=True` execs a simple command on macOS and forks it on Linux, so the pid
# recorded at start is the listener's on one platform and its parent's on the
# other. This resource forces the fork on both, which is the case CI caught and
# a macOS-only run never could.
out=$(ab sess-a serve forked 2>&1)
assert_contains "$out" "restarted from your worktree" "a forking start command works"
out=$(ab sess-a serves)
assert_equal 2 "$(printf '%s\n' "$out" | grep -c 'agent-bus')" \
  "both services are recognised as ours, however the shell ran them"

# ---- the other worktree is refused even though no lock is held --------------

assert_equal 0 "$(locks_held)" "no lock is held after serve returns"
CMD="curl -sf http://localhost:$PORT/which.txt"
out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=sv-1)")
assert_deny "$out" "a request from the other worktree is refused"
reason=$(json_field "$out" hookSpecificOutput permissionDecisionReason)
assert_contains "$reason" "serving a different checkout" "the denial says why"
assert_contains "$reason" "$A" "the denial names who started it"
assert_contains "$reason" "agentbus serve web" "the denial says how to take it"
assert_contains "$reason" "THAT checkout's files" \
  "the denial quotes the repository's own explanation"
assert_equal 0 "$(locks_held)" "the refused command claimed nothing"

# ---- taking it over moves the service, and everyone is told ------------------

out=$(ab sess-b serve web 2>&1)
assert_contains "$out" "restarted from your worktree" "the second session takes it"
assert_equal wt2 "$(fetch)" "the port now answers with the second worktree's file"

out=$(ab sess-a inbox)
assert_contains "$out" "'web' now serves" "the handover is announced on the bus"

out=$(ab_hook pre-tool "$(payload bash "sid=sess-a" "cwd=$REPO" "cmd=$CMD" id=sv-2)")
assert_deny "$out" "now it is the first session that is refused"
ab_hook post-bash "$(payload post-bash "sid=sess-a" "cwd=$REPO" id=sv-2)" > /dev/null

out=$(ab_hook pre-tool "$(payload bash "sid=sess-b" "cwd=$WT2" "cmd=$CMD" id=sv-3)")
assert_allow "$out" "the session it serves is allowed through"
ab_hook post-bash "$(payload post-bash "sid=sess-b" "cwd=$WT2" id=sv-3)" > /dev/null

# ---- `run` does the handover and the command in one step --------------------

READ="import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:$PORT/which.txt', timeout=5).read().decode().strip())"
out=$(ab sess-a run web -- python3 -c "$READ" 2>/dev/null)
assert_equal wt1 "$out" "run pointed the service at this worktree and used it"
assert_equal 0 "$(locks_held)" "run gave the resource back afterwards"
assert_equal wt1 "$(fetch)" "and left it serving the worktree it moved it to"

# ---- a service pulled back and forth is said out loud -----------------------
#
# That was the third handover of `web`, between two checkouts, inside a few
# seconds. Every one of them was legitimate on its own — took the lock, reported
# success — so nothing was ever said about the pattern. On 2026-07-29 the API
# went machine-side, rental-side and back inside seventeen seconds while three
# agents each ran their tests believing the rig answered for their own tree; two
# of them worked it out an hour later by reading `lsof`. The lock they needed
# existed the whole time. What they had no way to see was that they needed it.

churn() { ab sess-b inbox | grep -c "has changed checkouts" | tr -d ' '; }
assert_equal 1 "$(churn)" "the third handover between two trees is announced"
out=$(ab sess-b inbox)
assert_contains "$out" "agentbus claim web" "with the thing to do about it"
assert_contains "$out" "servwt2" "naming the checkouts it is being pulled between"

# ---- a session that moves into a worktree mid-session ----------------------
#
# Claude Code creates worktrees under `.claude/worktrees/` and moves a session
# into one. The session's root was derived once, at SessionStart, and everything
# that matters reads it: `serve` starts the service from that root, and
# `serving_check` compares against it. Left stale, `agentbus serve` restarts the
# service from the tree the session *started* in and reports "restarted from
# your worktree" — the exact silent wrong-checkout failure this plugin exists to
# prevent, produced by the plugin itself.
#
# Reported from real use on 2026-07-27, after it quietly reverted an API to
# main and an agent spent time on a fix that had stopped being deployed.

INNER="$REPO/.claude/worktrees/agent-abc"
git -C "$REPO" worktree add -q -b feat/inner "$INNER" > /dev/null 2>&1
printf 'inner\n' > "$INNER/which.txt"

new_session sess-move "$REPO"
assert_equal "$REPO" "$(session_field sess-move root)" \
  "a session starts in the checkout it was opened in"

# One hook carrying the new cwd is all it takes — and `prompt-submit` is the one
# that always runs the engine, so the correction lands at the session's next
# turn whatever else is going on. (A `pre-tool` for an unguarded command would
# not: the fast path filters it out before the engine is ever woken, which is
# exactly why the first version of this test passed against the broken build.)
ab_hook prompt-submit "$(payload session sid=sess-move "cwd=$INNER")" > /dev/null
assert_equal "$INNER" "$(session_field sess-move root)" \
  "and follows the agent into a worktree under .claude/worktrees/"
assert_equal "feat/inner" "$(session_field sess-move branch)" "branch and all"
# Not announced: a session running parallel subagents in different worktrees
# moves on every other tool call, and the first version of this emitted a note
# each time — thirty in three minutes into everybody else's context. The roster
# is where somebody looking for it will look.
assert_contains "$(ab sess-a status)" "$INNER" \
  "and the roster shows where it is now"
assert_not_contains "$(ab sess-a inbox)" "moved to" \
  "without announcing every move to everyone"

# A subagent's tool call carries its own cwd and an agent_id. That cwd is the
# subagent's, not the session's, and following it drags the root back and forth
# between two subagents working in two worktrees.
ab_hook prompt-submit "$(payload session sid=sess-move "cwd=$WT2" \
  agent_id=sub-1 agent_type=general-purpose)" > /dev/null
assert_equal "$INNER" "$(session_field sess-move root)" \
  "a subagent working elsewhere does not move the session"

# ---- but the subagent itself is judged where it runs ------------------------
#
# Its own record is written at SubagentStart from the directory it was launched
# in, which is its parent's, and the guard read that rather than the cwd on the
# call in front of it. So an agent that had pointed the service at its own
# worktree was refused permission to use it, in its own tree, by the plugin that
# had just moved it there. On 2026-07-29 one of them worked around that with
# AGENTBUS_OFF=1 for the rest of its turn, which is the one outcome this cannot
# afford: a guard an agent has caught being wrong is a guard it stops believing.

ab_hook subagent-start "$(payload subagent-start sid=sess-move "cwd=$INNER" \
  agent_id=sub-wt agent_type=general-purpose)" > /dev/null
assert_equal "$INNER" "$(agent_field sess-move sub-wt root)" \
  "a subagent is born where its parent was standing"

( cd "$WT2" && ab sess-b serve web > /dev/null 2>&1 )
assert_equal wt2 "$(fetch)" "the service is serving wt2"

out=$(ab_hook pre-tool "$(payload bash sid=sess-move "cwd=$WT2" "cmd=$CMD" \
  id=sv-sub agent_id=sub-wt agent_type=general-purpose)")
assert_allow "$out" \
  "a subagent working in the tree the service serves is not blocked from it"
assert_equal "$WT2" "$(agent_field sess-move sub-wt root)" \
  "and its record has followed it there"
ab_hook post-bash "$(payload post-bash sid=sess-move "cwd=$WT2" id=sv-sub \
  agent_id=sub-wt agent_type=general-purpose)" > /dev/null

# The other direction still holds — this is not a blanket exemption for
# subagents. The tree here is the main checkout rather than the parent's, on
# purpose: a cwd equal to the parent's is what a subagent's payload says when it
# has never changed directory, so it carries no information and is deliberately
# ignored. A subagent that really does return to its parent's tree has to say so
# (`agentbus here`), which is the price of the declaration sticking at all.
out=$(ab_hook pre-tool "$(payload bash sid=sess-move "cwd=$REPO" "cmd=$CMD" \
  id=sv-sub2 agent_id=sub-wt agent_type=general-purpose)")
assert_deny "$out" "and in a tree the service does not serve it is still refused"

# ---- a subagent that never changes directory can say where it is ------------
#
# Everything above works because the subagent's tool calls carried its own cwd.
# One that works by absolute path never changes directory, so every payload it
# causes carries its PARENT's — and no amount of inference can tell that from
# the truth. On 2026-07-29 an agent in that position was refused the service it
# had itself pointed at its own worktree, and used AGENTBUS_OFF=1 for the rest
# of its turn rather than argue with the guard.

ab_hook subagent-start "$(payload subagent-start sid=sess-move "cwd=$INNER" \
  agent_id=sub-still agent_type=general-purpose)" > /dev/null
assert_equal "$INNER" "$(agent_field sess-move sub-still root)" \
  "a subagent starts wherever its parent was standing"

# Its own hook payloads agree with that record, so they cannot correct it.
out=$(ab_hook pre-tool "$(payload bash sid=sess-move "cwd=$INNER" "cmd=$CMD" \
  id=sv-st1 agent_id=sub-still agent_type=general-purpose)")
assert_deny "$out" "so it is judged in its parent's tree, and refused"

# A shell knows where it is. This is where that answer gets handed over.
NAME=$(python3 -c "
import glob, json
for p in glob.glob('$AGENTBUS_HOME/agents/*.json'):
    r = json.load(open(p))
    if r.get('agent_id') == 'sub-still':
        print(r['name'])")
( cd "$WT2" && ab sess-move here --as "$NAME" > /dev/null )
assert_equal "$WT2" "$(agent_field sess-move sub-still root)" \
  "\`agentbus here\` records the tree it was actually run in"

out=$(ab_hook pre-tool "$(payload bash sid=sess-move "cwd=$INNER" "cmd=$CMD" \
  id=sv-st2 agent_id=sub-still agent_type=general-purpose)")
assert_allow "$out" \
  "and the guard now judges it there, even though the payload still says otherwise"
ab_hook post-bash "$(payload post-bash sid=sess-move "cwd=$INNER" id=sv-st2 \
  agent_id=sub-still agent_type=general-purpose)" > /dev/null

# It is the agent's own record that moved, not its parent's.
assert_equal "$INNER" "$(session_field sess-move root)" \
  "without dragging the session out of its own checkout"

# The CLI decides from where it was run — a moved session, or a subagent in its
# own worktree — and does not write that back, because the caller may be one of
# several subagents in several trees.
new_session sess-cli "$REPO"
( cd "$INNER" && ab sess-cli serve web > /dev/null 2>&1 )
assert_equal inner "$(fetch)" "serve from a worktree serves that worktree"
assert_equal "$REPO" "$(session_field sess-cli root)" \
  "without moving the session's recorded root"
# Said once, not once per handover. A warning that repeats every few seconds is
# read as noise and then the one that matters is read as noise too.
assert_equal 1 "$(churn)" "and the churn warning is not repeated for each move"

OTHER=$(make_repo servother)
commit_all "$OTHER"
( cd "$OTHER" && ab sess-cli name > /dev/null )
assert_equal "$REPO" "$(session_field sess-cli root)" \
  "and a call from an unrelated repository changes nothing at all"

# ---- a command that names a checkout is believed over the session's cwd -----
#
# `git -C <path>` is how a chat works on a worktree it never changes into, and
# everything that infers a tree from cwd then places it in the repository it was
# launched in, permanently. Reported from Windows on 2026-07-31: four chats
# rendered on one branch in one worktree, and one of them was somewhere else
# entirely — while its own generated name disagreed with the branch beside it.

out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=git -C $REPO add -A" id=gc-1)")
assert_allow "$out" "a git -C command is judged in the tree it names"
assert_equal 1 "$(locks_held)" "and takes that checkout's lock"
lk=$(ls "$AGENTBUS_HOME"/locks/ | head -1)
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=gc-1)" > /dev/null

# The proof that it is the named tree and not the session's: a second session
# standing in that tree is blocked by the lock the first one just took there.
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=git -C $REPO add -A" id=gc-2)")
assert_allow "$out" "it can be taken again once released"
out=$(ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=git add -A" id=gc-3)")
assert_deny "$out" "and a session working in that checkout is refused while it is held"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=gc-2)" > /dev/null

# A path that is not a directory is ignored rather than guessed at.
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=git -C /no/such/place add -A" id=gc-4)")
assert_allow "$out" "a -C path that does not exist falls back to the session's tree"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=gc-4)" > /dev/null


finish
