#!/usr/bin/env bash
# The two spines, characterised: what a command touches, and what a block says
# you can do about it.
#
# Nothing here is a new feature and nothing here is refactored. This file exists
# because a refactor that claims to preserve behaviour is worthless without
# tests that fail when behaviour moves, and because this repository has four
# times shipped a green assertion that measured the wrong thing.
#
# Two checks:
#
#   A. Every verb locks what the guard locks, FOR THE SAME COMMAND. Stated that
#      way — per command, not "the CLI and the guard agree about a resource
#      name" — because for an instance-keyed resource the guard has a command
#      and the command-line tool has not. Asserted on the lock files actually on
#      disk, never on printed text: `agentbus claim worktree` printed "claimed"
#      for weeks while writing a lock nothing consulted.
#
#   B. Every exit a block advertises lifts that block. "The guard allows the
#      exit" is NOT the property that matters — `agentbus claim worktree` was
#      allowed by the guard perfectly while doing nothing. Each exit is run and
#      then the refused command is re-run, and the question asked of it is
#      whether it is now allowed.
#
# Where today's answer is no, the failure is pinned rather than fixed, with a
# name that says so. M0 characterises; M1 changes, one commit per decision.
#
# File blocks (`guard_file`) are deliberately out of scope for check B:
# `resources_for` returns nothing for a `file:` path, so there is no resource,
# no lock name and no exit set to test — the property is vacuous there. The
# advice those blocks print is hand-written English and stays that way until
# after M3, which covers the command surface only.

. "$AB_ROOT/tests/lib.sh"

trap stop_services EXIT

# ------------------------------------------------- helpers lib.sh lacks ------
#
# Deliberately local. `tests/lib.sh` is shared, and nothing here has earned a
# place in it yet — but `assert_differ` and `lock_keys` are the two that would.

# lib.sh has "these must be equal" and nothing for the opposite. Needed here
# only to pin divergences: both uses below are assertions that two answers are
# NOT the same, on purpose.
assert_differ() {   # <a> <b> <label>
  if [ "$1" != "$2" ]; then
    _ok "$3"
  else
    _bad "$3" "both are [$1]; this assertion exists because they must differ"
  fi
}

# The name every lock on the bus is filed under — `lock_name(me, res, cmd)`'s
# answer, read back off disk rather than from anything the engine printed.
#
# A script as well as a shell function because `agentbus run` has to be asked
# from inside the command it is running: it gives its locks back the moment it
# exits, so there is no "after" in which to look.
LOCKDUMP="$TEST_TMP/lock-keys.sh"
cat > "$LOCKDUMP" <<'SH'
#!/usr/bin/env bash
python3 -c '
import glob, json, os
names = []
for path in glob.glob(os.path.join(os.environ["AGENTBUS_HOME"], "locks", "*.json")):
    try:
        names.append(json.load(open(path)).get("resource", ""))
    except Exception:
        pass
print(" ".join(sorted(names)))'
SH
chmod +x "$LOCKDUMP"

lock_keys() { "$LOCKDUMP"; }

# What `lock_name` appends for a `scope: "worktree"` resource, worked out here
# rather than asked of the engine — a characterisation test that computed the
# expected value with the code under test would assert nothing at all.
worktree_key() {   # <resource> <root> → name@digest
  python3 -c "
import hashlib, os, sys
print('%s@%s' % (sys.argv[1],
      hashlib.sha1(os.path.realpath(sys.argv[2]).encode()).hexdigest()[:6]))" "$1" "$2"
}

# Feed the guard one Bash command and keep the whole answer for the assertions
# that follow. An allowed command is handed straight back through PostToolUse:
# a retry that left a lock behind would change what the next scenario starts
# from, and every use of this below is either provoking a block or retrying one.
GUARD_OUT="$TEST_TMP/guard.json"
guard() {   # <tool use id> <session> <cwd> <command> [<agent id>]
  local id="$1" sid="$2" cwd="$3" cmd="$4" aid="${5:-}" extra=""
  [ -n "$aid" ] && extra="agent_id=$aid agent_type=general-purpose"
  ab_hook pre-tool \
    "$(payload bash "sid=$sid" "cwd=$cwd" "cmd=$cmd" "id=$id" $extra)" > "$GUARD_OUT"
  VERDICT=$(json_field "$(cat "$GUARD_OUT")" hookSpecificOutput permissionDecision)
  REASON=$(json_field "$(cat "$GUARD_OUT")" hookSpecificOutput permissionDecisionReason)
  if [ "$VERDICT" = "deny" ]; then
    return 0
  fi
  VERDICT=allow
  ab_hook post-bash \
    "$(payload post-bash "sid=$sid" "cwd=$cwd" "id=$id" $extra)" > /dev/null
}

# An exit is run the way a session runs one: the guard sees the line first — it
# has to, or the way out of a block is itself blocked, which is a defect this
# repository has shipped twice — and the command-line tool runs it second.
#
# Seeing it first is also load-bearing for `agentbus wait`: the hook is the only
# place that knows which subagent is typing, and it leaves a hint keyed on the
# exact tokens. An exit typed differently from the advertised line picks up no
# hint, which is a difference this file measures rather than avoids.
exit_seen_by_guard() {   # <tool use id> <session> <cwd> <line> [<agent id>]
  guard "$1" "$2" "$3" "$4" "${5:-}"
  assert_equal allow "$VERDICT" "the guard lets \`$4\` through while it is blocking"
}

run_exit() {   # <session> <the advertised line, verbatim> → what the tool printed
  local sid="$1" line="$2"
  eval "AGENTBUS_SESSION='$sid' '$AB_ROOT/bin/agentbus' ${line#agentbus }" 2>&1
}

take_exit() {   # <tool use id> <session> <cwd> <line> [<agent id>] → the output
  exit_seen_by_guard "$1" "$2" "$3" "$4" "${5:-}"
  run_exit "$2" "$4"
}

# `agentbus wait` blocks, and the advertised line carries no `--timeout` — which
# is the point of running it verbatim. So the bound lives here instead: a wait
# that has not come back is a failure to report, not a test that hangs for the
# ninety seconds the tool defaults to.
start_exit() {   # <session> <line> <output file>
  run_exit "$1" "$2" > "$3" 2>&1 &
  EXIT_PID=$!
}

finish_exit() {   # <seconds to allow>
  local n=0
  while kill -0 "$EXIT_PID" 2>/dev/null && [ "$n" -lt "$1" ]; do
    sleep 1
    n=$((n + 1))
  done
  if kill -0 "$EXIT_PID" 2>/dev/null; then
    kill -TERM "$EXIT_PID" 2>/dev/null
    _bad "the advertised wait comes back" "still running after $1 seconds"
  fi
  wait "$EXIT_PID" 2>/dev/null
}

# ------------------------------------------------------------ the fixture ----
#
# One repository declaring all four shapes a resource can have — plain, per
# checkout, per instance, and one that implies another — plus a service with a
# `start`, and one resource with per-worktree ports. Check A needs the first
# four; check B needs the last two to provoke the blocks that are not about
# locks at all.

DECLARED=$(free_port)
REPO=$(make_repo parityrepo)
python3 - "$REPO/.claude/agent-bus.json" "$DECLARED" <<'PY'
import json, os, sys
path, port = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"resources": [
    {"name": "db", "desc": "the shared development database",
     "why": "One database for every worktree.",
     "patterns": [r"\bpsql\b"]},
    {"name": "worktree", "desc": "this checkout's tree and index",
     "scope": "worktree",
     "patterns": [r"\bgit\s+add\b"]},
    {"name": "simulator", "desc": "an iOS simulator",
     "why": "One device, several of you.",
     "key": r"--udid\s+(\S+)",
     "patterns": [r"\bmaestro\b"]},
    {"name": "bundler", "desc": "the bundler",
     "patterns": [r"\bmetro\b"]},
    {"name": "rig", "desc": "the whole rig", "implies": ["bundler"],
     "patterns": [r"\brigrun\b"]},
    # No port: `serving` answers from the record alone for a portless service,
    # so the "this is serving another checkout" block can be provoked on a host
    # with neither lsof nor netstat.
    {"name": "web", "desc": "the demo service",
     "why": "It serves the tree it was started in.",
     "start": "sleep 300",
     "patterns": [r"\bwebcurl\b"]},
    {"name": "api", "desc": "the dev API", "port": port, "ports": "per-worktree",
     "env": "API_PORT",
     "patterns": [r"\buvicorn\b", r":%d\b" % port]},
]}, open(path, "w"), indent=2)
PY
commit_all "$REPO"
WT=$(make_worktree "$REPO" paritywt)

new_session sess-a "$REPO"
new_session sess-b "$WT"
A=$(ab sess-a name)
B=$(ab sess-b name)
assert_equal 2 "$(cat "$AGENTBUS_HOME/live-count")" "two sessions are live"

PSQL="psql -c 'select 1'"
WT_KEY=$(worktree_key worktree "$REPO")


# =============================================================================
# Check A — every verb locks what the guard locks, for the same command
# =============================================================================

# ---- a plain resource: one name, and both sides use it ----------------------

ab sess-a claim db --why "seeding" > /dev/null
assert_equal "db" "$(lock_keys)" "\`claim db\` writes the lock named db"
ab sess-a release db > /dev/null
assert_equal "" "$(lock_keys)" "and \`release db\` gives back that same key"

ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$PSQL" id=a-db)" > /dev/null
assert_equal "db" "$(lock_keys)" "a guarded psql writes the same one"
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=a-db)" > /dev/null

# ---- a per-checkout resource: the key both sides have to agree on -----------
#
# The one that was actually wrong. Every CLI verb used the bare name while the
# guard filed it under `<name>@<digest of the root>`, so the two never met.

ab sess-a claim worktree --why "long rebase" > /dev/null
assert_equal "$WT_KEY" "$(lock_keys)" \
  "\`claim worktree\` writes the per-checkout key, not the bare name"
ab sess-a release worktree > /dev/null
assert_equal "" "$(lock_keys)" "and \`release worktree\` resolves to the same key"

out=$(ab sess-a wait worktree --timeout 0 2>&1)
assert_contains "$out" "claimed 'worktree'" "\`wait worktree\` takes it when it is free"
assert_equal "$WT_KEY" "$(lock_keys)" "under the key the guard uses"
ab sess-a release worktree > /dev/null

ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=git add -A" id=a-wt)" > /dev/null
assert_equal "$WT_KEY" "$(lock_keys)" "and a guarded \`git add\` writes that key too"
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=a-wt)" > /dev/null

# The digest is of the checkout, so the other worktree is a different lock —
# without which "the CLI agrees with the guard" could be satisfied by both being
# globally wrong.
ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT" "cmd=git add -A" id=a-wt2)" > /dev/null
assert_equal "$(worktree_key worktree "$WT")" "$(lock_keys)" \
  "a second checkout locks a key of its own"
ab_hook post-bash "$(payload post-bash sid=sess-b "cwd=$WT" id=a-wt2)" > /dev/null

# ---- a `serve` verb resolves the same key as `claim` ------------------------

ab sess-b claim web --why "mine for now" > /dev/null
out=$(ab sess-a serve web 2>&1)
assert_contains "$out" "is held by $B" \
  "\`serve\` is stopped by the lock \`claim\` wrote, so both resolved one key"
ab sess-b release web > /dev/null

# ---- DIVERGENCE 1: an instance key exists for the guard and not for the CLI --
#
# Deliberate today, and named as such in the plan: `resolve_lock` is handed a
# resource name and no command, and the `key` regex matches against a command,
# so `agentbus claim simulator` cannot know which device is meant. The guard,
# which has the command, does. The two therefore lock different things for what
# is, to the person typing, the same resource.
#
# Pinned here as intended behaviour. M1 decides in a commit of its own whether
# `agentbus claim simulator --udid ABC` or `agentbus claim simulator@ABC` should
# exist. When this assertion fails, it is because that decision was taken — not
# because something broke.

ab sess-a claim simulator --why "all of them" > /dev/null
CLI_SIM=$(lock_keys)
ab sess-a release simulator > /dev/null

MAESTRO="maestro --udid ABC123 test a.yaml"
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$MAESTRO" id=a-sim)" > /dev/null
GUARD_SIM=$(lock_keys)
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=a-sim)" > /dev/null

assert_equal "simulator" "$CLI_SIM" "\`claim simulator\` locks the whole resource"
assert_equal "simulator@ABC123" "$GUARD_SIM" \
  "while the guard locks the one device the command names"
assert_differ "$CLI_SIM" "$GUARD_SIM" \
  "DIVERGENCE (pinned on purpose, M1 revisits): the CLI and the guard lock different names for one simulator"

# The instance is invisible to BOTH when the command is an `agentbus` line:
# `agentbus` is a read-only head, so `command_targets` yields nothing to run the
# `key` regex over. That is agreement rather than parity by design, and it is
# worth pinning because it is the case M4's `plan_for(names=…)` has to reproduce.
RUNLINE="agentbus run simulator -- $MAESTRO"
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$RUNLINE" id=a-run)" > /dev/null
assert_equal "simulator" "$(lock_keys)" \
  "the guard reads no device out of an \`agentbus run\` line"
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=a-run)" > /dev/null
assert_equal "simulator" "$(ab sess-a run simulator -- "$LOCKDUMP" 2>/dev/null)" \
  "and neither does \`agentbus run\` itself, so for that line the two agree"

# ---- DIVERGENCE 2: `claim` does not take what a resource implies ------------
#
# Also deliberate, also named in the plan: a claim is a considered act and
# expanding it silently would hold more than the caller asked for. It says so
# instead. `run` and the guard both expand — the guard because a Maestro run is
# only meaningful against the bundler serving your tree, `run` because it did
# not and the careful command was the weaker one.
#
# Pinned. M1's expected outcome is that `claim` keeps refusing and keeps saying
# so, but that is to be confirmed in its own commit rather than assumed here.

out=$(ab sess-a claim rig --why "just the rig" 2>&1)
CLI_RIG=$(lock_keys)
assert_contains "$out" "implies bundler" "a deliberate claim is told what it has NOT taken"
assert_contains "$out" "agentbus claim rig,bundler" "and how to take it"
ab sess-a release rig > /dev/null

ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=rigrun --all" id=a-rig)" > /dev/null
GUARD_RIG=$(lock_keys)
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=a-rig)" > /dev/null

assert_equal "rig" "$CLI_RIG" "\`claim rig\` takes the rig and nothing else"
assert_equal "bundler rig" "$GUARD_RIG" "while a guarded rigrun takes what it implies"
assert_differ "$CLI_RIG" "$GUARD_RIG" \
  "DIVERGENCE (pinned on purpose, M1 revisits): \`claim\` does not expand \`implies\` and the guard does"

assert_equal "bundler rig" "$(ab sess-a run rig -- "$LOCKDUMP" 2>/dev/null)" \
  "\`run\`, unlike \`claim\`, expands it — the same answer as the guard"
assert_equal "" "$(lock_keys)" "and gives every one of them back when the command ends"


# =============================================================================
# Check B — every advertised exit lifts the block
# =============================================================================
#
# The table below is hand-written and is a second copy of what the messages in
# `guard_bash`, `serving_check` and `wrong_port_check` say. That is deliberate
# duplication: a table derived from the message could not catch the message
# being wrong, and extracting a command line out of rendered English is exactly
# the thing M3 removes the need for. When `plan_for` returns exits as
# `{cmd, when, kind}` and the message is rendered from them, this table is what
# gets deleted.
#
#   <scenario>|<what the exit claims to do>|<text the block must contain, verbatim>
#
#   through — running it must make the refused command allowed
#   correct — it does not unblock; it says to run a DIFFERENT command instead
#   bypass  — it steps over the decision rather than resolving it
#   ask     — a way to find out, or to ask; not a way through
#
# `@holder@` is the one substitution: a block names the agent holding the lock,
# and no fixture can know that name before it runs.

EXITS='
held|ask|agentbus status
held|ask|agentbus post --to @holder@ "..."
held|through|agentbus wait db --why "..."
held|bypass|AGENTBUS_OFF=1 <your command>
held|through|agentbus claim db --steal --why "..."
same-checkout|ask|agentbus status
same-checkout|ask|agentbus post --to @holder@ "..."
same-checkout|through|agentbus wait db --why "..."
same-checkout|bypass|AGENTBUS_OFF=1 <your command>
same-checkout|through|agentbus claim db --steal --why "..."
sibling|ask|agentbus status
sibling|ask|agentbus post --to @holder@ "..."
sibling|through|agentbus wait db --why "..."
sibling|bypass|AGENTBUS_OFF=1 <your command>
sibling|through|agentbus claim db --steal --why "..."
unidentified|through|agentbus claim db --as <your name>
unidentified|through|agentbus wait db --why "..."
unidentified|through|agentbus release --all
unidentified|ask|agentbus status
unidentified|ask|agentbus post --to @holder@ "..."
unidentified|bypass|AGENTBUS_OFF=1 <your command>
unidentified|through|agentbus claim db --steal --why "..."
implied|through|agentbus wait bundler --why "..."
implied|bypass|AGENTBUS_OFF=1 <your command>
implied|through|agentbus claim bundler --steal --why "..."
instance|through|agentbus wait simulator --why "..."
instance|bypass|AGENTBUS_OFF=1 <your command>
instance|through|agentbus claim simulator --steal --why "..."
serving|through|agentbus serve web
serving|through|agentbus run web -- <your command>
wrong-port|correct|eval "$(agentbus env)"
wrong-port|correct|agentbus port api
wrong-port|bypass|AGENTBUS_OFF=1 <your command>
'

advertised() {   # <scenario> — assert every exit the table lists appears in $REASON
  printf '%s\n' "$EXITS" | while IFS='|' read -r scen kind text; do
    [ "$scen" = "$1" ] || continue
    text=${text//@holder@/$HOLDER}
    assert_contains "$REASON" "$text" "the $1 block advertises \`$text\` ($kind)"
  done
}

# ---- 1. held by another session, in another checkout ------------------------

HOLDER="$A"
ab sess-a claim db --why "seeding the database" > /dev/null
guard b1-1 sess-b "$WT" "$PSQL"
assert_equal deny "$VERDICT" "a database another session holds blocks the command"
advertised held
assert_contains "$REASON" "$A" "and the block names who is holding it"

# The two lines that are advertised without claiming to unblock anything. Both
# have to be reachable — a guard that refuses the advice it just printed is a
# defect this repository has shipped twice — and neither may quietly become a
# way through without somebody noticing.
out=$(take_exit b1-2 sess-b "$WT" 'agentbus status')
assert_contains "$out" "$A" "\`agentbus status\` runs and shows the other session"
guard b1-3 sess-b "$WT" "$PSQL"
assert_equal deny "$VERDICT" "reading the roster does not lift the block, and does not claim to"

take_exit b1-4 sess-b "$WT" "agentbus post --to $A \"...\"" > /dev/null
assert_contains "$(ab sess-a inbox)" "..." "\`agentbus post --to\` reaches the holder"
guard b1-5 sess-b "$WT" "$PSQL"
assert_equal deny "$VERDICT" "and asking them does not lift it either"

# The bypass. Advertised as `AGENTBUS_OFF=1 <your command>`, which is the one
# exit that is a template rather than a line to copy — the reader substitutes
# the command they were refused. It is not a lift in the sense the others are:
# it steps over the decision instead of resolving it, and the block stands for
# the next command that does not carry it.
guard b1-6 sess-b "$WT" "AGENTBUS_OFF=1 $PSQL"
assert_equal allow "$VERDICT" "AGENTBUS_OFF=1 in front of the command gets past the guard"
guard b1-7 sess-b "$WT" "$PSQL"
assert_equal deny "$VERDICT" "…which is a bypass, not a lift: the block is exactly where it was"

out=$(take_exit b1-8 sess-b "$WT" 'agentbus claim db --steal --why "..."')
assert_contains "$out" "claimed 'db'" "the advertised steal takes it"
guard b1-9 sess-b "$WT" "$PSQL"
assert_equal allow "$VERDICT" "and the block lifts"
ab sess-b release db > /dev/null

# The wait is the only exit whose whole point is that somebody else lets go
# while it is running, so it is the only one worth the wall-clock time.
ab sess-a claim db --why "seeding the database" > /dev/null
guard b1-10 sess-b "$WT" "$PSQL"
assert_equal deny "$VERDICT" "the database is held again"
exit_seen_by_guard b1-11 sess-b "$WT" 'agentbus wait db --why "..."'
start_exit sess-b 'agentbus wait db --why "..."' "$TEST_TMP/wait-held.out"
sleep 1
ab sess-a release db > /dev/null
finish_exit 15
out=$(cat "$TEST_TMP/wait-held.out")
assert_contains "$out" "is held by $A" "the advertised wait queues against the lock in the way"
assert_contains "$out" "claimed 'db'" "and takes it the moment it frees"
guard b1-12 sess-b "$WT" "$PSQL"
assert_equal allow "$VERDICT" "so the block lifts"
ab sess-b release db > /dev/null

# ---- 2. the same-checkout variant -------------------------------------------
#
# Same exits, different paragraph in the middle: two sessions in one checkout
# are running the same code, so the resource's `why` — which explains
# cross-worktree damage — would state something the reader can see is false.

new_session sess-c "$REPO"
C=$(ab sess-c name)
HOLDER="$A"
ab sess-a claim db --why "seeding the database" > /dev/null
guard b2-1 sess-c "$REPO" "$PSQL"
assert_equal deny "$VERDICT" "a session in the same checkout is blocked too"
assert_contains "$REASON" "the same one you are in" "and told that is where the holder is"
assert_contains "$REASON" "You are both in this checkout" "with the reason that fits"
advertised same-checkout

# The exit set is identical to the ordinary block's and reaches the same code,
# so only the two that touch the lock are run again here.
guard b2-2 sess-c "$REPO" "AGENTBUS_OFF=1 $PSQL"
assert_equal allow "$VERDICT" "the bypass works from the same checkout"
out=$(take_exit b2-3 sess-c "$REPO" 'agentbus claim db --steal --why "..."')
assert_contains "$out" "claimed 'db'" "and so does the steal"
guard b2-4 sess-c "$REPO" "$PSQL"
assert_equal allow "$VERDICT" "which lifts the block"
ab sess-c release db > /dev/null

# ---- 3. two subagents of one session ----------------------------------------
#
# A parent and its own subagent never contend; two subagents do, and that is the
# case that must serialise. It is also the case where `agentbus wait` depends on
# the hint the guard leaves, because nothing in a shell can tell one subagent of
# a session from another.

ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-1 agent_type=general-purpose)" > /dev/null
ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-2 agent_type=general-purpose)" > /dev/null
SUB1=$(python3 -c "
import glob, json
for p in glob.glob('$AGENTBUS_HOME/agents/*.json'):
    r = json.load(open(p))
    if r.get('agent_id') == 'sub-1':
        print(r['name'])")
SUB2=$(python3 -c "
import glob, json
for p in glob.glob('$AGENTBUS_HOME/agents/*.json'):
    r = json.load(open(p))
    if r.get('agent_id') == 'sub-2':
        print(r['name'])")
assert_contains "$SUB1" "$A/" "the session's first subagent is named after it"

sub1_holds_db() {   # <tool use id> — one subagent's command takes the database
  ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$PSQL" id="$1" \
    agent_id=sub-1 agent_type=general-purpose)" > /dev/null
}

sub1_holds_db b3-hold
assert_equal "db" "$(lock_keys)" "one subagent's command holds the database"

HOLDER="$SUB1"
guard b3-1 sess-a "$REPO" "psql -c 'select 2'" sub-2
assert_equal deny "$VERDICT" "and its sibling is refused"
assert_contains "$REASON" "two agents of the same session" "with the reason that fits"
advertised sibling

# Typed exactly as advertised it works, and the reason it works is the hint: the
# hook is the only thing that knows sub-2 is the one asking, and it leaves that
# under a key computed from the tokens of the line it saw.
exit_seen_by_guard b3-2 sess-a "$REPO" 'agentbus wait db --why "..."' sub-2
start_exit sess-a 'agentbus wait db --why "..."' "$TEST_TMP/wait-sib.out"
sleep 1
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=b3-hold \
  agent_id=sub-1 agent_type=general-purpose)" > /dev/null
finish_exit 15
out=$(cat "$TEST_TMP/wait-sib.out")
# The block names the subagent holding the lock; `wait` names the session it
# belongs to. Different vocabularies for one holder, pinned so that M3 rendering
# both from one Plan is visibly a change.
assert_contains "$out" "is held by $A" "the advertised line queues against the lock in the way"
assert_contains "$out" "claimed 'db'" "and takes it when that command ends"
guard b3-3 sess-a "$REPO" "psql -c 'select 2'" sub-2
assert_equal allow "$VERDICT" "and the block lifts for the sibling that waited"
ab sess-a release --all > /dev/null

# DEFECT (pinned, M1 must decide): the same exit, run without the guard having
# seen that exact line, reports success and lifts nothing.
#
# `agentbus wait db` from a shell cannot say which subagent is asking, so with
# no hint it is read as the session itself — and a parent never contends with
# its own subagent, so `do_claim` answers "already yours". It prints
# `claimed 'db'`, exits 0, and the sibling that read the advice is still
# blocked. Any wording but the advertised one reaches this path, and so does an
# `agentbus wait` inside a script the hook never saw.
sub1_holds_db b3-hold2
assert_equal "db" "$(lock_keys)" "the sibling's command takes the database again"
out=$(run_exit sess-a 'agentbus wait db --why "..."')
assert_contains "$out" "claimed 'db'" \
  "DEFECT (pinned): a wait the guard did not see reports success without taking anything"
assert_equal "db" "$(lock_keys)" "leaving the sibling's lock exactly where it was"
guard b3-4 sess-a "$REPO" "psql -c 'select 2'" sub-2
assert_equal deny "$VERDICT" \
  "DEFECT (pinned): so that same exit, typed any other way, does NOT lift the block"
# And a second thing worth knowing while it is in front of us: that stray wait
# upgraded a one-command claim to a hard one, and `release_autoclaim` gives back
# only soft locks — so PostToolUse no longer frees it.
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=b3-hold2 \
  agent_id=sub-1 agent_type=general-purpose)" > /dev/null
assert_equal "db" "$(lock_keys)" \
  "DEFECT (pinned): and the command ending no longer gives it back, because it is hard now"
ab sess-a release --all > /dev/null

# ---- 4. taken by somebody in this session who cannot be named ---------------
#
# An `agentbus claim` buried in a runner script: the guard never saw the command
# line, so there is no hint, and the lock has to admit it cannot say which party
# took it. Treating that as "the session itself" is what let three subagents
# drive one simulator, so it blocks the session's other agents instead.

ab sess-a claim db --why "from inside a runner script" > /dev/null
HOLDER="$A"
guard b4-1 sess-a "$REPO" "$PSQL" sub-2
assert_equal deny "$VERDICT" "a claim nobody can attribute blocks this session's own agents"
assert_contains "$REASON" "nothing can" "and says why it cannot tell"
advertised unidentified

# DEFECT (pinned, M1 must fix): `agentbus claim db --as <your name>` is the
# first thing this block tells the reader to do, and it does not work.
#
# The guard no longer refuses the line — that half was fixed on 2026-08-02, when
# `--as` was added beside `--steal` in `explicit_resources`. But `do_claim` is
# then asked to take a lock held by an unidentified party of the same session,
# `same_party` answers no for exactly the reason the block exists, and the CLI
# exits 1. The advice is reachable and useless: naming yourself does not make an
# anonymous lock yours, and nothing in the message says to add `--steal`.
out=$(take_exit b4-2 sess-a "$REPO" "agentbus claim db --as $SUB2" sub-2)
assert_contains "$out" "is held by $A" \
  "DEFECT (pinned): the \`--as\` claim the block advertises is refused by the CLI"
guard b4-3 sess-a "$REPO" "$PSQL" sub-2
assert_equal deny "$VERDICT" \
  "DEFECT (pinned): so the first exit the unidentified block offers does NOT lift it"

# The wait does queue against the right lock, which is the property that matters
# — it is the exit that works if the other agent ever finishes.
out=$(take_exit b4-4 sess-a "$REPO" 'agentbus wait db --timeout 0 --why "..."' sub-2)
assert_contains "$out" "is held by $A" "the advertised wait queues against the real lock"
assert_not_contains "$out" "claimed 'db'" "rather than reporting a claim it did not make"

# And the one that does lift it.
out=$(take_exit b4-5 sess-a "$REPO" 'agentbus release --all')
assert_contains "$out" "released 1" "\`agentbus release --all\` gives back the anonymous lock"
guard b4-6 sess-a "$REPO" "$PSQL" sub-2
assert_equal allow "$VERDICT" "and that exit lifts the block"
ab sess-a release --all > /dev/null

# ---- 5. blocked on something the command only implies -----------------------

HOLDER="$A"
ab sess-a claim bundler --why "packing" > /dev/null
guard b5-1 sess-b "$WT" "rigrun --all"
assert_equal deny "$VERDICT" "a command is blocked on a resource it never named"
assert_contains "$REASON" "Your command drives 'rig'" "and told which of its own needs it"
advertised implied

guard b5-2 sess-b "$WT" "AGENTBUS_OFF=1 rigrun --all"
assert_equal allow "$VERDICT" "the bypass works for an implied resource"
out=$(take_exit b5-3 sess-b "$WT" 'agentbus claim bundler --steal --why "..."')
assert_contains "$out" "claimed 'bundler'" "the steal names the implied resource and takes it"
guard b5-4 sess-b "$WT" "rigrun --all"
assert_equal allow "$VERDICT" "and the block lifts"
ab sess-b release bundler > /dev/null

# ---- 6. blocked on one instance of several ----------------------------------
#
# DEFECT (pinned, M1 must fix): both ways through that this block advertises
# report success and leave it exactly where it was.
#
# The block is about `simulator@ABC123`. Its advice names the resource the way a
# person types it — `simulator` — and `resolve_lock`, given a name and no
# command, cannot get back to the instance. So `agentbus wait simulator` and
# `agentbus claim simulator --steal` both act on a bare `simulator` lock that
# nothing was contending for: they take a lock that was free, print "claimed",
# exit 0, and the device is still somebody else's.
#
# This is the same shape as the `scope: "worktree"` defect fixed on 2026-07-29 —
# an exit that reports success against a lock it never looked at — and it is why
# the plan's rule is "the block must lift", not "the exit must be allowed".

ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" "cmd=$MAESTRO" id=b6-hold)" > /dev/null
assert_equal "simulator@ABC123" "$(lock_keys)" "one session takes one device"

HOLDER="$A"
guard b6-1 sess-b "$WT" "maestro --udid ABC123 test b.yaml"
assert_equal deny "$VERDICT" "and another reaching for that device is refused"
advertised instance

# Bounded, because the day M1 teaches `resolve_lock` about instances this wait
# stops returning instantly and starts queueing for the ninety seconds it
# defaults to — which is the fix working, and should read as one failed
# assertion rather than as a suite that hangs.
exit_seen_by_guard b6-2 sess-b "$WT" 'agentbus wait simulator --why "..."'
start_exit sess-b 'agentbus wait simulator --why "..."' "$TEST_TMP/wait-inst.out"
finish_exit 15
out=$(cat "$TEST_TMP/wait-inst.out")
assert_contains "$out" "claimed 'simulator'" \
  "DEFECT (pinned): the advertised wait reports a claim instantly"
assert_equal "simulator simulator@ABC123" "$(lock_keys)" \
  "DEFECT (pinned): having taken a second, unrelated lock rather than the one in the way"
guard b6-3 sess-b "$WT" "maestro --udid ABC123 test b.yaml"
assert_equal deny "$VERDICT" \
  "DEFECT (pinned): so \`agentbus wait simulator\` does NOT lift an instance block"
ab sess-b release simulator > /dev/null

out=$(take_exit b6-4 sess-b "$WT" 'agentbus claim simulator --steal --why "..."')
assert_contains "$out" "claimed 'simulator'" \
  "DEFECT (pinned): and the advertised steal reports success too"
guard b6-5 sess-b "$WT" "maestro --udid ABC123 test b.yaml"
assert_equal deny "$VERDICT" \
  "DEFECT (pinned): while \`agentbus claim simulator --steal\` does NOT lift it either"
ab sess-b release simulator > /dev/null

# The bypass is the only exit on this block that does what it says.
guard b6-6 sess-b "$WT" "AGENTBUS_OFF=1 maestro --udid ABC123 test b.yaml"
assert_equal allow "$VERDICT" "only the bypass gets the reader past an instance block"
ab_hook post-bash "$(payload post-bash sid=sess-a "cwd=$REPO" id=b6-hold)" > /dev/null
assert_equal "" "$(lock_keys)" "the rig is free again"

# ---- 7. the service is answering for another checkout -----------------------
#
# No lock is involved: holding "web" does not make it serve your code. This
# block therefore has an exit set of its own, and no bypass in it.

out=$(ab sess-a serve web 2>&1)
assert_contains "$out" "restarted from your worktree" "the first session starts the service"

guard b7-1 sess-b "$WT" "webcurl /health"
assert_equal deny "$VERDICT" "the other checkout is refused with no lock held anywhere"
assert_contains "$REASON" "serving a different checkout" "and told why"
advertised serving
assert_not_contains "$REASON" "AGENTBUS_OFF" \
  "and offers no bypass, so the exits above are the whole of its advice"
assert_equal "" "$(lock_keys)" "the refused command claimed nothing on the way"

out=$(take_exit b7-2 sess-b "$WT" 'agentbus serve web')
assert_contains "$out" "restarted from your worktree" "the advertised handover runs"
guard b7-3 sess-b "$WT" "webcurl /health"
assert_equal allow "$VERDICT" "and the block lifts"

# The second exit is the other template line: `-- <your command>` is where the
# reader puts what they were refused. It moves the service and runs the command
# in one step, and leaves it moved.
out=$(take_exit b7-4 sess-a "$REPO" 'agentbus run web -- true')
assert_contains "$out" "restarted from your worktree" "\`agentbus run\` moves it too"
guard b7-5 sess-a "$REPO" "webcurl /health"
assert_equal allow "$VERDICT" "and leaves the block lifted for the tree it moved it to"
guard b7-6 sess-b "$WT" "webcurl /health"
assert_equal deny "$VERDICT" "while the other checkout is now the one refused"

# ---- 8. aimed at a port that belongs to another checkout --------------------
#
# The exits here are `correct`, not `through`: the block is not saying "get
# permission", it is saying "that is not your port". Running them and re-running
# the same command must therefore leave the block standing — and the command
# they tell you to run instead must be allowed. Asserted both ways, because a
# test that only demanded a lift would have to call this block broken, and a
# test that only demanded the exit be allowed would have missed everything in
# section 6.

MINE=$( cd "$WT" && AGENTBUS_SESSION=sess-b "$AB_ROOT/bin/agentbus" port api )
WRONG="curl -sf localhost:$DECLARED/health"
guard b8-1 sess-b "$WT" "$WRONG"
assert_equal deny "$VERDICT" "reaching for the declared port from a linked worktree is refused"
assert_contains "$REASON" "which is not this checkout's" "and told whose it is not"
advertised wrong-port
assert_contains "$REASON" "$MINE" "and told which port is this checkout's"

# The advertised line is `eval "$(agentbus env)"`, asserted verbatim above. What
# is run here is the inner half: evaluating it would export API_PORT into this
# test's own shell for every scenario after it, and what the exit is worth is
# entirely in what the inner half prints.
out=$(take_exit b8-2 sess-b "$WT" 'agentbus env')
assert_contains "$out" "export API_PORT=$MINE" "the advertised env hands over this checkout's port"
guard b8-3 sess-b "$WT" "$WRONG"
assert_equal deny "$VERDICT" "the same command is still refused, as it must be"
guard b8-4 sess-b "$WT" "curl -sf localhost:$MINE/health"
assert_equal allow "$VERDICT" "and the command it tells you to run instead is allowed"

out=$(take_exit b8-5 sess-b "$WT" 'agentbus port api')
assert_equal "$MINE" "$out" "\`agentbus port api\` prints the same number on its own"

guard b8-6 sess-b "$WT" "AGENTBUS_OFF=1 $WRONG"
assert_equal allow "$VERDICT" "and saying you really do mean the other one gets you through"


finish
