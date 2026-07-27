#!/usr/bin/env bash
# What the plugin costs and says when you are the only session on the machine.
#
# This is the common case — most of the time nobody else is running — and it is
# the case where a bug is most expensive, because the hooks fire on every tool
# call of every session on this Mac. Alone, the correct behaviour is complete
# silence at close to zero cost: the fast path reads one small file and exits
# before it has even looked at the payload.

. "$AB_ROOT/tests/lib.sh"

BUDGET_MS="${AGENTBUS_SOLO_BUDGET_MS:-400}"
ROUNDS=20

REPO=$(make_repo solorepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "server", "desc": "the dev API on :8099", "port": 8099,
     "start": "uvicorn app:api --port 8099",
     "patterns": ["\\buvicorn\\b", ":8099\\b"]},
    {"name": "worktree", "desc": "this checkout's tree and index",
     "scope": "worktree",
     "patterns": ["\\bgit\\s+(checkout|switch|stash|reset|rebase|add|commit)\\b"]}
  ]
}
JSON
commit_all "$REPO"

new_session sess-solo "$REPO"
assert_equal 1 "$(cat "$AGENTBUS_HOME/live-count")" "one live session"

# A session that is alone is told nothing at all — no roster, no rules, no
# banner. There is nobody to coordinate with, so there is nothing to say.
out=$(ab_hook session-start "$(payload session sid=sess-solo "cwd=$REPO" title=x)")
assert_empty "$out" "starting alone injects nothing into the session"

GUARDED='curl -sf http://localhost:8099/health'
PAYLOAD=$(payload bash sid=sess-solo "cwd=$REPO" "cmd=$GUARDED" id=solo-1)

out=$(ab_hook pre-tool "$PAYLOAD")
assert_empty "$out" "alone, the fast path says nothing about a guarded command"

# The same must hold one layer down, because on a host without bash the hooks
# call the engine directly and there is no fast path to gate anything.
out=$(ab_engine pre-tool "$PAYLOAD")
assert_empty "$out" "alone, the engine itself also says nothing"

out=$(ab_hook pre-tool "$(payload bash sid=sess-solo "cwd=$REPO" "cmd=git add -A" id=solo-2)")
assert_empty "$out" "alone, a command touching the checkout is not guarded either"

out=$(ab_hook post-batch "$(payload batch sid=sess-solo "cwd=$REPO")")
assert_empty "$out" "alone, there is nothing to deliver between turns"

out=$(ab_hook pre-tool "$(payload file sid=sess-solo "cwd=$REPO" "path=$REPO/README")")
assert_empty "$out" "alone, an edit is not guarded"

assert_equal 0 "$(locks_held)" "alone, nothing is ever claimed"

# ---- cost ------------------------------------------------------------------
#
# Measured on the fast path only, and with the payload built beforehand: what
# is being timed is what Claude Code pays on every single tool call.
#
# The best of three batches, not one batch or an average. This machine is
# running other Claude Code sessions and this suite at the same time, and every
# source of noise can only make a batch slower — so the fastest one is the
# closest estimate of what the gate actually costs, and the assertion stays
# about the gate rather than about how busy the laptop was.

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

best=""
for _batch in 1 2 3; do
  started=$(now_ms)
  for _ in $(seq 1 "$ROUNDS"); do
    printf '%s' "$PAYLOAD" | bash "$AB_ROOT/bin/ab-hook" pre-tool > /dev/null 2>&1
  done
  elapsed=$(( $(now_ms) - started ))
  if [ -z "$best" ] || [ "$elapsed" -lt "$best" ]; then
    best="$elapsed"
  fi
done

if [ "$best" -le "$BUDGET_MS" ]; then
  _ok "$ROUNDS fast-path calls in ${best}ms (budget ${BUDGET_MS}ms)"
else
  _bad "$ROUNDS fast-path calls in ${best}ms (budget ${BUDGET_MS}ms)" \
    "the gate that makes a solo session free is not short-circuiting"
fi

# post-batch is the one event that does NOT simply give up when alone: a session
# that has just left may have handed something over that nobody has read. The
# check it does instead has to stay a couple of builtin reads, or every tool
# batch of every solo session on the machine pays for it.
#
# Measured against a large payload, and that is the whole point. What this gate
# saves is the slurp of stdin, which bash does a byte at a time; against a small
# payload a gate that short-circuits and one that reads the whole thing and
# gives up two checks later are indistinguishable — 109 ms against 113 ms for
# twenty calls. At 128 KB the same pair is 109 ms against roughly 800 ms.
BATCH=$(payload batch sid=sess-solo "cwd=$REPO" pad=131072)
best=""
for _batch in 1 2 3; do
  started=$(now_ms)
  for _ in $(seq 1 "$ROUNDS"); do
    printf '%s' "$BATCH" | bash "$AB_ROOT/bin/ab-hook" post-batch > /dev/null 2>&1
  done
  elapsed=$(( $(now_ms) - started ))
  if [ -z "$best" ] || [ "$elapsed" -lt "$best" ]; then
    best="$elapsed"
  fi
done

if [ "$best" -le "$BUDGET_MS" ]; then
  _ok "$ROUNDS solo post-batch calls in ${best}ms (budget ${BUDGET_MS}ms)"
else
  _bad "$ROUNDS solo post-batch calls in ${best}ms (budget ${BUDGET_MS}ms)" \
    "the unread check is waking the engine when there is nothing to deliver"
fi

# ---- the off switch --------------------------------------------------------
#
# AGENTBUS_OFF is the documented recovery when a hook misbehaves, so it has to
# work on both the fast path and the engine, even with other sessions live.

new_session sess-other "$REPO"
assert_equal 2 "$(cat "$AGENTBUS_HOME/live-count")" "a second session is live"

# Set inside the command substitution's own subshell: an assignment written in
# front of a shell function is not reliably scoped to that call.
out=$(export AGENTBUS_OFF=1; ab_hook pre-tool "$PAYLOAD")
assert_empty "$out" "AGENTBUS_OFF silences the fast path"
out=$(export AGENTBUS_OFF=1; ab_engine pre-tool "$PAYLOAD")
assert_empty "$out" "AGENTBUS_OFF silences the engine"
assert_equal 0 "$(locks_held)" "AGENTBUS_OFF claims nothing on the way past"

finish
