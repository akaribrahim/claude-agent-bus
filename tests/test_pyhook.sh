#!/usr/bin/env bash
# The Python fast path decides exactly what the bash one decides.
#
# Windows has no shell to gate hooks with, so `bin/hook.py` does the same job
# in Python: answer "nothing to do here" without loading the engine. That is
# worth having — measured on a Windows 10 host with endpoint scanning, a hook
# with nothing to do cost 281 ms, of which 178 ms was spent getting ready to
# decide there was nothing to do — but it is also a second implementation of
# the one thing in this plugin that must never be wrong twice.
#
# So the point of this file is parity, not behaviour: every case is put through
# both entry points and their answers compared. A guard that fires on macOS and
# not on Windows is worse than one that fires on neither, because nobody looks
# for it.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo pyrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "the shared development database",
     "why": "One database for every worktree.",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT2=$(make_worktree "$REPO" pywt2)

# Compare the two entry points on one payload. Both are asked; both are held to
# the exit-0-and-valid-JSON invariant by their helpers; then the decisions are
# compared rather than the wording.
same() {   # <label> <event> <payload>
  local sh py d_sh d_py
  sh=$(ab_hook "$2" "$3")
  py=$(ab_pyhook "$2" "$3")
  d_sh=$(json_field "$sh" hookSpecificOutput permissionDecision)
  d_py=$(json_field "$py" hookSpecificOutput permissionDecision)
  assert_equal "${d_sh:-none}" "${d_py:-none}" "$1"
}

# ---- alone: both stay out of the way ----------------------------------------

new_session sess-a "$REPO"
CMD='psql -c "select 1"'

same "alone, a guarded command: both allow" pre-tool \
  "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$CMD" id=py-1)"
assert_equal 0 "$(locks_held)" "and neither claimed anything"

out=$(ab_pyhook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=ls -la" id=py-2)")
assert_empty "$out" "an unguarded command says nothing"

# ---- two sessions: both guard -----------------------------------------------

new_session sess-b "$WT2"
assert_equal 2 "$(cat "$AGENTBUS_HOME/live-count")" "both sessions are live"

out=$(ab_pyhook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$CMD" id=py-3)")
assert_allow "$out" "the python path lets the first session through"
assert_equal 1 "$(locks_held)" "and really takes the lock"

same "the second session: both deny" pre-tool \
  "$(payload bash sid=sess-b "cwd=$WT2" "cmd=$CMD" id=py-4)"
reason=$(json_field "$(ab_pyhook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=$CMD" id=py-5)")" hookSpecificOutput permissionDecisionReason)
assert_contains "$reason" "development database" "with the same explanation"
assert_equal 1 "$(locks_held)" "and a denied command claims nothing"

ab_pyhook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=py-3)" > /dev/null
assert_equal 0 "$(locks_held)" "post-bash gives it back"

# The token pre-filter is the cheap gate both share: a command with none of the
# configured literals in it must not reach the engine at all.
same "a command matching no token: both allow" pre-tool \
  "$(payload bash sid=sess-b "cwd=$WT2" "cmd=echo nothing to see" id=py-6)"

# ---- writes are recorded, and pushed into the other session's filter --------

W="$REPO/service.py"
ab_pyhook record-write "$(payload write sid=sess-a "cwd=$REPO" "path=$W")" > /dev/null
assert_contains "$(cat "$AGENTBUS_HOME/writes/sess-a.log")" "$W" \
  "the python path records a write"
assert_contains "$(cat "$AGENTBUS_HOME/hot-for/sess-b")" "$W" \
  "and pushes it into the other session's filter"

# ---- an edit against a file somebody else just wrote ------------------------

same "an edit onto a fresh write: both deny" pre-tool \
  "$(payload file sid=sess-b "cwd=$REPO" "path=$W" tool=Edit)"

# A file nobody has touched is not in hot-for, so neither wakes the engine.
same "an edit elsewhere: both allow" pre-tool \
  "$(payload file sid=sess-b "cwd=$REPO" "path=$REPO/untouched.py" tool=Edit)"

# ---- messages are delivered ------------------------------------------------

ab sess-a post "the python path should carry this" > /dev/null
out=$(ab_pyhook post-batch "$(payload batch sid=sess-b "cwd=$WT2" "cmd=ls" id=py-7)")
assert_contains "$(json_field "$out" hookSpecificOutput additionalContext)" \
  "should carry this" "a message reaches the other session through hook.py"

out=$(ab_pyhook post-batch "$(payload batch sid=sess-b "cwd=$WT2" "cmd=ls" id=py-8)")
assert_empty "$out" "and is not delivered twice"

# ---- the payload shapes that break a naive reader ---------------------------
#
# PowerShell prepends a UTF-8 BOM when piping to a native executable, and this
# file scans the payload as text rather than parsing it — so both the BOM and
# whitespace around the colons have to be tolerated, or the gate silently
# decides there is nothing to do.

ab_pyhook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$CMD" id=py-hold)" > /dev/null
assert_equal 1 "$(locks_held)" "the first session is holding it again"

P=$(payload bash sid=sess-b "cwd=$WT2" "cmd=$CMD" id=py-9)
out=$(printf '\357\273\277%s' "$P" | python3 "$AB_ROOT/bin/hook.py" pre-tool)
assert_deny "$out" "a payload with a UTF-8 BOM is still guarded"

COMPACT=$(python3 -c "
import json, sys
print(json.dumps(json.loads(sys.argv[1]), separators=(',', ':')))" "$P")
out=$(printf '%s' "$COMPACT" | python3 "$AB_ROOT/bin/hook.py" pre-tool)
assert_deny "$out" "and so is one with no spaces around its colons"
ab_pyhook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=py-hold)" > /dev/null

# ---- the reason this file exists: the bytecode cache ------------------------
#
# Python writes no bytecode for a script it runs as __main__, so calling the
# engine directly recompiles five thousand lines on every hook. hook.py imports
# it as a module instead, which is cached — 4 ms against 30 ms here, and 71 ms
# on the Windows host this was written for.

rm -rf "$AB_ROOT/bin/__pycache__"
ab_pyhook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" "cmd=$CMD" id=py-10)" > /dev/null
assert_file "$AB_ROOT/bin/__pycache__" \
  "waking the engine through hook.py leaves a bytecode cache behind"

# ---- and it never loads the engine when there is nothing to do --------------
#
# The whole saving is here: on a host with no fast path the engine was loaded
# to discover it had no work. If this stops being true the cost comes back and
# nothing else in the suite would notice.

# The pre-filter greps the WHOLE payload, cwd included — and this suite runs
# under a directory called `agentbus-tests…`, so a payload from inside it
# always contains a token and always wakes the engine. That is correct
# behaviour and a fair warning about paths, but it makes the fixture unable to
# measure the saving, so this one is asked from somewhere neutral.
rm -rf "$AB_ROOT/bin/__pycache__"
NEUTRAL=$(python3 -c "
import json
print(json.dumps({'session_id': 'sess-b', 'cwd': '/tmp',
                  'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                  'tool_input': {'command': 'echo hello'},
                  'tool_use_id': 'py-11'}))")
printf '%s' "$NEUTRAL" | python3 "$AB_ROOT/bin/hook.py" pre-tool > /dev/null
assert_no_file "$AB_ROOT/bin/__pycache__" \
  "a command with nothing to guard never loads the engine at all"

ab_pyhook record-write "$(payload write sid=sess-a "cwd=$REPO" "path=$REPO/x.py")" > /dev/null
assert_no_file "$AB_ROOT/bin/__pycache__" \
  "and neither does recording a write, which it does by itself"


# =============================================================================
# Every branch of the gate, both entry points, same answer
# =============================================================================
#
# The assertions above compare decisions, which is the right thing to compare
# and reaches only the branches that end in a decision. Most of the gate does
# not: it ends in "nothing to do here", and the whole reason both files exist
# is to reach that answer without starting the engine. A branch that stops
# short on one platform and not on the other is either a guard that fires in
# one place, or a cost that comes back in the other, and nothing in this suite
# could see either.
#
# So both files are copied beside a stand-in engine, and every branch is asked
# of both: the exit code, anything printed, and whether the engine was woken
# and for which event. The stand-in is a Python file that is also an executable
# script, because `bin/ab-hook` execs the engine and `bin/hook.py` imports it as
# a module — the two ways of reaching it are themselves a thing the copies have
# to agree about.

FAST="$TEST_TMP/fastpath"
mkdir -p "$FAST"
cp "$AB_ROOT/bin/ab-hook" "$AB_ROOT/bin/hook.py" "$FAST/"
cat > "$FAST/agentbus" <<'PY'
#!/usr/bin/env python3
"""A stand-in engine that records being woken and decides nothing.

Reached two ways, as the real one is: `bin/ab-hook` execs it with `hook <event>`
and `bin/hook.py` imports it and calls `run_hook`. Both land in `_note`."""
import os
import sys


def _note(event):
    path = os.environ.get("FASTPATH_LOG")
    if path:
        with open(path, "a") as fh:
            fh.write((event or "?") + "\n")


def ensure_dirs():
    pass


def run_hook(event, raw):
    _note(event)


if __name__ == "__main__":
    _note(sys.argv[2] if len(sys.argv) > 2 else "")
PY
chmod +x "$FAST/agentbus"
export FASTPATH_LOG="$TEST_TMP/fastpath.log"

GATE_ENV=""

one_gate() {   # <sh|py> <event> <payload> → "<rc>|<woken for>|<stdout>"
  local out rc woke
  : > "$FASTPATH_LOG"
  if [ "$1" = sh ]; then
    out=$(printf '%s' "$3" | env $GATE_ENV bash "$FAST/ab-hook" "$2" 2>/dev/null)
  else
    out=$(printf '%s' "$3" | env $GATE_ENV python3 "$FAST/hook.py" "$2" 2>/dev/null)
  fi
  rc=$?
  woke=$(tr '\n' ' ' < "$FASTPATH_LOG")
  printf '%s|%s|%s' "$rc" "${woke% }" "$out"
}

# Ask both, require the same answer, and leave the answer in $GATE_RC /
# $GATE_WOKE for the assertion that says what the answer should have been.
# Agreement alone is not enough: two files that both stopped guarding would
# agree perfectly.
gate() {   # <label> <event> <payload>
  local a b rest
  a=$(one_gate sh "$2" "$3")
  b=$(one_gate py "$2" "$3")
  assert_equal "$a" "$b" "$1"
  GATE_RC=${a%%|*}
  rest=${a#*|}
  GATE_WOKE=${rest%%|*}
}

woke_for() {   # <event> <label>
  assert_equal "$1" "$GATE_WOKE" "$2"
}

slept() {      # <label>
  assert_equal "" "$GATE_WOKE" "$1"
}

BASH_P=$(payload bash sid=sess-a "cwd=$REPO" "cmd=$CMD" id=g-1)
PLAIN_P=$(payload bash sid=sess-a cwd=/tmp "cmd=echo nothing" id=g-2)
BATCH_P=$(payload batch sid=sess-a "cwd=$REPO" "cmd=$CMD" id=g-3)
IDLE_P=$(payload batch sid=sess-a "cwd=$REPO")
WRITE_P=$(payload write sid=sess-a "cwd=$REPO" "path=$REPO/gate.py")

# ---- the two doors that are shut before anything is read --------------------

GATE_ENV="AGENTBUS_OFF=1"
gate "AGENTBUS_OFF: both entry points agree" session-start \
  "$(payload session sid=sess-a "cwd=$REPO")"
slept "and neither wakes the engine for an event that always wakes it"
GATE_ENV=""

# An engine without its mode bits. `bin/ab-hook` tests for executable and
# `bin/hook.py` used to test only for present — so a checkout that lost the bit
# would stop guarding on macOS and go on guarding on Windows, which is worse
# than either, and is the shape of divergence this whole file exists to catch.
chmod -x "$FAST/agentbus"
gate "an engine that is not executable: both agree" pre-tool "$BASH_P"
slept "and neither starts it"
chmod +x "$FAST/agentbus"

GATE_ENV="AGENTBUS_HOME=$TEST_TMP/no-such-bus"
gate "no state directory at all: both agree" pre-tool "$BASH_P"
slept "and neither wakes the engine looking for one"
GATE_ENV=""

# ---- the events that are never gated ----------------------------------------
#
# Once per session, per user turn, or per subagent. Cheap enough to be always
# worth the engine, and the payload is inherited rather than slurped.

gate "session-start is ungated" session-start "$(payload session sid=sess-a "cwd=$REPO")"
woke_for session-start "and reaches the engine"
gate "session-end is ungated" session-end "$(payload session-end sid=sess-a cwd=/)"
woke_for session-end "and reaches the engine"
gate "prompt-submit is ungated" prompt-submit "$(payload session sid=sess-a "cwd=$REPO")"
woke_for prompt-submit "and reaches the engine"
gate "subagent-start is ungated" subagent-start \
  "$(payload subagent-start sid=sess-a "cwd=$REPO" agent_id=g-sub)"
woke_for subagent-start "and reaches the engine"
gate "subagent-stop is ungated" subagent-stop \
  "$(payload subagent-stop sid=sess-a "cwd=$REPO" agent_id=g-sub)"
woke_for subagent-stop "and reaches the engine"

gate "an event neither of them knows: both agree" nonsense "$BASH_P"
slept "and neither invents a handler for it"

# ---- alone on the bus -------------------------------------------------------
#
# The gate that pays for the whole plugin: one session cannot collide with
# anybody, so nothing below the live count is worth an engine start. Written
# straight into `live-count` here — the real engine keeps it up to date and no
# real engine runs in this section.

printf '1\n' > "$AGENTBUS_HOME/live-count"

gate "alone, a guarded command: both agree" pre-tool "$BASH_P"
slept "and neither wakes the engine, whatever the command touches"
gate "alone, a write: both agree" record-write "$WRITE_P"
slept "and a write is not worth one either"
gate "alone, a finished command: both agree" post-bash \
  "$(payload post-bash sid=sess-a "cwd=$REPO" id=g-1)"
slept "and neither is that"

# The one exception, and the reason it is one: a session that has just left may
# have handed something over that nobody has read, and its own exit is what took
# the count back to one.
SEQ_WAS=$(cat "$AGENTBUS_HOME/events.seq" 2>/dev/null || echo 0)
printf '%s\n' "$SEQ_WAS" > "$AGENTBUS_HOME/cursors/sess-a"
printf '%s\n' "$SEQ_WAS" > "$AGENTBUS_HOME/cursors/sess-b"
gate "alone with nothing unread: both agree" post-batch "$BATCH_P"
slept "and a batch nobody is behind on wakes nothing"

printf '%s\n' "$((SEQ_WAS - 1))" > "$AGENTBUS_HOME/cursors/sess-a"
gate "alone with a handoff unread: both agree" post-batch "$BATCH_P"
woke_for post-batch "and the batch that could deliver it does wake the engine"

# A cursor left behind by a crash would hold that gate open on every batch for
# ever, so one with no session file behind it is skipped.
printf '%s\n' "$SEQ_WAS" > "$AGENTBUS_HOME/cursors/sess-a"
printf '%s\n' "$((SEQ_WAS - 1))" > "$AGENTBUS_HOME/cursors/ghost-session"
gate "a cursor whose session is gone: both agree" post-batch "$BATCH_P"
slept "and neither holds the gate open for it"
rm -f "$AGENTBUS_HOME/cursors/ghost-session"

printf '0\n' > "$AGENTBUS_HOME/events.seq"
gate "alone with an empty event stream: both agree" post-batch "$BATCH_P"
slept "and nobody can be behind on nothing"
printf '%s\n' "$SEQ_WAS" > "$AGENTBUS_HOME/events.seq"

# ---- two live sessions ------------------------------------------------------

printf '2\n' > "$AGENTBUS_HOME/live-count"

rm -f "$AGENTBUS_HOME"/autoclaim/*.json
gate "a finished command with no claim outstanding: both agree" post-bash \
  "$(payload post-bash sid=sess-a "cwd=$REPO" id=g-1)"
slept "and neither looks for locks that were never taken"
: > "$AGENTBUS_HOME/autoclaim/g-1.json"
gate "a finished command with one outstanding: both agree" post-bash \
  "$(payload post-bash sid=sess-a "cwd=$REPO" id=g-1)"
woke_for post-bash "and both go and give it back"
rm -f "$AGENTBUS_HOME/autoclaim/g-1.json"

gate "a batch that ran a command: both agree" post-batch "$BATCH_P"
woke_for post-batch "and both read what it printed"
assert_file "$AGENTBUS_HOME/sessions/sess-a.beat" "the heartbeat is a bare truncate"

printf '%s\n' "$SEQ_WAS" > "$AGENTBUS_HOME/cursors/sess-a"
gate "a batch that ran nothing, with nothing unread: both agree" post-batch "$IDLE_P"
slept "and neither wakes for it — an exact test, not a heuristic"

gate "a batch with no session on it: both agree" post-batch \
  "$(payload batch cwd=/tmp)"
slept "and neither wakes for a payload it cannot attribute"

# ---- record-write, which both handle themselves -----------------------------

gate "a write with a path: both agree" record-write "$WRITE_P"
slept "and neither starts the engine to record it"
assert_contains "$(cat "$AGENTBUS_HOME/writes/sess-a.log")" "$REPO/gate.py" \
  "though both did record it"
gate "a notebook write: both agree" record-write \
  "$(payload write sid=sess-a "cwd=$REPO" "path=$REPO/gate.ipynb" tool=NotebookEdit)"
slept "and neither starts the engine for that either"
gate "a write with no path at all: both agree" record-write \
  "$(payload batch sid=sess-a "cwd=$REPO")"
slept "and there is nothing to record"
gate "a write with no session: both agree" record-write \
  "$(payload write cwd=/tmp "path=/tmp/x.py")"
slept "and nowhere to record it"

# ---- the pre-tool filters ---------------------------------------------------

gate "a Bash command matching a token: both agree" pre-tool "$BASH_P"
woke_for pre-tool "and both hand it to the guard"
gate "a Bash command matching none: both agree" pre-tool "$PLAIN_P"
slept "and neither wakes the guard for it"
gate "a tool that is guarded by nothing: both agree" pre-tool \
  "$(payload file sid=sess-a "cwd=$REPO" "path=$REPO/gate.py" tool=Read)"
slept "and neither looks any further at it"

TOK_WAS=$(cat "$AGENTBUS_HOME/guard-tokens")
printf '\n' > "$AGENTBUS_HOME/guard-tokens"
gate "no tokens to filter on: both agree" pre-tool "$BASH_P"
slept "and a repository declaring nothing costs nothing"
# The catch-all a resource with no mandatory literal produces. Waking the engine
# on every command costs milliseconds; missing the guard costs a silently wrong
# test, so the gate opens for everything — in both files, by different means.
printf '.\n' > "$AGENTBUS_HOME/guard-tokens"
gate "the catch-all token: both agree" pre-tool "$PLAIN_P"
woke_for pre-tool "and everything wakes the guard"
printf '%s\n' "$TOK_WAS" > "$AGENTBUS_HOME/guard-tokens"

HOTFILE="$AGENTBUS_HOME/hot-for/sess-a"
HOT_WAS=$(cat "$HOTFILE" 2>/dev/null)
: > "$HOTFILE"
gate "an edit with an empty filter: both agree" pre-tool \
  "$(payload file sid=sess-a "cwd=$REPO" "path=$REPO/gate.py")"
slept "and neither wakes the engine to say nobody touched it"
printf '%s\n' "$REPO/gate.py" > "$HOTFILE"
gate "an edit onto a path in the filter: both agree" pre-tool \
  "$(payload file sid=sess-a "cwd=$REPO" "path=$REPO/gate.py")"
woke_for pre-tool "and both go and ask about the collision"
gate "an edit somewhere else: both agree" pre-tool \
  "$(payload file sid=sess-a "cwd=$REPO" "path=$REPO/elsewhere.py")"
slept "and neither wakes for a file nobody has written"
gate "an edit with no session on it: both agree" pre-tool \
  "$(payload file cwd=/tmp "path=$REPO/gate.py")"
slept "and neither has a filter to read"
printf '%s' "$HOT_WAS" > "$HOTFILE"

finish
