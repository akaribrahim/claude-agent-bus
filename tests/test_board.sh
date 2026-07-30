#!/usr/bin/env bash
# The board: a window onto the bus, served to this machine and no other.
#
# Three properties matter more than what it looks like.
#
#   1. It is READ-ONLY. It polls every couple of seconds for as long as a tab
#      is open, so if it reaped sessions or rewrote the derived files the act of
#      watching the bus would change it — and the numbers somebody is watching
#      would be partly their own reflection.
#   2. It is LOOPBACK-ONLY. This data is every branch name, worktree path and
#      message on the machine.
#   3. The page is SELF-CONTAINED. A dashboard that fetches a stylesheet from a
#      CDN tells that CDN when you are working and from which repository, and
#      stops rendering on a plane.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo boardrepo)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "the shared development database",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT2=$(make_worktree "$REPO" boardwt2)

new_session sess-a "$REPO"
new_session sess-b "$WT2"
A=$(ab sess-a name)
ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-1 agent_type=general-purpose)" > /dev/null
ab sess-a doing "wiring the board" > /dev/null
ab sess-a post "something worth reading" > /dev/null
ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" "cmd=psql -c 'select 1'" id=bd-1)" > /dev/null

# ---- the snapshot carries what the page draws -------------------------------

state() {   # <python expression over `d`>
  python3 -c "
import importlib.machinery, importlib.util, json, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
d = ab.board_state()
print($1)"
}

assert_equal 2 "$(state 'len(d["sessions"])')" "the snapshot has both sessions"
assert_equal 1 "$(state 'len([s for s in d["sessions"] if s["agents"]])')" \
  "and the subagent under the one that started it"
assert_equal "wiring the board" "$(state 'd["sessions"][0]["doing"] or d["sessions"][1]["doing"]')" \
  "with what a session said it was doing"
assert_equal 1 "$(state 'len(d["locks"])')" "the held resource is there"
assert_equal db "$(state 'd["locks"][0]["resource"]')" "named"
assert_contains "$(state 'json.dumps(d["events"])')" "something worth reading" \
  "and the messages, newest first"
assert_equal "$(state 'd["events"][0]["i"]')" "$(read_seq)" \
  "the newest event really is first"

# ---- read-only: watching must not change what is watched --------------------

# A fingerprint of everything an engine run would normally rewrite.
derived() {
  python3 -c "
import hashlib, os
h = hashlib.sha1()
for p in ('live-count', 'guard-tokens', 'events.seq', 'events.jsonl'):
    f = os.path.join('$AGENTBUS_HOME', p)
    h.update(open(f, 'rb').read() if os.path.exists(f) else b'-')
for d in ('cursors', 'locks', 'sessions', 'agents'):
    base = os.path.join('$AGENTBUS_HOME', d)
    for n in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        h.update(n.encode())
        h.update(open(os.path.join(base, n), 'rb').read())
print(h.hexdigest())"
}
# A session that is genuinely reapable — dead pid, silent for longer than
# STALE_BEAT. Any ordinary engine run would delete it and release what it held.
# The board must leave it exactly where it is: reaping is a write, and a window
# that refreshes by itself has no business performing maintenance.
python3 -c "
import json, os, time
home = '$AGENTBUS_HOME'
json.dump({'agent': 'ghost', 'pid': 999999, 'cwd': '$REPO', 'root': '$REPO',
           'repo_key': 'x:1', 'repo_label': 'x', 'branch': 'main',
           'started': int(time.time()) - 9000},
          open(os.path.join(home, 'sessions', 'sess-dead.json'), 'w'))
beat = os.path.join(home, 'sessions', 'sess-dead.beat')
open(beat, 'w').close()
old = time.time() - 4000            # > STALE_BEAT (45m), pid is not alive
os.utime(beat, (old, old))"
assert_file "$AGENTBUS_HOME/sessions/sess-dead.json" "a reapable session is planted"

before=$(derived)
state 'len(d["sessions"])' > /dev/null
state 'len(d["sessions"])' > /dev/null
assert_equal "$before" "$(derived)" \
  "polling the board changes no state at all — not a cursor, not live-count"
assert_file "$AGENTBUS_HOME/sessions/sess-dead.json" \
  "and a dead session is left on disk rather than reaped behind the user's back"
assert_equal 2 "$(state 'len(d["sessions"])')" \
  "while still being left out of what the page shows"

# For contrast: a command the user actually asked for is allowed to reap it.
ab sess-a status > /dev/null
assert_no_file "$AGENTBUS_HOME/sessions/sess-dead.json" \
  'which status, asked a question by a person, does do'

# ---- the page is self-contained ---------------------------------------------

html=$(python3 -c "
import importlib.machinery, importlib.util, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
print(ab.BOARD_HTML)")
assert_not_contains "$html" 'src="http' "the page loads no external script"
assert_not_contains "$html" 'href="http' "and no external stylesheet or font"
assert_not_contains "$html" "cdn." "and nothing from a CDN"
assert_contains "$html" "prefers-color-scheme" "it renders in dark mode too"

# ---- it serves, and only to this machine ------------------------------------

if ! command -v python3 > /dev/null; then
  skip_test "no python3 to drive an HTTP client"
fi

"$AB_ROOT/bin/agentbus" board --port 0 --no-open > "$TEST_TMP/board.out" 2>&1 &
BOARD_PID=$!
trap 'kill $BOARD_PID 2>/dev/null' EXIT
url=""
for _ in $(seq 40); do
  url=$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*\)/.*|\1|p' "$TEST_TMP/board.out" | head -1)
  [ -n "$url" ] && break
  sleep 0.25
done

if [ -z "$url" ]; then
  _bad "the board prints the URL it is serving" "$(cat "$TEST_TMP/board.out")"
else
  _ok "the board prints the URL it is serving"
  port="${url##*:}"
  assert_contains "$url" "127.0.0.1" "bound to the loopback address, not 0.0.0.0"

  get() {   # <path> → "<status> <body>"
    python3 -c "
import sys, urllib.error, urllib.request
try:
    r = urllib.request.urlopen('$url' + sys.argv[1], timeout=10)
    print(r.status, r.read().decode('utf-8', 'replace'))
except urllib.error.HTTPError as e:
    print(e.code, '')" "$1"
  }
  out=$(get /)
  assert_contains "$out" "200" "the page is served"
  assert_contains "$out" "<title>agent-bus" "and it is the board"
  out=$(get /data)
  assert_contains "$out" "200" "the data endpoint answers"
  assert_contains "$out" '"sessions"' "with the snapshot"
  assert_contains "$out" "something worth reading" "including what was said"
  assert_contains "$(get /nope)" "404" "and anything else is a 404"

  # The one that matters: nothing outside this machine may reach it. Binding to
  # 127.0.0.1 is what guarantees that, and this asserts the guarantee rather
  # than the line of code that makes it.
  reachable=$(python3 -c "
import socket
s = socket.socket()
s.settimeout(2)
ip = None
try:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.connect(('8.8.8.8', 80))
    ip = probe.getsockname()[0]
    probe.close()
except Exception:
    pass
if not ip or ip.startswith('127.'):
    print('skip')
else:
    try:
        s.connect((ip, $port))
        print('yes')
    except Exception:
        print('no')")
  case "$reachable" in
    no)   _ok "a connection from this machine's LAN address is refused" ;;
    skip) _ok "a connection from this machine's LAN address is refused (skipped: no LAN address)" ;;
    *)    _bad "a connection from this machine's LAN address is refused" \
            "the board answered on a non-loopback address" ;;
  esac
fi

kill $BOARD_PID 2>/dev/null
trap - EXIT

finish
