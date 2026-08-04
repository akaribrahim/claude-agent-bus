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
def who(name):    # the live session an agent name belongs to
    return [s for s in d['sessions'] if s['agent'] == name][0]
print($1)"
}

assert_equal 2 "$(state 'len(d["sessions"])')" "the snapshot has both sessions"
assert_equal 1 "$(state 'len([s for s in d["sessions"] if s["agents"]])')" \
  "and the subagent under the one that started it"
assert_equal "wiring the board" "$(state 'd["sessions"][0]["doing"] or d["sessions"][1]["doing"]')" \
  "with what a session said it was doing"
assert_equal 1 "$(state 'len(d["locks"])')" "the held resource is there"
assert_equal db "$(state 'd["locks"][0]["resource"]')" "named"

# ---- services: every declared one, held or free -----------------------------
#
# Not only the ones somebody has started. "Nobody is holding the simulator" is
# as much of an answer as "she is", and a service that has never been started
# is the state a reader most needs to be able to see.

assert_equal 1 "$(state 'len(d["serves"])')" "the declared resource is listed"
assert_equal db "$(state 'd["serves"][0]["resource"]')" "by name"
assert_contains "$(state 'd["serves"][0]["held_by"]')" "$(ab sess-b name)" \
  "with the agent that is holding it"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT2" id=bd-1)" > /dev/null
assert_equal "" "$(state 'd["serves"][0]["held_by"]')" \
  "and nothing there once it is given back, so free reads as free"

# A serve record whose process is gone, in a repo nobody is live in, is cruft
# from an earlier shape of the tree — this machine carries three — and listing
# its resources beside the real ones puts the same service on the page twice.
python3 -c "
import json, os
json.dump({'resource': 'db', 'repo': 'ghostrepo:0000', 'root': '/nowhere',
           'by': 'gone', 'pid': 999999, 'port': 1},
          open(os.path.join('$AGENTBUS_HOME', 'serves', 'ghost__db.json'), 'w'))"
assert_equal 1 "$(state 'len(d["serves"])')" \
  "a dead service in a repo nobody is in is not listed"
assert_not_contains "$(state 'json.dumps(d["repos"])')" "ghostrepo" \
  "and its repository is not offered as a filter"
assert_contains "$(state 'json.dumps(d["events"])')" "something worth reading" \
  "and the messages, newest first"
assert_equal "$(state 'd["events"][0]["i"]')" "$(read_seq)" \
  "the newest event really is first"

# ---- what each session produced, and where two of them collide --------------
#
# The question somebody merging two chats' work has is not "who is live" but
# "have they both edited the same file", and the answer has to arrive before the
# merge rather than during it. The bus already records every write per session,
# so the collision half of this needs no git at all — only the repository-relative
# form of the path, which is what two worktrees of one repository have in common.

B=$(ab sess-b name)
: > "$WT2/one.py"
commit_all "$WT2"
: > "$WT2/two.py"
commit_all "$WT2"

wrote() {   # <session id> <worktree> <relative path…>
  local sid="$1" root="$2"; shift 2
  for f in "$@"; do
    : > "$root/$f"
    ab_hook record-write "$(payload write "sid=$sid" "cwd=$root" \
      "path=$root/$f")" > /dev/null
  done
}
wrote sess-a "$REPO" shared.py only-a.py
wrote sess-b "$WT2" shared.py only-b.py

assert_equal 2 "$(state 'who("'"$A"'")["wrote_n"]')" \
  "the snapshot counts the files a session has written"
assert_contains "$(state 'json.dumps(who("'"$A"'")["wrote"])')" "only-a.py" \
  "and names them"
assert_equal 1 "$(state 'len(who("'"$A"'")["clash"])')" \
  "one of which the other session has written too"
assert_equal shared.py "$(state 'who("'"$A"'")["clash"][0]["path"]')" \
  "named as the repository sees it, so two worktrees line up on one path"
assert_equal "$B" "$(state '" ".join(who("'"$A"'")["clash"][0]["also"])')" \
  "and the collision names the other one"
assert_equal shared.py "$(state 'who("'"$B"'")["clash"][0]["path"]')" \
  "which the other session is told about too, since either could be merged first"

# Sessions in different projects cannot collide, and pairing them would put a
# warning on the page about two files that have nothing to do with each other.
REPO2=$(make_repo boardrepo2)
commit_all "$REPO2"
new_session sess-c "$REPO2"
C=$(ab sess-c name)
wrote sess-c "$REPO2" shared.py
assert_equal 0 "$(state 'len(who("'"$C"'")["clash"])')" \
  "the same path in another repository is not a collision"
assert_equal "$B" "$(state '" ".join(who("'"$A"'")["clash"][0]["also"])')" \
  "and nobody from another project is named beside the session that did collide"

# ---- how far ahead of the trunk, without paying for it on the poll ----------
#
# A `git rev-list` per session per poll, for as long as a tab is open, is a cost
# a window that only watches has no business imposing. So the poll runs no git:
# it serves a cached number and hands the counting to a thread.

warm() {   # <expression over `d` (a later poll), `who`, `poll`, `stale`>
  python3 -c "
import importlib.machinery, importlib.util, json, os, time
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
def poll(name):
    return [s for s in ab.board_state()['sessions'] if s['agent'] == name][0]
def stale(root, name):    # a cached number older than the TTL
    ab._GIT[root] = {'at': ab.now() - 3600, 'ahead': 99, 'base': 'main'}
    return poll(name)
ab.board_state()          # the first poll asks for the count and does not wait
for _ in range(100):
    d = ab.board_state()
    if all(s['ahead_of'] is not None for s in d['sessions']):
        break
    time.sleep(0.05)
def who(name):
    return [s for s in d['sessions'] if s['agent'] == name][0]
print($1)"
}

assert_equal None "$(state 'who("'"$B"'")["ahead"]')" \
  "the first poll of a fresh board runs no git and says so"
assert_equal None "$(state 'who("'"$B"'")["ahead_of"]')" \
  "with nothing named as the thing it has not counted against yet"
assert_equal 2 "$(warm 'who("'"$B"'")["ahead"]')" \
  "a later poll has the commits that worktree is ahead by"
assert_equal main "$(warm 'who("'"$B"'")["ahead_of"]')" \
  "counted against the branch the repository itself calls default, no remote to ask"
assert_equal 0 "$(warm 'who("'"$A"'")["ahead"]')" \
  "and the checkout sitting on that branch is ahead by nothing"
assert_equal None "$(warm 'stale("'"$WT2"'", "'"$B"'")["ahead"]')" \
  "a number older than the cache TTL is not served as though it were current"

# ---- which window to poke ---------------------------------------------------
#
# An idle session with messages it has never been shown is invisible today, so
# the reader messages every chat instead of the one that is waiting.

assert_equal 1 "$(state 'who("'"$B"'")["unread"]')" \
  "a session that has not been shown a message is counted as behind by one"
assert_equal 0 "$(state 'who("'"$A"'")["unread"]')" \
  "and the session that sent it is not behind on its own message"
assert_equal False "$(state 'who("'"$B"'")["waiting"]')" \
  "a session still working is not waiting: it will read the bus at its next turn"

quiet() {   # <session id…> — silent for longer than IDLE_SECS, nowhere near stale
  python3 -c "
import os, sys, time
for sid in sys.argv[1:]:
    beat = os.path.join('$AGENTBUS_HOME', 'sessions', sid + '.beat')
    old = time.time() - 400
    os.utime(beat, (old, old))" "$@"
}
quiet sess-b sess-c
assert_equal True "$(state 'who("'"$B"'")["idle"]')" "once it has gone quiet"
assert_equal True "$(state 'who("'"$B"'")["waiting"]')" \
  "an idle session with an unread message is the one thing asking to be poked"
assert_equal True "$(state 'who("'"$C"'")["idle"]')" "while another sits quiet too"
assert_equal False "$(state 'who("'"$C"'")["waiting"]')" \
  "which is not asking for anything, because it has been shown everything"

# Reading the bus for real clears it — the count is the same one the session is
# handed, not a second opinion computed a different way.
ab_hook prompt-submit "$(payload session sid=sess-b "cwd=$WT2")" > /dev/null
assert_equal 0 "$(state 'who("'"$B"'")["unread"]')" \
  "and the count is gone once the session has actually been shown the message"
# The hook that delivered it was also a heartbeat, so the session is no longer
# quiet. Put it back, or "not waiting" would be true for the wrong reason and
# would keep being true if the count stopped working.
quiet sess-b
assert_equal True "$(state 'who("'"$B"'")["idle"]')" "still quiet afterwards"
assert_equal False "$(state 'who("'"$B"'")["waiting"]')" \
  "so an idle session that is up to date stops asking for attention"

# The session in the other project has served its purpose; the read-only checks
# below count what is live, and they were written when this file had two.
end_session sess-c

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

# ---- the page is updated, not rebuilt ---------------------------------------
#
# It polls for as long as a tab is open. Assigning innerHTML would replace the
# DOM each time: a selection dies mid-sentence, anything the reader had opened
# snaps shut, and nothing can be shown as having CHANGED, because after a
# wholesale redraw everything is equally new. Keeping every value out of markup
# is also what makes it impossible for a branch name or a message to arrive as
# HTML, so this one line stands in for both.

assert_not_contains "$html" "innerHTML" \
  "the page never builds markup from data, so a poll cannot replace the DOM"
# The one that bit: BOARD_HTML is Python source, and an unescaped \n written for
# a JavaScript string is converted on the way past. The page then arrives with a
# real newline inside a string literal, which is a syntax error — and a page whose
# script does not parse renders nothing at all while still serving a valid 200.
assert_contains "$html" 'join("\n")' \
  "and its newline escapes survive Python's own parsing of the source"

# Whether a value is drawn WELL needs a browser, and this file has none — these
# only catch the regression that does not need one: a fact added to the snapshot
# and wired to nothing, which is a cost paid on every poll for a number no reader
# ever sees. They say "reads" because that is all a search of the source can know.
assert_contains "$html" "s.ahead_of" "the page reads how far ahead of the trunk"
assert_contains "$html" "s.clash" "and the files two sessions have both written"
assert_contains "$html" "s.unread" "and how many messages a session has not seen"
assert_contains "$html" "s.waiting" "and which session is waiting to be poked"
# The divider is per-reader, so it is remembered in the browser: the server is
# read-only, and a cursor kept there would be one two tabs had to fight over.
assert_contains "$html" 'localStorage.getItem("ab-seen")' \
  "and remembers where the reader was in the browser, not on the server"

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
