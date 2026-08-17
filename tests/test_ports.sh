#!/usr/bin/env bash
# Per-worktree ports: stop contending for one, and give each checkout its own.
#
# The bus was built to coordinate a shared service, and it does. But on the
# machine it was written for, 119 of 141 blocks it ever issued were the same
# sentence — "that service is serving a different checkout" — for three
# resources that could simply have been three services. Counted another way:
# 87 per cent of every refusal, and all 107 handovers, existed because two
# worktrees were sharing a port they did not have to share.
#
# A resource opts in with `"ports": "per-worktree"`. The number comes from the
# checkout's path, so it is the same every time with no state to lose, and the
# repository's ORIGINAL checkout keeps the port the config declares — which is
# what makes this additive: nothing changes for whoever works in the main clone,
# or for the README that says :8082.
#
# Isolation removes contention and introduces exactly one new way to be wrong,
# which is why this file is longer than the feature: an agent reaches for
# `localhost:8082` out of habit and quietly exercises another checkout's code.
# That is the founding failure of this plugin arriving through the back door.

. "$AB_ROOT/tests/lib.sh"

# A port nothing on this machine is using. The first version of this fixture
# used 8082 and was denied by `serving_check`, because a real dev API was
# listening on this Mac — a fixture colliding with the world it is modelling.
DECLARED=$(free_port)

REPO=$(make_repo portrepo)
python3 - "$REPO/.claude/agent-bus.json" "$DECLARED" <<'PY'
import json, os, sys
path, port = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"resources": [
    {"name": "api", "desc": "the dev API", "port": port,
     "ports": "per-worktree", "env": "API_PORT",
     "start": "python3 -m http.server ${PORT} --bind 127.0.0.1",
     "ready": "curl -sf localhost:${PORT}/",
     "patterns": [r"\buvicorn\b", r":%d\b" % port]},
    {"name": "db", "desc": "the shared database", "patterns": [r"\bpsql\b"]},
]}, open(path, "w"), indent=2)
PY
commit_all "$REPO"
WT1=$(make_worktree "$REPO" portwt1)
WT2=$(make_worktree "$REPO" portwt2)

new_session sess-main "$REPO"
new_session sess-w1 "$WT1"
new_session sess-w2 "$WT2"

at() {   # <dir> <session> <args…> → run the CLI from that directory
  local dir="$1" sid="$2"; shift 2
  ( cd "$dir" && AGENTBUS_SESSION="$sid" "$AB_ROOT/bin/agentbus" "$@" )
}

# ---- the original checkout keeps what the config declares -------------------
#
# Additive on purpose: the human working in the main clone, and every script and
# bookmark that names the declared port, carry on unchanged. Only the worktrees
# agents create get allocated ones.

MAIN_PORT=$(at "$REPO" sess-main port api)
assert_equal "$DECLARED" "$MAIN_PORT" "the original checkout keeps the declared port"

P1=$(at "$WT1" sess-w1 port api)
P2=$(at "$WT2" sess-w2 port api)
assert_not_contains "$P1" "$DECLARED" "a linked worktree gets one of its own"
assert_not_contains "$P2" "$P1" "and two worktrees do not get the same one"

# Derived from the path, so it survives anything: no registry, no bus, no reboot.
assert_equal "$P1" "$(at "$WT1" sess-w1 port api)" "the same checkout always gets the same port"
rm -f "$AGENTBUS_HOME/ports.json"
assert_equal "$P1" "$(at "$WT1" sess-w1 port api)" \
  "and gets it back even with the registry deleted"

# ---- the port reaches everything that uses one ------------------------------
#
# Every other part of the plugin reads res["port"]. Materialising the allocation
# in repo_config is what makes that true, and it is the whole of the feature —
# `serve`, `serving`, the readiness probe and the guard's own patterns all
# follow without knowing anything about allocation.

cfg_field() {   # <root> <field> → that field of the api resource, as this checkout sees it
  python3 -c "
import importlib.machinery, importlib.util, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
_, key, _, _ = ab.git_facts('$1')
res = [r for r in ab.repo_config(key, '$1')['resources'] if r['name'] == 'api'][0]
print(res.get('$2'))"
}

assert_contains "$(cfg_field "$WT1" start)" "$P1" \
  "\${PORT} in the start command becomes this checkout's port"
assert_contains "$(cfg_field "$WT1" ready)" "$P1" "and so does the readiness probe"
assert_contains "$(cfg_field "$WT1" patterns)" "$P1" \
  "a pattern for the new port is added, or a command aimed at it matches nothing"
assert_equal "worktree" "$(cfg_field "$WT1" scope)" \
  "and the lock becomes per checkout, because the thing is no longer shared"

# ---- what `agentbus env` hands to a shell -----------------------------------

out=$(at "$WT1" sess-w1 env)
assert_contains "$out" "export API_PORT=$P1" "env exports the name the config asked for"
assert_contains "$out" "this checkout's own" "and says which are allocated"
out=$(at "$REPO" sess-main env)
assert_contains "$out" "export API_PORT=$DECLARED" "the main checkout exports the declared one"

# ---- and to every process agent-bus starts or wraps -------------------------
#
# `env` answers a shell that thought to ask. The process that most needs the
# answer never gets a shell: a mobile bundler bakes the API's base URL into the
# bundle from a `.env` naming the original checkout's port, so giving a worktree
# its own API changes nothing — the app calls the other tree, the screen looks
# right, and the result belongs to somebody else's code. No guard can catch it,
# because the request leaves a simulator and not the shell being watched.
#
# So the number is put where the bundler already looks: its environment, under
# the same names `agentbus env` prints. Raised as an open gap by the session
# that wrote the per-worktree config on 2026-08-02 and left open long enough to
# be measured — 16 runs past the wrong-port guard with `AGENTBUS_OFF`, 30 of
# those mentions naming the original checkout's port.

ENVREPO=$(make_repo portenv)
EDECL=$(free_port)
python3 - "$ENVREPO/.claude/agent-bus.json" "$EDECL" "$TEST_TMP/baked.txt" <<'PY'
import json, os, sys
path, port, baked = sys.argv[1], int(sys.argv[2]), sys.argv[3]
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"resources": [
    {"name": "api", "desc": "the dev API", "port": port, "ports": "per-worktree",
     "start": "python3 -m http.server ${PORT} --bind 127.0.0.1",
     "ready": "curl -sf localhost:${PORT}/",
     "patterns": [r":%d\b" % port]},
    # What a bundler's start line looks like once it stops naming a number: the
    # API it points the app at is read, not written down. No port of its own —
    # the whole question is whether it can see somebody else's.
    {"name": "bundler", "desc": "bakes the API's address into a bundle",
     "start": "sh -c 'printf %%s \"$AGENTBUS_PORT_API\" > \"%s\"; sleep 30'"
              % baked,
     "patterns": [r"\bbundler\b"]},
    {"name": "db", "desc": "the shared database", "patterns": [r"\bpsql\b"]},
]}, open(path, "w"), indent=2)
PY
commit_all "$ENVREPO"
EWT=$(make_worktree "$ENVREPO" portenvwt)
new_session sess-env "$EWT"
EPORT=$(at "$EWT" sess-env port api)
assert_not_contains "$EPORT" "$EDECL" "the fixture worktree really did get its own port"

# A command under `run` sees them — and sees the ports of resources it did not
# ask for, because `db` is what it took and the API's address is what it needs.
got=$(at "$EWT" sess-env run db -- sh -c 'printf %s "$AGENTBUS_PORT_API"')
assert_equal "$EPORT" "$got" \
  "a command under \`run\` is given this checkout's ports, not just its own lock"

# And a service agent-bus starts, which is the case that closes the gap: nothing
# ran a shell here, nobody typed a number, and the bundler still knows.
rm -f "$TEST_TMP/baked.txt"
out=$(at "$EWT" sess-env serve bundler 2>&1)
assert_contains "$out" "restarted from your worktree" "the bundler starts"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$TEST_TMP/baked.txt" ] && break
  sleep 0.3
done
assert_equal "$EPORT" "$(cat "$TEST_TMP/baked.txt" 2>/dev/null)" \
  "and what it baked in is this worktree's API, which no .env could have told it"

# ---- and the number is handed over before the first command ------------------
#
# `env` answers when asked, and the guard below answers when the wrong port is
# typed. Neither of those is early enough. On the live bus a subagent in a
# worktree called the declared port 28 times with AGENTBUS_OFF in front of every
# one, because the config said that number and nothing had said otherwise — so
# the block was doing its job and being paid to go away. A block is the wrong
# place to first learn your own address; by then the command exists and the
# cheapest way past a refusal is a bypass.

brief() {   # <sid> <cwd> → the whole text injected at that session's start
  json_field "$(ab_hook session-start "$(payload session "sid=$1" "cwd=$2")")" \
    hookSpecificOutput additionalContext
}

out=$(brief sess-w1 "$WT1")
assert_contains "$out" "api is on :$P1 here" \
  "a session opening in a worktree is told its own port, unasked"
assert_contains "$out" "the :$DECLARED in the config is the original checkout's" \
  "and told that the number in the config belongs to somebody else"
assert_contains "$out" 'eval "$(agentbus env)"' \
  "and told the one command that hands over the whole set"

# Nothing to say to the original checkout: its port IS the declared one, and a
# line saying so would be paid for by every session that opens there.
assert_not_contains "$(brief sess-main "$REPO")" "Your own ports" \
  "while the original checkout is told nothing about ports at all"

# ---- the one new way to be wrong, and the guard for it ----------------------
#
# Isolation removes contention. It cannot stop an agent typing the port it read
# in a README, and that is the original silent failure: a green result for
# somebody else's tree. Nothing else in this plugin would catch it, because with
# per-worktree ports there is no lock to contend for and no service serving the
# wrong checkout — everything is behaving exactly as designed.

out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=curl -sf localhost:$P1/health" id=pt-1)")
assert_allow "$out" "a command aimed at this checkout's own port is fine"
ab_hook post-bash "$(payload post-bash sid=sess-w1 "cwd=$WT1" id=pt-1)" > /dev/null

out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=curl -sf localhost:$DECLARED/health" id=pt-2)")
assert_deny "$out" "reaching for the declared port out of habit is refused"
reason=$(json_field "$out" hookSpecificOutput permissionDecisionReason)
assert_contains "$reason" "original checkout" "and told whose it is"
assert_contains "$reason" "$P1" "and told which port is theirs"
assert_contains "$reason" "agentbus env" "and how to get it"

# The port that catches this one is not in this checkout's patterns at all —
# each worktree's patterns name only its own — so the check cannot depend on a
# pattern having matched. That is why it runs before `resources_for`.
out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=curl -sf localhost:$P2/health" id=pt-3)")
assert_deny "$out" "and so is reaching for another worktree's allocated port"
assert_contains "$(json_field "$out" hookSpecificOutput permissionDecisionReason)" \
  "portwt2" "which names the checkout it belongs to"

out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=curl -sf localhost:3000/health" id=pt-4)")
assert_allow "$out" "a port this machine has not allocated is nobody's business"

out=$(ab_hook pre-tool "$(payload bash sid=sess-main "cwd=$REPO" \
  "cmd=curl -sf localhost:$DECLARED/health" id=pt-5)")
assert_allow "$out" "and the original checkout is not refused its own port"
ab_hook post-bash "$(payload post-bash sid=sess-main "cwd=$REPO" id=pt-5)" > /dev/null

# What a session is shown on its next turn. Drained before the override below, so
# that every count after it is about the override and nothing else.
inbox() {   # <sid> <cwd> → the text injected into that session's context
  json_field "$(ab_hook prompt-submit \
    "$(payload session "sid=$1" "cwd=$2")")" hookSpecificOutput additionalContext
}
msgs() {   # <inbox text> → how many messages it carried
  printf '%s\n' "$1" | grep -c '^  - ' || true
}
astray() {   # <python expression over `recs`> → over the wrong-port events, oldest first
  python3 -c "
import json
recs = [json.loads(l) for l in open('$AGENTBUS_HOME/events.jsonl')]
recs = [r for r in recs if r.get('kind') == 'wrong-port']
print($1)"
}
inbox sess-main "$REPO" > /dev/null
inbox sess-w2 "$WT2" > /dev/null

# The override still works, because sometimes another checkout's port is exactly
# what you mean — and taking it leaves a trace, as it does everywhere else.
out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 curl -sf localhost:$DECLARED/health" id=pt-6)")
assert_allow "$out" "saying you mean it gets you through"

# ---- but this trace is one somebody reads ------------------------------------
#
# `AGENTBUS_OFF` in front of a lock is a legitimate escape — "I accept the
# contention risk", "this `psql` is aimed at a staging box in another country" —
# and it is left exactly as it was, below. In front of the wrong-port check there
# is no such case: this checkout's own port exists, and an answer from another
# one is not about this tree however the config is written.
#
# So the consequence decides the audience. It does not land on the party that
# switched the guard off — it lands on the checkout whose service now has another
# tree's requests in it, and on whoever later reads a conclusion measured against
# code its author was not looking at. Told only to the bypasser, it is told to the
# one party the news is not for; on the live bus this happened 28 times in a day
# while the log filled up and nobody's context did.

told=$(inbox sess-main "$REPO")
assert_contains "$told" "went past the wrong-port guard on :$DECLARED" \
  "a wrong-port bypass reaches the checkout whose port it took"
assert_equal 1 "$(msgs "$told")" "as one message"
assert_contains "$told" ":$DECLARED belongs to : the repository's original checkout" \
  "saying which port it was and whose checkout that port serves"
assert_contains "$told" "theirs is     : $P1" \
  "and which port the checkout it ran in has of its own"
assert_contains "$told" "being reported as theirs" \
  "and that the answer is being reported as the bypasser's own"
assert_contains "$told" 'Skipped: eval "$(agentbus env)"' \
  "and names the one command that was skipped"
assert_contains "$(inbox sess-w2 "$WT2")" "went past the wrong-port guard" \
  "and the rest of the repository is told, because reading the conclusion is enough"

# The same sentence the block would have printed, not a second copy of it. Asserted
# against the block's own text and character for character: the two are one
# function, and a rewrite of either that leaves them saying different things about
# the same command fails here.
fact=$(printf '%s\n' "$reason" | grep "belongs to :")
assert_contains "$told" "${fact# }" \
  "and it is the block's own line about the port, not a second copy of it"

# ---- and a run of them costs its readers one message -------------------------
#
# The hard half. 28 identical bypasses in 24 hours is what was measured, and 28
# identical sentences in everybody's context is precisely the noise 2.3.0 removed
# — 76 of 88 bypass announcements about nothing, hiding the twelve that were not.
# Making this one loud must not undo that. So the first speaks and the rest are
# counted: per party and per port, and deliberately not per command, because the
# 28 were 25 `curl`s and 6 readiness loops around the same wrong number.

mark=$(read_seq)
i=1
while [ "$i" -lt 28 ]; do
  i=$((i + 1))
  ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
    "cmd=AGENTBUS_OFF=1 curl -sf localhost:$DECLARED/health" id="pt-6-$i")" > /dev/null
done
assert_equal 27 "$(( $(read_seq) - mark ))" \
  "the twenty-seven behind the first are all recorded"
assert_equal 0 "$(msgs "$(inbox sess-main "$REPO")")" \
  "and not one of them is delivered: the run cost its reader one message"
assert_equal 0 "$(msgs "$(inbox sess-w2 "$WT2")")" "nor anybody else"
assert_equal 28 "$(astray 'len(recs)')" "all 28 are in the log, where a watcher wants them"
assert_equal 0 "$(astray "recs[0].get('again', 0)")" \
  "the one that spoke is not marked as a repeat"
assert_equal 28 "$(astray "recs[-1]['again']")" \
  "and the last says it is the twenty-eighth, not the twenty-seventh nobody saw"

# A run is bounded; a NEW one is not quieted by it. Another worktree's allocated
# port is also the case that used to leave nothing behind at all: it matches no
# pattern in this checkout, so it was not in `overrode` either and the ordinary
# bypass line never fired.
out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 curl -sf localhost:$P2/health" id=pt-6-new)")
assert_allow "$out" "a bypass aimed at another worktree's allocated port still runs"
assert_contains "$(astray "recs[-1]['text']")" ":$P2" \
  "and is recorded, where before it left nothing at all — not even a line"
told=$(inbox sess-main "$REPO")
assert_equal 1 "$(msgs "$told")" "a port nobody has been warned about is loud again"
assert_contains "$told" "portwt2" "naming the checkout that one belongs to"
assert_equal 1 "$(msgs "$(inbox sess-w2 "$WT2")")" \
  "and the checkout that port does belong to hears it once as well"

# ---- a run that does not stop is not swallowed for ever ----------------------
#
# Bounded is not the same as silenced. A party that goes on doing this all day
# would be mentioned once and then never again, which is how the failure this
# whole change is about stayed quiet in the first place — so the window is how
# long one announcement stands for, not for ever. Driven by ageing the record on
# disk, the way the sweeps are tested: the alternative is a test that sleeps for
# six hours.
age_astray() {   # <port, or "" for every pair> <age of `at`> <age of `last`>
  python3 -c "
import json, sys, time
path = '$AGENTBUS_HOME/astray.json'
reg = json.load(open(path))
want = sys.argv[1]
for v in reg.values():
    if want and str(v.get('port')) != want:
        continue
    v['at'] = int(time.time()) - int(sys.argv[2])
    v['last'] = int(time.time()) - int(sys.argv[3])
json.dump(reg, open(path, 'w'))" "$1" "$2" "$3"
}

# Still going: the last one was a moment ago, the announcement was six hours ago.
age_astray "$DECLARED" 21660 0
ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 curl -sf localhost:$DECLARED/health" id=pt-6-again)" > /dev/null
told=$(inbox sess-main "$REPO")
assert_equal 1 "$(msgs "$told")" "a run still going is spoken about again when the window is up"
assert_contains "$told" "And 27 more of these since" \
  "and the second one says how many it has been standing for"

# Stopped: two more went by since that second announcement, and then nothing for a
# whole window. What comes back is a first one — loud, and not carrying a count
# from a run that ended, because the agent doing it now is not the one that was
# told six hours ago.
ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 curl -sf localhost:$DECLARED/health" id=pt-6-q1)" > /dev/null
ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 curl -sf localhost:$DECLARED/health" id=pt-6-q2)" > /dev/null
age_astray "" 21660 21660
ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 curl -sf localhost:$DECLARED/health" id=pt-6-fresh)" > /dev/null
told=$(inbox sess-main "$REPO")
assert_contains "$told" "went past the wrong-port guard on :$DECLARED" \
  "a run that stopped for a whole window comes back loud"
assert_not_contains "$told" "more of these since" \
  "and as a first one, not carrying the tail of a run that ended"

# And the register does not grow for ever: a pair older than the window changes no
# decision, so it is not kept. Every pair above was just aged past it; only the one
# that came back is still there.
assert_equal 1 "$(python3 -c "
import json
print(len(json.load(open('$AGENTBUS_HOME/astray.json'))))")" \
  "and a pair nobody has been past for a window is dropped rather than kept"
inbox sess-w2 "$WT2" > /dev/null

# ---- and the ordinary lock bypass is untouched -------------------------------
#
# Same words, same one line, still delivered to nobody. This is the escape that
# has a case for it — "I accept the contention risk" — so it is stepped over
# against a lock somebody is really holding, which is the only version of it that
# would notice the override being taken away.
ab sess-w2 claim db --why "seeding the database" > /dev/null
mark=$(read_seq)
out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 psql -c 'select 3'" id=pt-6-lock)")
assert_allow "$out" "an ordinary lock bypass still gets through a lock somebody holds"
assert_equal 1 "$(( $(read_seq) - mark ))" "and still puts exactly one line on the bus"
assert_equal "ran past the guard on 'db' with AGENTBUS_OFF" \
  "$(python3 -c "
import json
recs = [json.loads(l) for l in open('$AGENTBUS_HOME/events.jsonl')]
print(recs[-1]['text'].split(' — ')[0])")" \
  "in the words it has always used"
assert_equal 0 "$(msgs "$(inbox sess-w2 "$WT2")")" \
  "and reaching nobody's context, exactly as before"
ab sess-w2 release db > /dev/null

# ---- distinguishable on the board -------------------------------------------
#
# The feed already carried these as one more line in the colour of a block. A
# guard that was switched off is not the same object as a guard that held, and a
# run of 28 whose rows are identical is 27 rows that each look like the first.
# Run, not searched for: the class has to be the one the page puts on the row and
# the one the stylesheet has a rule for, and a search of the source cannot tell a
# class that is applied from a class that is mentioned.

python3 -c "
import importlib.machinery, importlib.util, json, os, re
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
html = ab.BOARD_HTML.replace('__INTERVAL__', '2000')
open('$TEST_TMP/page.html', 'w').write(html)
open('$TEST_TMP/board.js', 'w').write(
    re.search(r'<script>(.*?)</script>', html, re.S).group(1))
json.dump(ab.board_state(), open('$TEST_TMP/data.json', 'w'))"

if ! command -v node > /dev/null 2>&1; then
  _ok "the feed marks a wrong-port bypass as its own kind of row (skipped: no node)"
  _ok "and says which one of a run each repeat is (skipped: no node)"
  _ok "and the class it draws is the class the stylesheet paints (skipped: no node)"
else
  drawn=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/board.js" \
               "$TEST_TMP/data.json" 2>&1 | grep '^FEED ' || true)
  assert_contains "$drawn" "k-wrong-port" \
    "the feed marks a wrong-port bypass as its own kind of row"
  assert_contains "$drawn" "wrong-port ×28" \
    "and says which one of a run each repeat is"
  # Both names read out of the page and compared, so this cannot be satisfied by
  # naming either of them here: rename the class in one and the other is orphaned.
  cls=$(printf '%s\n' "$drawn" | sed -n 's/^FEED \[ev \([^]]*\)\].*/\1/p' \
        | grep wrong-port | head -1)
  assert_contains "$(cat "$TEST_TMP/page.html")" ".$cls{" \
    "and the class it draws is the class the stylesheet paints"
fi

# ---- resources that did not opt in are untouched ----------------------------

out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=psql -c 'select 1'" id=pt-7)")
assert_allow "$out" "a resource without per-worktree ports still behaves as before"
assert_equal 1 "$(locks_held)" "and is still locked machine-wide"
out=$(ab_hook pre-tool "$(payload bash sid=sess-w2 "cwd=$WT2" \
  "cmd=psql -c 'select 2'" id=pt-8)")
assert_deny "$out" "so two worktrees still contend for it — which is the point"
ab_hook post-bash "$(payload post-bash sid=sess-w1 "cwd=$WT1" id=pt-7)" > /dev/null

finish
