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

finish
