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

# The override still works, because sometimes another checkout's port is exactly
# what you mean — and taking it leaves a trace, as it does everywhere else.
out=$(ab_hook pre-tool "$(payload bash sid=sess-w1 "cwd=$WT1" \
  "cmd=AGENTBUS_OFF=1 curl -sf localhost:$DECLARED/health" id=pt-6)")
assert_allow "$out" "saying you mean it gets you through"

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
