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

finish
