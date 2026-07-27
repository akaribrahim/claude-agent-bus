#!/usr/bin/env bash
# The summary a session leaves behind when it ends.
#
# Everything in it is already on disk. The point is not the data, it is that
# nobody writes it down: a session ends, what it learned goes with it, and the
# next agent re-derives it from the diff or repeats the work. So the two halves
# that must hold are that it is assembled from real state at the one moment
# nobody is around to do it by hand, and that it reaches the other sessions'
# context rather than sitting in a log file they will never open.
#
# It must also stay quiet. A handoff from a session that only read things is
# noise, and noise is what makes the useful ones get skimmed past.

. "$AB_ROOT/tests/lib.sh"

trap stop_services EXIT

PORT=$(free_port)
REPO=$(make_repo handrepo)
mkdir -p "$REPO/api"
python3 - "$REPO/.claude/agent-bus.json" "$PORT" <<'PY'
import json, os, sys
path, port = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"resources": [
    {"name": "web", "desc": "the demo server", "port": port,
     "start": "python3 -m http.server %d --bind 127.0.0.1" % port,
     "patterns": [r"\bhttp\.server\b", r":%d\b" % port]},
    {"name": "db", "desc": "the shared development database",
     "patterns": [r"\bpsql\b"]},
]}, open(path, "w"), indent=2)
PY
commit_all "$REPO"
WT2=$(make_worktree "$REPO" handwt2)

new_session sess-a "$REPO"    # the one that will finish
new_session sess-b "$WT2"     # the one that outlives it
A=$(ab sess-a name)

batch_of() {   # <session id> <cwd> → what that session is told at its next turn
  json_field "$(ab_hook post-batch "$(payload batch "sid=$1" "cwd=$2")")" \
    hookSpecificOutput additionalContext
}

# Drain whatever the joins produced, so what is asserted below is the handoff.
batch_of sess-b "$WT2" > /dev/null

# ---- a session that did nothing leaves quietly ------------------------------

new_session sess-idle "$REPO"
end_session sess-idle
out=$(batch_of sess-b "$WT2")
assert_not_contains "$out" "finished on" "a session that did nothing writes no handoff"

# …and neither does one whose only writes were outside the repository.
new_session sess-scratch "$REPO"
ab_hook record-write "$(payload write sid=sess-scratch "cwd=$REPO" \
  "path=$TEST_TMP/elsewhere.txt")" > /dev/null
end_session sess-scratch
out=$(batch_of sess-b "$WT2")
assert_not_contains "$out" "finished on" \
  "nor one whose only write was a scratch file somewhere else"

# ---- a session that worked leaves a summary ---------------------------------

ab sess-a doing "rewriting the token refresh" > /dev/null
for f in token.py session.py tests_token.py; do
  ab_hook record-write "$(payload write sid=sess-a "cwd=$REPO" \
    "path=$REPO/api/$f")" > /dev/null
done
# Written twice: the count is of files, not of writes.
ab_hook record-write "$(payload write sid=sess-a "cwd=$REPO" \
  "path=$REPO/api/token.py")" > /dev/null

# A scratch file outside the repository is not work to hand over. The first
# handoff this plugin ever wrote for real was from a session whose only write
# was /tmp/claude-clip.txt, which is exactly the noise that stops the useful
# ones being read.
ab_hook record-write "$(payload write sid=sess-a "cwd=$REPO" \
  "path=$TEST_TMP/scratch-notes.txt")" > /dev/null

ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=psql -l" id=h-1)" > /dev/null
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=h-1)" > /dev/null
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=psql -c x" id=h-2)" > /dev/null
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=h-2)" > /dev/null

ab sess-a own "api/**" --why "auth rewrite" > /dev/null
ab sess-a serve web > /dev/null 2>&1

# `handoff` on demand, before asserting the automatic one — the summary has to
# be readable while the session is still running, not only after it has gone.
out=$(ab sess-a handoff --note "second half is untested")
assert_contains "$out" "finished on main" "the summary names the branch"
assert_contains "$out" "handrepo" "and the worktree"
assert_contains "$out" "rewriting the token refresh" "and what it was doing"
assert_contains "$out" "wrote     : 3 files" "and how many files, counted once each"
assert_not_contains "$out" "scratch-notes" \
  "counting only what was written inside the repository"
assert_contains "$out" "api/token.py" "naming them repository-relative"
assert_contains "$out" "claimed   : 2 commands" "and how many commands took a resource"
assert_contains "$out" "STILL RUNNING" "and that the service it started is still up"
assert_contains "$out" "agentbus serve web" "with what to do about that"
assert_contains "$out" "api/**" "and the scope it is about to release"
assert_contains "$out" "second half is untested" "and the note it was given"
assert_contains "$out" "sent to 1 session" "and it says where it went"

# ---- it arrives in the other session's context ------------------------------

out=$(batch_of sess-b "$WT2")
assert_contains "$out" "finished on main" "the other session is told, at its next turn"
assert_contains "$out" "STILL RUNNING" "including the part it can act on"
assert_equal 1 "$(printf '%s\n' "$out" | grep -c '^      agent-bus: ')" \
  "and a multi-line summary is indented under its own heading, not run together"

# ---- and again, automatically, when the session actually ends ---------------

end_session sess-a
out=$(batch_of sess-b "$WT2")
assert_contains "$out" "finished on main" "ending the session writes one by itself"
assert_contains "$out" "api/token.py" "assembled from state that is about to be deleted"
assert_contains "$out" "STILL RUNNING" "and the detached service is still reported"

assert_no_file "$AGENTBUS_HOME/writes/sess-a.log" "the writes log is gone afterwards"
assert_no_file "$AGENTBUS_HOME/owns/sess-a.json" "and so is the ownership record"

# The service really is still up: that is the whole reason the line exists.
assert_equal "$(ab sess-b serves | grep -c web)" 1 "the service outlived its session"

# ---- alone, there is nobody to hand over to ---------------------------------

new_session sess-solo "$REPO"
ab_hook record-write "$(payload write sid=sess-solo "cwd=$REPO" \
  "path=$REPO/api/lonely.py")" > /dev/null
end_session sess-b
assert_equal 1 "$(cat "$AGENTBUS_HOME/live-count")" "one session left"

before=$(read_seq)
end_session sess-solo
assert_equal "$before" "$(read_seq)" \
  "the last session out writes nothing at all"

finish
