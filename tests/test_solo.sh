#!/usr/bin/env bash
# What the plugin costs and says when you are the only session on the machine.
#
# This is the common case — most of the time nobody else is running — and it is
# the case where a bug is most expensive, because the hooks fire on every tool
# call of every session on this Mac. Alone, the correct behaviour is complete
# silence at close to zero cost: the fast path reads one small file and exits
# before it has even looked at the payload.

. "$AB_ROOT/tests/lib.sh"

# Both cost checks below are RATIOS against a floor measured in the same run,
# not wall-clock budgets. They used to be budgets, and on 2026-08-02 one of them
# failed once in five suite runs with nothing wrong: this Mac had six Claude Code
# sessions on eight cores, load average 10, and 20 calls took 517 ms against a
# 400 ms budget. Two days later it failed two runs in three under the same load.
#
# The mitigation already here — best of three batches — is not enough, because
# under real load every batch is slow. A budget measured in milliseconds on a
# machine whose whole purpose is running several agents at once is measuring the
# machine. The property is a ratio, and a ratio survives load because the floor
# inflates with it. Same lesson as the plugin's own performance gate, which was
# moved off absolute figures for exactly this reason and then turned out not to
# resolve on the delta either.
#
# `AGENTBUS_SOLO_MAX_X100` overrides the multiple, in hundredths.
MAX_X100="${AGENTBUS_SOLO_MAX_X100:-500}"
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
out=$(ab_hook session-start "$(payload session sid=sess-solo "cwd=$REPO")")
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

# The best of three batches, not one or an average: noise can only make a batch
# slower, so the fastest is the closest estimate of what the thing itself costs.
fastest() {   # <command, run $ROUNDS times> → milliseconds
  local best="" started elapsed
  for _batch in 1 2 3; do
    started=$(now_ms)
    for _ in $(seq 1 "$ROUNDS"); do
      eval "$1" > /dev/null 2>&1
    done
    elapsed=$(( $(now_ms) - started ))
    if [ -z "$best" ] || [ "$elapsed" -lt "$best" ]; then
      best="$elapsed"
    fi
  done
  printf '%d' "${best:-0}"
}

# The floor: starting bash $ROUNDS times and doing nothing. A fast path that
# short-circuits is that plus one small file read. One that wakes the engine is
# that plus a Python start and a 6700-line recompile — an order of magnitude,
# not a percentage — so the multiple separates the two however busy the laptop is.
floor=$(fastest "bash -c :")
[ "$floor" -lt 1 ] && floor=1

fast=$(fastest 'printf "%s" "$PAYLOAD" | bash "$AB_ROOT/bin/ab-hook" pre-tool')
ratio=$(( 100 * fast / floor ))
if [ "$ratio" -le "$MAX_X100" ]; then
  _ok "the fast path costs ${ratio}% of a bare bash start (limit ${MAX_X100}%)"
else
  _bad "the fast path costs ${ratio}% of a bare bash start (limit ${MAX_X100}%)" \
    "the gate that makes a solo session free is not short-circuiting: ${fast}ms against a ${floor}ms floor for $ROUNDS calls"
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
# There is deliberately no timing assertion for it, and the reason is worth
# leaving here because the obvious one looks convincing and is not.
#
# The figures above came from a version of the gate that read the payload in
# bash before deciding, a byte at a time. It does not any more: `unread` reads
# `events.seq` and the cursor files, all small, and stdin is passed through to
# the engine untouched. So the small-against-large ratio no longer moves when
# the gate breaks — a `PAY=$(cat)` put back in front of it was measured at under
# a millisecond against 128 KB, invisible beside the cost of starting bash at
# all. An assertion on it passed with the gate deliberately broken, which is the
# definition of measuring nothing.
#
# The property itself is tested exactly rather than by stopwatch, in
# `tests/test_pyhook.sh`: a `post-batch` with nothing unread must not wake the
# engine, asserted against a stub engine that records whether it was run, and
# asserted of BOTH fast paths so they cannot drift apart. That is the check;
# this file's job is the cost of the door that is already known to be shut.

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

# ---- a payload it cannot read is said out loud, not swallowed ---------------
#
# A hook that returns nothing is byte-identical to one that considered the call
# and allowed it, so a guard that fails open must say so. On Windows,
# PowerShell prepends a UTF-8 BOM when piping to a native executable and
# `json.loads` raises on the first character; three debugging sessions were
# spent concluding the ownership guard was broken when the payload had simply
# not parsed. The same `except ValueError` also caught `UnicodeDecodeError`,
# which is how a filename with a byte undefined in the console codepage turned
# the guard off for that call.

P=$(payload bash sid=sess-solo "cwd=$REPO" "cmd=git add -A" id=bom-1)
out=$(printf '\357\273\277%s' "$P" | "$AB_ROOT/bin/agentbus" hook pre-tool 2>"$TEST_TMP/bom.err")
rc=$?
assert_equal 0 "$rc" "a payload with a UTF-8 BOM still exits 0"
assert_equal "" "$(cat "$TEST_TMP/bom.err")" "and is read, not reported as broken"

out=$(printf 'this is not json' | "$AB_ROOT/bin/agentbus" hook pre-tool 2>"$TEST_TMP/bad.err")
assert_equal 0 "$?" "a payload that really is unreadable still exits 0"
assert_equal "" "$out" "prints nothing on stdout, which the session parses"
assert_contains "$(cat "$TEST_TMP/bad.err")" "guard was skipped"   "and says on stderr that it failed open"


finish
