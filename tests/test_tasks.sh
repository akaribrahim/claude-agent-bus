#!/usr/bin/env bash
# The task ledger: what the agents have taken, and who cannot get on until
# somebody else finishes.
#
# The whole design rests on one thing, so most of this file is about it: an agent
# types a sentence and a reference, and NOTHING else. Every other field on the
# screen is worked out from what the bus already records — the session's branch
# and worktree, its write log, the locks, a lock's queue, the live session list.
# The reason is not tidiness. Agents forget, measurably: `AGENTBUS_OFF` became a
# reflex here, 88 uses in 48 hours of which 76 overrode nothing. A ledger with
# six fields to fill in is one nobody fills in on the afternoon it would have
# mattered, so a field that could be derived and is asked for instead is a defect
# and there are assertions below whose only job is to catch one arriving.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo shopfront)
set_config "$REPO" <<'JSON'
{
  "resources": [
    {"name": "db", "desc": "the shared development database",
     "why": "two migrations at once leaves the schema in neither state",
     "patterns": ["\\bpsql\\b"]}
  ]
}
JSON
commit_all "$REPO"
WT=$(make_worktree "$REPO" web review/web)

new_session sess-a "$REPO"
new_session sess-b "$WT"
A=$(ab sess-a name)
B=$(ab sess-b name)

# One repository's ledger exactly as it is on disk.
led() {   # <python expression over `d` (the ledger dict) and `t(id)`>
  python3 -c "
import glob, json, os
paths = sorted(glob.glob(os.path.join('$AGENTBUS_HOME', 'tasks', '*.json')))
files = [json.load(open(p)) for p in paths]
d = files[0] if files else {'tasks': []}
def t(tid):
    return [x for x in d['tasks'] if x['id'] == tid][0]
print($1)"
}

# The enriched view — the one place that decides what a task's state is, and
# what the board, `status` and the banner all read.
view() {   # <python expression over `v` (list) and `t(id)`>
  python3 -c "
import importlib.machinery, importlib.util, json, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
sessions = ab.load_sessions()
v = ab.ledger_view('$(session_field sess-a repo_key)', sessions)
def t(tid):
    return [x for x in v if x['id'] == tid][0]
print($1)"
}

wrote() {   # <session id> <worktree> <relative path…>
  local sid="$1" root="$2"; shift 2
  for f in "$@"; do
    mkdir -p "$(dirname "$root/$f")"
    : > "$root/$f"
    ab_hook record-write "$(payload write "sid=$sid" "cwd=$root" \
      "path=$root/$f")" > /dev/null
  done
}

# ---- one line in, an id out --------------------------------------------------

out=$(ab sess-a take "fix the review findings in api/")
assert_contains "$out" "t1" "taking a piece of work answers with an id to close it by"
assert_equal 1 "$(led 'len(d["tasks"])')" "and there is one entry in the ledger"
assert_equal "fix the review findings in api/" "$(led 't("t1")["what"]')" \
  "carrying the sentence that was typed"

# State belongs under AGENTBUS_HOME like every lock, and never in the repository:
# a ledger committed by one chat and rebased away by another is not a ledger.
assert_file "$AGENTBUS_HOME/tasks" "the ledger lives under AGENTBUS_HOME"
assert_empty "$(git -C "$REPO" status --porcelain)" \
  "and taking a task writes nothing at all into the repository"

# An agent that re-reads its instructions and says the same thing again is the
# common case, not a mistake worth an error — and certainly not two tasks.
out=$(ab sess-a take "fix the review findings in api/")
assert_contains "$out" "already yours" "saying the same thing twice is not two pieces of work"
assert_equal 1 "$(led 'len(d["tasks"])')" "and adds no second entry"

# ---- everything else is derived ---------------------------------------------
#
# Each of these is a field an agent would otherwise have had to type, and each
# has exactly one source the bus already keeps.

assert_equal "$A" "$(led 't("t1")["agent"]')" "who took it comes from the session"
assert_equal main "$(led 't("t1")["branch"]')" "the branch it is on, from the same record"
assert_equal "$REPO" "$(led 't("t1")["root"]')" "and the checkout it was taken in"

# Files: from the write log, from the moment it was taken. An agent that had to
# list what it had touched would list it wrong.
wrote sess-a "$REPO" api/before.py
sleep 1
out=$(ab sess-a take "rewrite the token store")
assert_contains "$out" "t2" "a second piece of work gets its own id"
wrote sess-a "$REPO" api/token.py api/keys.py
assert_equal 2 "$(view 't("t2")["wrote_n"]')" \
  "a task counts the files written since it was taken"
assert_not_contains "$(view 'json.dumps(t("t2")["wrote"])')" "api/before.py" \
  "and not the ones that were already there when it started"

# Held resources: from the locks. Nothing declares this.
ab sess-a claim db --why "migration 20260804" > /dev/null
assert_equal db "$(view '" ".join(t("t1")["holding"])')" \
  "what its owner is holding comes from the lock, not from the ledger"
assert_not_contains "$(led 'json.dumps(d)')" "holding" \
  "so the ledger has no field for it to disagree with"

# Queued behind somebody: from the lock's own queue, which the wait writes. This
# is the one the brief singles out — a "blocked by" the queue already implies
# must not be declared a second time.
ab sess-b wait db --timeout 0 > /dev/null 2>&1 || true
out=$(ab sess-b take "port the web fixtures")
assert_contains "$out" "t3" "the other session takes something too"
assert_contains "$(view 't("t3")["queued_for"][0]')" "db" \
  "what a task is queued behind comes from the lock queue"
assert_contains "$(view 't("t3")["queued_for"][0]')" "$A" \
  "naming who is in the way, which the queue also already knew"
assert_not_contains "$(led 'json.dumps(d)')" "queued" \
  "and again nothing in the ledger says it"

# ---- the one thing that is typed, because nothing can infer it --------------
#
# A dependency between two pieces of work is not a contention over a resource:
# there is no lock to queue for, nothing is held, and the bus can see a file
# change but not an intention. So it is declared — once, on the waiting side.

out=$(ab sess-b take "rebase web onto main once api lands" --needs t1)
assert_contains "$out" "needs t1" "a task can say which other one has to land first"
assert_equal t1 "$(view '" ".join(t("t4")["blocked_by"])')" \
  "and reads as blocked until it does"
assert_equal "$B" "$(view '" ".join(t("t1")["waiting"])')" \
  "while the task in the way names who is waiting on it — the same declaration, read backwards"
assert_equal '[]' "$(led 'json.dumps(t("t1").get("waiting", []))')" \
  "which is not written on both sides, so the two cannot disagree"

out=$(ab sess-b take "something new" --needs t99 2>&1) && rc=0 || rc=$?
assert_equal 1 "${rc:-0}" "a reference to a task that does not exist is refused"
assert_contains "$out" "no task 't99'" "by name"
assert_equal 4 "$(led 'len(d["tasks"])')" \
  "and nothing is recorded, so nothing is blocked for ever by work nobody can finish"

# ---- finishing --------------------------------------------------------------

out=$(ab sess-a done t1 --note "all four findings closed")
assert_contains "$out" "done t1" "finishing says so"
assert_contains "$out" "$B" "and names the agent it has just unblocked"
assert_equal done "$(led 't("t1")["state"]')" "the ledger records it"
assert_equal 0 "$(view 'len(t("t4")["blocked_by"])')" \
  "the task that was waiting is no longer blocked, without a second declaration"
assert_equal 0 "$(view 'len(t("t1")["waiting"])')" \
  "and nobody is shown as waiting on finished work"

# What it produced is snapshotted when it closes, because it stops being
# answerable later: the write log is deleted with the session, and "what did that
# task produce" is what somebody merging asks tomorrow. So the number stops
# moving — a live count would go on climbing as its owner did other work.
assert_equal 3 "$(view 't("t1")["wrote_n"]')" "a finished task keeps what it wrote"
wrote sess-a "$REPO" api/afterwards.py
assert_equal 3 "$(view 't("t1")["wrote_n"]')" \
  "and stops counting, rather than collecting whatever its owner does next"

out=$(ab sess-a done t1)
assert_contains "$out" "already done" "finishing twice is not an error"

out=$(ab sess-b done t2 2>&1) && rc=0 || rc=$?
assert_equal 1 "${rc:-0}" "somebody else's open task cannot be closed for them"
assert_contains "$out" "$A" "and the refusal says whose it is"

out=$(ab sess-b done 2>&1) && rc=0 || rc=$?
assert_equal 1 "${rc:-0}" "a bare done with two open is refused rather than guessed"
assert_contains "$out" "t3" "listing the first"
assert_contains "$out" "t4" "and the second, as commands to run"

ab sess-b done t3 > /dev/null
ab sess-b done t4 > /dev/null
out=$(ab sess-b done 2>&1) && rc=0 || rc=$?
assert_equal 1 "${rc:-0}" "and with nothing open it says so instead of inventing one"
assert_contains "$out" "agentbus take" "pointing at the verb that starts one"

# ---- a task whose session has gone ------------------------------------------
#
# The rule `sweep_locks` follows cannot be the rule here. A lock that grants
# nothing is deleted on sight, because the resource frees itself and a stale lock
# actively misleads. A task does not free itself: it is the only written record
# that some work was started, and the branch it was started on is still there —
# which is exactly what somebody merging two chats' work is looking for. So it is
# SHOWN as orphaned, which costs no write at all, and only ages out a day later.

new_session sess-c "$REPO"
C=$(ab sess-c name)
ab sess-c take "drop the legacy table" > /dev/null      # t5
ab sess-c take "renumber the fixtures" > /dev/null      # t6
assert_equal open "$(view 't("t5")["state"]')" "an open task reads as open"
end_session sess-c
assert_equal dropped "$(view 't("t5")["state"]')" \
  "and as dropped the moment its session is gone, with no sweep in between"
assert_equal open "$(led 't("t5")["state"]')" \
  "which is derived rather than written, so nothing on disk had to be corrected"
assert_equal False "$(view 't("t5")["owner_live"]')" "the owner is reported as gone"
assert_equal "$C" "$(led 't("t5")["agent"]')" "by the name it had"
assert_equal main "$(view 't("t5")["branch"]')" \
  "and the branch the work is sitting on is still named, which is the point of keeping it"

out=$(ab sess-b take t5)
assert_contains "$out" "t5 is yours" "somebody else can pick it up"
assert_contains "$out" "$C" "and is told whose it was"
assert_equal "$B" "$(led 't("t5")["agent"]')" "the ledger changes hands"
assert_equal "$C" "$(led 't("t5")["from"]')" "and remembers where it came from"
assert_equal open "$(view 't("t5")["state"]')" "it is open work again"
assert_equal dropped "$(view 't("t6")["state"]')" \
  "while the rest of that session's work stays where it was"

ab sess-a take "hold the api open" > /dev/null           # t7
out=$(ab sess-b take t7 2>&1) && rc=0 || rc=$?
assert_equal 1 "${rc:-0}" "a live agent's task cannot be taken off it"
assert_contains "$out" "still live" "because nobody can prove they have stopped"
assert_contains "$out" "agentbus post --to $A" "so the refusal says who to ask"

# ---- ids are per repository, and so is everything else ----------------------
#
# Scoped like a plain `post` and unlike `--all`: two chats merging into one trunk
# is the case this exists for, and a task graph spanning projects is not.

REPO2=$(make_repo storefront)
commit_all "$REPO2"
new_session sess-d "$REPO2"
D=$(ab sess-d name)
out=$(ab sess-d take "unrelated work in another project")
assert_contains "$out" "t1" "another repository starts its ids again at t1"
assert_equal 2 "$(led 'len(files)')" "each repository has a ledger of its own"
assert_not_contains "$(view 'json.dumps(v)')" "unrelated work" \
  "and one repository's tasks are not visible in another's"
out=$(ab sess-d take "blocked on the other project" --needs t7 2>&1) && rc=0 || rc=$?
assert_equal 1 "${rc:-0}" "a task in another project cannot be depended on"

# ---- what the others are told -----------------------------------------------
#
# A task line is a sentence an agent chose to write, which is the test for
# whether it is delivered. Lock churn is not delivered and should not be; this
# is, because the whole reason to write it is that another chat should not start
# the same work, or should learn that what it was waiting for has landed.

ab sess-a take "reseed the fixtures" > /dev/null
out=$(ab_hook prompt-submit "$(payload session sid=sess-b "cwd=$WT")")
assert_contains "$out" "reseed the fixtures" \
  "another session in the repository is told at its next turn"
out=$(ab_hook prompt-submit "$(payload session sid=sess-a "cwd=$REPO")")
assert_not_contains "$out" "reseed the fixtures" \
  "and the session that wrote it is not told its own news"
out=$(ab_hook prompt-submit "$(payload session sid=sess-d "cwd=$REPO2")")
assert_not_contains "$out" "reseed the fixtures" \
  "nor is a session in another project, which never asked"

# ---- a reader who is one of the agents --------------------------------------

# Only the ledger block. `status` also prints the tail of the event stream, which
# is machine-wide by design — asserting over the whole screen would have made the
# scope check below pass or fail on something else entirely.
out=$(ab sess-b status | sed -n '/have taken/,/^$/p')
assert_contains "$out" "have taken" "status says what the agents in this repo have taken"
assert_contains "$out" "drop the legacy table" "naming the work"
assert_contains "$out" "was $C" \
  "and marking the work whose chat ended, which is the branch somebody has to pick up"
assert_not_contains "$out" "unrelated work" "and nothing from another project"

# ---- ageing out -------------------------------------------------------------

age() {   # <task id> <seconds ago>
  python3 -c "
import glob, json, os, sys, time
for p in glob.glob(os.path.join('$AGENTBUS_HOME', 'tasks', '*.json')):
    d = json.load(open(p))
    hit = False
    for t in d['tasks']:
        if t['id'] == sys.argv[1]:
            t['at'] = int(time.time()) - int(sys.argv[2])
            if t.get('done_at'):
                t['done_at'] = t['at']
            hit = True
    if hit:
        json.dump(d, open(p, 'w'))" "$1" "$2"
}

# A task that landed half an hour ago is history: still in the ledger, so that
# somebody arriving tomorrow can find out what happened to a branch, and off the
# screen, so that the screen is about now.
age t1 3600
assert_equal False "$(view 't("t1")["fresh"]')" \
  "work that landed a while ago drops off the screen"
assert_equal 1 "$(led 'len([x for x in d["tasks"] if x["id"] == "t1"])')" \
  "while staying in the ledger, because tomorrow somebody asks what happened to that branch"

age t7 90000        # open, and its owner is still live
age t5 90000        # open, and so is this one, until sess-b ends below
ab sess-a status > /dev/null      # any engine run a person asked for sweeps
assert_equal 1 "$(led 'len([x for x in d["tasks"] if x["id"] == "t7"])')" \
  "long-running work whose owner is still there is not litter, however old"
assert_equal 1 "$(led 'len([x for x in d["tasks"] if x["id"] == "t5"])')" \
  "and neither is a day-old task somebody has picked up"
end_session sess-b
ab sess-a status > /dev/null
assert_equal 0 "$(led 'len([x for x in d["tasks"] if x["id"] == "t5"])')" \
  "but once that session has gone too, a day-old task is forgotten"
assert_equal 1 "$(led 'len([x for x in d["tasks"] if x["id"] == "t7"])')" \
  "and the sweep takes only what it was aimed at"

# ---- the board ---------------------------------------------------------------

snap() {   # <python expression over `d`, `t(id)`, `sess(name)`>
  python3 -c "
import importlib.machinery, importlib.util, json, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
d = ab.board_state()
def t(tid):
    return [x for x in d['tasks'] if x['id'] == tid][0]
def sess(name):
    return [s for s in d['sessions'] if s['agent'] == name][0]
print($1)"
}

new_session sess-e "$REPO"
E=$(ab sess-e name)
# Into a file another live session has written too, so the row this task sits
# under still carries the 2.4.0 collision the reader came for.
wrote sess-e "$REPO" api/token.py
# The id is read from what the verb answered rather than assumed: ids are handed
# out per repository in order, and a test that counts them itself is a test that
# breaks whenever the file above it takes one more task.
MINE=$(ab sess-e take "wire the ledger to the page" --needs t7 | head -1 | cut -d' ' -f1)
assert_contains "$(snap 'json.dumps([x["what"] for x in d["tasks"]])')" \
  "wire the ledger to the page" "the snapshot the page polls carries the tasks"
assert_equal "$E" "$(snap 't("'"$MINE"'")["agent"]')" "each with the agent that took it"
assert_equal True "$(snap 't("'"$MINE"'")["owner_live"]')" \
  "and whether its session is still there, which is what decides where the row goes"
assert_equal t7 "$(snap '" ".join(t("'"$MINE"'")["blocked_by"])')" \
  "the one thing a reader has to act on: work that cannot go on until other work lands"
assert_equal "$(session_field sess-e repo_key)" "$(snap 't("'"$MINE"'")["repo"]')" \
  "tagged with its repository, so the page's project filter reaches it"
assert_equal 2 "$(snap 'len(set(x["repo"] for x in d["tasks"]))')" \
  "with the other project's ledger read too, since somebody is still working there"
end_session sess-d
assert_equal 0 "$(snap 'len([x for x in d["tasks"] if x["repo"] != sess("'"$E"'")["repo"]])')" \
  "and dropped once nobody is, like every other row on this page — the ledger keeps it, the screen does not"

# Read-only, the first of this board's three invariants, extended to the ledger:
# it polls every couple of seconds for as long as a tab is open, and rendering a
# task must not reap, adopt or advance anything.
#
# There has to be something for a sweep to take, or this measures nothing — which
# is what the first version of it did: with no reapable task on the bus, a
# `sweep_tasks` planted inside `board_state` left the fingerprint identical and
# the assertion passed. The same trap `test_board.sh` avoids by planting a
# genuinely reapable session before asking whether the board reaps.
new_session sess-f "$REPO"
LOST=$(ab sess-f take "work that will be abandoned" | head -1 | cut -d' ' -f1)
end_session sess-f
age "$LOST" 90000
assert_equal 1 "$(led 'len([x for x in d["tasks"] if x["id"] == "'"$LOST"'"])')" \
  "a task any ordinary engine run would forget is planted"

ledger_print() {
  python3 -c "
import glob, hashlib, os
h = hashlib.sha1()
for p in sorted(glob.glob(os.path.join('$AGENTBUS_HOME', 'tasks', '*'))):
    st = os.stat(p)
    h.update(os.path.basename(p).encode())
    h.update(open(p, 'rb').read())
    h.update(str(st.st_mtime_ns).encode())
print(h.hexdigest())"
}
before=$(ledger_print)
snap 'len(d["tasks"])' > /dev/null
snap 'len(d["tasks"])' > /dev/null
assert_equal "$before" "$(ledger_print)" \
  "polling the board changes nothing in the ledger — not a state, not an mtime"
assert_equal 1 "$(led 'len([x for x in d["tasks"] if x["id"] == "'"$LOST"'"])')" \
  "so an abandoned task is left on disk rather than swept behind the user's back"
ab sess-e status > /dev/null
assert_equal 0 "$(led 'len([x for x in d["tasks"] if x["id"] == "'"$LOST"'"])')" \
  'which status, asked a question by a person, does do'

# A prerequisite that HAS landed. `needs` and `blocked_by` are the same list
# right up until the thing the work was built on is finished, and after that the
# difference between them is the only place anything can say what this work
# assumes — a page drawing `blocked_by` alone shows work that named a
# prerequisite as though it had named none.
DEP=$(ab sess-e take "add the fixture loader" | head -1 | cut -d' ' -f1)
ab sess-e done "$DEP" > /dev/null
BUILT=$(ab sess-e take "use the fixture loader" --needs "$DEP" | head -1 | cut -d' ' -f1)
assert_equal "$DEP" "$(snap '" ".join(t("'"$BUILT"'")["needs"])')" \
  "a task keeps the prerequisite it declared after that prerequisite lands"
assert_equal "" "$(snap '" ".join(t("'"$BUILT"'")["blocked_by"])')" \
  "and stops being blocked by it, which is what makes the two lists different"

# Work that changed hands. The agent on the row is whoever has it now, so the
# name of the chat that started it is the only way a reader can join what they
# are looking at to what they remember reading.
# In the other worktree on purpose: a session that joins the same repository on
# the same branch after the first one has gone is handed the same generated name,
# and "carried from" is deliberately blank when the name has not changed — so a
# fixture built in one checkout would have measured nothing at all.
new_session sess-h "$REPO"
H=$(ab sess-h name)
HANDED=$(ab sess-h take "move the seed data" | head -1 | cut -d' ' -f1)
end_session sess-h
new_session sess-i "$WT"
ab sess-i take "$HANDED" > /dev/null

# A checkout with nobody in it and something left on it. The page draws a strip
# of ground per checkout, and a checkout whose chat has closed is where the work
# somebody has to pick up is actually sitting — so the strip has to survive its
# last agent leaving rather than disappearing with it.
SPARE=$(make_worktree "$REPO" ledgerspare)
new_session sess-j "$SPARE"
ab sess-j take "split the migration" > /dev/null
end_session sess-j
assert_equal "$H" "$(snap 't("'"$HANDED"'")["from"]')" \
  "carried work remembers the agent it came from"

html=$(python3 -c "
import importlib.machinery, importlib.util, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
print(ab.BOARD_HTML)")
# A fact added to the snapshot and wired to nothing is a cost paid on every poll
# for a number no reader ever sees. These are the only cover on a host with no
# node, where the executing check below is skipped — and each names the exact
# call that draws the field rather than the field, because a field name appears
# in three or four places and a search for one of those cannot fail for the right
# reason. Tried: dropping the drawing line while leaving `shown(...)` and the
# header's own filter behind left a search for `t.blocked_by` perfectly green.
assert_contains "$html" "put(c.what, t.what" "the page draws what an agent said it was doing"
assert_contains "$html" '"blocked until " + t.blocked_by' \
  "and what it cannot get on without"
assert_contains "$html" "put(c.state, t.state)" \
  "and whether the work is open, done or dropped"
assert_contains "$html" 't.waiting.join(", ") + " waiting on this"' \
  "and who is waiting on it"
assert_contains "$html" '"holding " + t.holding' \
  "and what its owner holds, which nothing declared"

# ---- it is served, and the script it serves actually parses ------------------
#
# The one that got past every assertion in this suite last time: a page that
# returns 200 with a script that does not parse renders nothing at all, and no
# amount of asserting on JSON can see it. BOARD_HTML is Python source, so one
# unescaped backslash in a JavaScript string is enough.

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
  _bad "the board serves the page the ledger is drawn on" "$(cat "$TEST_TMP/board.out")"
else
  get() {   # <path> → "<status> <body>"
    python3 -c "
import sys, urllib.error, urllib.request
try:
    r = urllib.request.urlopen('$url' + sys.argv[1], timeout=10)
    print(r.status, r.read().decode('utf-8', 'replace'))
except urllib.error.HTTPError as e:
    print(e.code, '')" "$1"
  }
  body=$(get /data)
  assert_contains "$body" "200" "the data endpoint answers"
  assert_contains "$body" "wire the ledger to the page" "with the ledger in it"
  printf '%s' "$body" | sed '1s/^200 //' > "$TEST_TMP/data.json"

  get / | sed '1s/^200 //' > "$TEST_TMP/page.html"
  python3 -c "
import re, sys
h = open('$TEST_TMP/page.html').read()
m = re.search(r'<script>(.*?)</script>', h, re.S)
open('$TEST_TMP/board.js', 'w').write(m.group(1) if m else '')
sys.exit(0 if m else 1)" \
    && _ok "the served page carries a script" \
    || _bad "the served page carries a script" "no <script> in the served HTML"

  if command -v node > /dev/null 2>&1; then
    if out=$(node --check "$TEST_TMP/board.js" 2>&1); then
      _ok "and it parses as JavaScript, so the page renders rather than 200-ing empty"
    else
      _bad "and it parses as JavaScript, so the page renders rather than 200-ing empty" "$out"
    fi
    # And then it is RUN, against the data the server just served, in the
    # smallest DOM the page's reconciler actually uses. Everything above this is
    # a search of the source, and a search cannot tell a field that is drawn from
    # a field that is merely mentioned — a `fillTask` whose body never executes
    # still contains every name a grep would look for. Proved: a mutation that
    # made that function return immediately left every one of those assertions
    # green.
    if out=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/board.js" \
                  "$TEST_TMP/data.json" 2>&1); then
      _ok "the page renders when it is actually run"
      rows=$(printf '%s\n' "$out" | grep '^AGENTS \[task' || true)
      assert_contains "$rows" "wire the ledger to the page" \
        "drawing a row for what an agent said it was doing"
      assert_contains "$rows" "blocked until t7 lands" \
        "and, on that row, what it cannot get on without"
      assert_contains "$rows" "dropped" \
        "and marking work whose session has gone, which sits under no session at all"
      assert_contains "$rows" "waiting on this" \
        "and telling the agent in the way that somebody is behind it"
      assert_contains "$rows" "holding db" \
        "and what its owner holds, which came from the locks and not from the ledger"
      # Beside, not instead of: the session's own row keeps everything 2.4.0
      # gave it, so a session that has declared nothing loses nothing.
      sess_rows=$(printf '%s\n' "$out" | grep '^AGENTS \[\]' || true)
      assert_contains "$sess_rows" "files written" \
        "beside a session row that still shows the files it has written"
      assert_contains "$sess_rows" "also" \
        "and the ones another session in the same repository has written too"
      assert_contains "$(printf '%s\n' "$out" | grep '^HEADER')" "open" \
        "with the header counting the work that is open"
      assert_contains "$rows" "built on $DEP, landed" \
        "and, beside what a task is still waiting for, what it was built on that has landed"
      # Where work went when its chat closed. The branch is half the answer; the
      # other half is the checkout it was taken in, which is the only thing that
      # says where to go and look.
      gone=$(printf '%s\n' "$out" | grep '^AGENTS \[task gone' || true)
      assert_contains "$gone" "was $C" \
        "naming the agent whose chat has gone, on work nobody is holding"
      assert_contains "$gone" "$WT" "and the checkout that work was taken in"
      assert_contains "$rows" "carried from $H" \
        "and, on work that changed hands, the agent it was carried from"
      # The strip for a checkout nobody is standing in. Counted, not searched:
      # the band's text contains the abandoned work either way, and only the
      # absence of a character row says the ground is empty.
      spare=$(printf '%s\n' "$out" | awk -v p="$SPARE" '
        /^AGENTS \[band/ { on = index($0, p) > 0 }
        on { print }
        /^AGENTS \[prj/ { on = 0 }')
      assert_contains "$spare" "split the migration" \
        "a checkout nobody is standing in keeps its strip, with the work left on it"
      assert_equal 0 "$(printf '%s\n' "$spare" | grep -c '^AGENTS \[\] ' || true)" \
        "and nothing standing on that ground, which is the fact it is drawn for"
    else
      _bad "the page renders when it is actually run" "$out"
    fi
  else
    _ok "and it parses as JavaScript (skipped: no node on this host)"
    _ok "the page renders when it is actually run (skipped: no node on this host)"
  fi
fi

kill $BOARD_PID 2>/dev/null
trap - EXIT

finish
