#!/usr/bin/env bash
# `agentbus integrate` — the one verb here that spends money and the only one
# that acts.
#
# One chat cannot make another chat act: hooks fire on a session's own activity,
# so nothing can put a turn into an idle interactive session. A session agent-bus
# starts itself is different, because it was created programmatically. So the
# thing that works is not "make those two chats coordinate" — it is "take the work
# they finished and have a session of our own put it together".
#
# What this file can prove without paying for a model, and does:
#
#   - the refusal. No `--yes`, no worktree, no event, nothing spent, exit 1.
#   - the command line, exactly, including the budget cap and the absence of any
#     flag that would skip permissions.
#   - the environment, exactly: the parent's session identity gone, the bus left
#     ON, and a `git push` that really fails — measured by pushing.
#   - the whole run, against a stand-in `claude` on PATH that does the merges with
#     plain git. That exercises the worktree, the ancestry check, the report and
#     the cleanup; only the model's judgement is missing.
#   - that it cannot close anybody's task, which is a property of the engine
#     rather than of the prompt, so it can be asserted directly.
#   - that a run which does not finish leaves the evidence instead of tidying it.
#
# What is left to tests/live/acceptance.sh: that a real spawned session registers
# on the bus and appears in the roster. That needs a real CLI and real money.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo intrepo)
printf 'shared\n' > "$REPO/shared.py"
printf 'one\n' > "$REPO/one.py"
printf 'two\n' > "$REPO/two.py"
commit_all "$REPO"

ONE=$(make_worktree "$REPO" intone feat-one)
TWO=$(make_worktree "$REPO" inttwo feat-two)
printf 'ONE\n' > "$ONE/one.py"
commit_all "$ONE"
printf 'TWO\n' > "$TWO/two.py"
commit_all "$TWO"

new_session sess-one "$ONE"
new_session sess-two "$TWO"
A=$(ab sess-one name)
B=$(ab sess-two name)
ab sess-one take "rewrite the loader" > /dev/null
ab sess-one done --note "done and tested" > /dev/null
ab sess-two take "restyle the templates" > /dev/null
ab sess-two done > /dev/null

# A third session, in the primary checkout, which is who runs this.
new_session sess-boss "$REPO"

worktrees() { git -C "$REPO" worktree list | wc -l | tr -d ' '; }
ledger_print() { shasum "$AGENTBUS_HOME"/tasks/*.json | shasum | cut -c1-16; }
tree_print() {
  python3 -c "
import hashlib, os, sys
h = hashlib.sha1()
for root in sys.argv[1:]:
    for base, dirs, names in os.walk(root):
        dirs.sort()
        for n in sorted(names):
            p = os.path.join(base, n)
            h.update(os.path.relpath(p, root).encode())
            try:
                with open(p, 'rb') as fh:
                    h.update(fh.read())
            except OSError:
                h.update(b'?')
print(h.hexdigest())" "$@"
}

# ---- it refuses, and refusing costs nothing ---------------------------------

WT_BEFORE=$(worktrees)
SEQ_BEFORE=$(read_seq)
# Counted rather than asserted absent: TMPDIR is shared with everything else on
# the machine, and a leftover from another run would make an absolute check pass
# or fail for reasons that have nothing to do with this one.
scratch_dirs() { ls -d "${TMPDIR:-/tmp}"/agentbus-land-* 2>/dev/null | wc -l | tr -d ' '; }
SCRATCH_BEFORE=$(scratch_dirs)
out=$(ab sess-boss integrate 2>&1)
rc=$?
assert_equal 1 "$rc" "without --yes it exits non-zero, so nothing reads it as a run"
assert_contains "$out" "Nothing was created and nothing was spent" \
  "and says so rather than leaving the reader to guess"
assert_contains "$out" "agentbus integrate --yes" "with the one thing to add"
assert_contains "$out" "feat-one, then feat-two" \
  "the plan names the branches it would merge, in the order it would merge them"
assert_contains "$out" "detached at main" "and that it works detached at the trunk"
assert_contains "$out" "This is real money" "and says outright that this costs"
assert_contains "$out" 'capped at $2.00' "with the ceiling it will be held to"
assert_contains "$out" "never      push, touch another worktree, or close anybody's task" \
  "and what it will not do"
assert_contains "$out" "rewrite the loader" \
  "and the finished work it is about, in the words its author used"
assert_equal "$WT_BEFORE" "$(worktrees)" \
  "a refusal creates no worktree — the plan is printed before anything exists"
assert_equal "$SEQ_BEFORE" "$(read_seq)" "and puts nothing on the bus"
assert_equal "$SCRATCH_BEFORE" "$(scratch_dirs)" \
  "and leaves no scratch directory behind either"

# ---- the command line it would run ------------------------------------------
#
# Printed as part of the plan, so what is about to be spent is legible before it
# is spent. The absence of a permission-skipping flag is asserted rather than
# assumed: the worker gets the tools it needs and no more.

assert_contains "$out" "It runs as: claude -p <the prompt above>" \
  "the plan prints the command line itself"
assert_contains "$out" "--max-budget-usd 2.00" \
  "including the cap the CLI itself enforces, which is what makes the promise keepable"
assert_contains "$out" "--allowedTools Bash Read Edit Write Grep Glob" \
  "and the tools it is given"
assert_contains "$out" "--output-format stream-json" \
  "and that its transcript is machine-readable, so the run can be reported on"
assert_not_contains "$out" "dangerously-skip-permissions" \
  "and nothing that would let it do anything at all"
assert_contains "$(ab sess-boss integrate --budget 0.25 --model haiku 2>&1)" \
  "--model haiku --max-budget-usd 0.25" "both of which the caller can change"

# ---- the environment the worker is handed ------------------------------------

env_of() {   # <python expression over `env`>
  python3 -c "
import importlib.machinery, importlib.util, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
os.environ['AGENTBUS_SESSION'] = 'sess-boss'
os.environ['CLAUDE_CODE_SESSION_ID'] = 'sess-boss'
os.environ['CLAUDE_PID'] = '4242'
os.environ['AGENTBUS_OFF'] = '1'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
env = ab.worker_env('$REPO')
print($1)"
}
# Inheriting the parent's identity is not a small bug: the worker would register
# AS the chat that started it, so one roster line would cover two processes and
# the parent's write log would collect the worker's files.
assert_equal False "$(env_of '"AGENTBUS_SESSION" in env')" \
  "the worker does not inherit the session id of the chat that spawned it"
assert_equal False "$(env_of '"CLAUDE_CODE_SESSION_ID" in env')" \
  "nor the one Claude Code itself would have passed down"
assert_equal False "$(env_of '"CLAUDE_PID" in env')" "nor its process id"
# The opposite kind of edit, and just as load-bearing: it is meant to be an
# ordinary citizen of the bus, and a worker started from a shell where somebody
# had switched the bus off would register nowhere and be guarded by nothing.
assert_equal False "$(env_of '"AGENTBUS_OFF" in env')" \
  "and AGENTBUS_OFF is cleared, so it registers like any other session"
assert_equal "$AGENTBUS_HOME" "$(env_of 'env["AGENTBUS_HOME"]')" \
  "while the bus it joins is the same one everybody else is on"

# ---- and it cannot push, measured by pushing --------------------------------

git init -q --bare "$TEST_TMP/remote.git"
git -C "$REPO" remote add origin "$TEST_TMP/remote.git"
push_out=$(python3 -c "
import importlib.machinery, importlib.util, os, subprocess
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
r = subprocess.run(['git', 'push', 'origin', 'main'], cwd='$REPO',
                   capture_output=True, text=True, env=ab.worker_env('$REPO'))
print(r.returncode, (r.stderr or '').replace('\n', ' '))")
assert_contains "$push_out" "agent-bus-refuses-to-push" \
  "a push from the worker's environment fails, and says why"
assert_not_contains "$push_out" "0 " "with git reporting a failure, not a success"
# Falsifiable only against the other half: without the override the same push
# works, which is what makes the override the thing doing the work.
if git -C "$REPO" push -q origin main 2>/dev/null; then
  _ok "while the identical push without that environment succeeds"
else
  _bad "while the identical push without that environment succeeds" \
    "the push failed for some other reason, so the rail above proves nothing"
fi
# The remote stays, so that the run further down is a repository that really has
# somewhere to push to and the override can be seen in the environment the
# spawned process was actually handed.

# ---- what the worker is told ------------------------------------------------

prompt_of() {   # <python expression over `p`>
  python3 -c "
import importlib.machinery, importlib.util, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
sessions = ab.load_sessions()
me = [s for s in sessions if s['sid'] == 'sess-boss'][0]
v = ab.merge_view(me['repo_key'], sessions, me['root'])
p = ab.worker_prompt(v, [c['branch'] for c in v['candidates']], '/tmp/scratch')
print($1)"
}
p=$(prompt_of 'p')
assert_contains "$p" "/tmp/scratch" "the worker is told which scratch worktree it is in"
assert_contains "$p" "detached at main" "and what it is detached at"
assert_contains "$p" "feat-one" "and which branches to merge"
assert_contains "$p" "rewrite the loader" "and whose work each one is"
assert_contains "$p" "Do not push" "and told not to push"
assert_contains "$p" "Do not leave this directory" "nor to work in anybody else's checkout"
assert_contains "$p" "agentbus done" \
  "nor to close the tasks, because that is their authors' declaration to make"
assert_contains "$p" "run it" "and to run whatever this repository uses to check itself"

# ---- it cannot close anybody's task, and not because it is asked not to ------
#
# The engine already makes this impossible, which is worth asserting where it can
# be seen: a candidate is made of tasks whose state is `done`, `done` refuses a
# task that is not the caller's own, and `take` refuses one that is finished. There
# is no sequence of verbs by which another session closes finished work.

ab sess-one take "still on the loader tests" > /dev/null      # t3, open
L=$(ledger_print)
out=$(ab sess-boss done t3 2>&1); rc=$?
assert_equal 1 "$rc" "a third session cannot close somebody else's open task"
assert_contains "$out" "$A" "and the refusal names whose it is"
# A finished task is a different shape of the same answer: there is nothing left
# to close, so it is told so and the ledger is not touched. Both halves matter,
# because between them there is no order of verbs that reaches somebody else's
# finished work — which is what makes "it must not close anybody's task" a
# property of the engine rather than a line in a prompt.
out=$(ab sess-boss done t1 2>&1)
assert_contains "$out" "already done" "and a finished one has nothing left to close"
out=$(ab sess-boss take t1 2>&1); rc=$?
assert_equal 1 "$rc" "nor can it take a finished task over to close it again"
assert_contains "$out" "is finished" "which the refusal says"
assert_equal "$L" "$(ledger_print)" "so the ledger is byte-identical after all three"

# ---- with no CLI to spawn, it creates nothing --------------------------------
#
# PATH is narrowed to a directory holding only the tools the engine itself needs,
# so `claude` is genuinely absent whether or not this host has one installed.

BARE="$TEST_TMP/bare-bin"
mkdir -p "$BARE"
for tool in git python3 sh bash env uname sed grep; do
  src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$BARE/$tool"
done
out=$(PATH="$BARE" AGENTBUS_SESSION=sess-boss "$AB_ROOT/bin/agentbus" integrate --yes 2>&1)
rc=$?
assert_equal 1 "$rc" "with no claude on PATH it refuses"
assert_contains "$out" "no \`claude\` on PATH" "and says that is why"
assert_contains "$out" "Nothing was created" "and that it left nothing behind"
assert_equal "$WT_BEFORE" "$(worktrees)" "which the worktree list agrees with"

# ---- the whole run, against a stand-in for the CLI --------------------------
#
# The stand-in does the merges with plain git and reports the way the real thing
# does. Everything except the model's judgement is exercised: the scratch
# worktree, the ancestry check that does not take the worker's word for it, the
# report, and the cleanup.

STUB="$TEST_TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/claude" <<'STUBEOF'
#!/bin/sh
# A stand-in for the claude CLI. Records what it was given, then does the job
# with plain git so that the surrounding machinery can be tested for free.
printf '%s\n' "$@" > "$AB_STUB_ARGV"
env > "$AB_STUB_ENV"
pwd > "$AB_STUB_CWD"
if [ -n "${AB_STUB_FAIL:-}" ]; then
  printf '{"type":"result","result":"CONFLICTS — a person has to choose"}\n'
  exit "$AB_STUB_FAIL"
fi
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"merging now"}]}}\n'
for b in ${AB_STUB_BRANCHES:-}; do
  git merge --no-ff --no-edit "$b" > /dev/null 2>&1 || {
    printf '{"type":"result","result":"CONFLICTS in %s"}\n' "$b"; exit 2; }
done
printf '{"type":"result","result":"MERGED — both branches in, checks pass"}\n'
exit 0
STUBEOF
chmod +x "$STUB/claude"
export AB_STUB_ARGV="$TEST_TMP/stub.argv" AB_STUB_ENV="$TEST_TMP/stub.env" \
       AB_STUB_CWD="$TEST_TMP/stub.cwd" AB_STUB_BRANCHES="feat-one feat-two"

CHECKOUTS_BEFORE=$(tree_print "$ONE" "$TWO")
L=$(ledger_print)
SEQ_BEFORE=$(read_seq)
out=$(PATH="$STUB:$PATH" AGENTBUS_SESSION=sess-boss "$AB_ROOT/bin/agentbus" \
        integrate --yes 2>&1)
rc=$?
assert_equal 0 "$rc" "with --yes and a CLI to spawn, it runs and succeeds"
assert_contains "$out" "MERGED — both branches in" \
  "and reports what the worker actually said"
assert_contains "$out" "Integrated feat-one, feat-two onto main" \
  "beside its own verdict, which is git's rather than the worker's"
assert_contains "$out" "· merging now" "having shown the worker's progress as it went"
assert_contains "$out" "no task was closed" \
  "and saying that closing the work is still its authors' to declare"

# The worktree it worked in: a fresh temporary directory, and demonstrably not
# anybody's checkout. This is the rail that matters most — a session let loose in
# a running checkout is the failure this whole plugin exists to prevent.
worked_in=$(cat "$TEST_TMP/stub.cwd")
assert_contains "$worked_in" "agentbus-land-" "the worker ran in a scratch worktree"
if [ "$worked_in" != "$REPO" ] && [ "$worked_in" != "$ONE" ] && \
   [ "$worked_in" != "$TWO" ]; then
  _ok "which is none of the three checkouts anybody is working in"
else
  _bad "which is none of the three checkouts anybody is working in" "$worked_in"
fi
assert_no_file "$worked_in" "and it is gone again once the job succeeded"
assert_equal "$WT_BEFORE" "$(worktrees)" "with the repository's worktree list back as it was"
assert_equal "$CHECKOUTS_BEFORE" "$(tree_print "$ONE" "$TWO")" \
  "and not one byte changed in either checkout somebody is working in"
assert_equal "$L" "$(ledger_print)" "nor in the ledger: it read the tasks and closed none"

# The other agents can see it. It is about to appear in their roster holding
# things, and a session nobody announced is the thing this plugin exists to stop.
assert_contains "$(python3 -c "
import json
for line in open('$AGENTBUS_HOME/events.jsonl'):
    r = json.loads(line)
    if 'integration worker' in r.get('text', ''):
        print(r['text'])")" "merging feat-one, feat-two" \
  "and the other sessions in the repository were told it had started"

# What the worker was actually handed, from its own record of it rather than from
# the plan the human read. The two are built by the same functions; this is the
# proof that the functions are the ones being used.
argv=$(tr '\n' ' ' < "$TEST_TMP/stub.argv")
assert_contains "$argv" "--max-budget-usd 2.00" "the spawned process really got the cap"
assert_contains "$argv" "--allowedTools Bash Read Edit Write Grep Glob" \
  "and the tool list, not a wider one"
assert_contains "$argv" "detached at main" "and a prompt scoped by the preview"
assert_not_contains "$(cat "$TEST_TMP/stub.env")" "AGENTBUS_SESSION=sess-boss" \
  "and an environment carrying none of its parent's identity"
assert_contains "$(cat "$TEST_TMP/stub.env")" \
  "GIT_CONFIG_KEY_0=remote.origin.pushurl" \
  "and the git config that stops it pushing, for the remote this repository has"

# ---- --keep, for looking at a run that worked -------------------------------

git -C "$REPO" reset -q --hard HEAD    # the merges went to the scratch tree only
out=$(PATH="$STUB:$PATH" AGENTBUS_SESSION=sess-boss "$AB_ROOT/bin/agentbus" \
        integrate --yes --keep 2>&1)
# From what it printed, not from the shell's `pwd`: mkdtemp hands back
# /var/folders/... and pwd resolves the symlink to /private/var/folders/..., so
# comparing the two strings asserts a macOS detail rather than the behaviour.
kept=$(printf '%s\n' "$out" | sed -n 's/^Kept: //p')
assert_contains "$out" "Kept: " "with --keep it says where it left the worktree"
assert_file "$kept" "and the worktree is still there"
assert_equal "$(cd "$kept" && pwd -P)" "$(cat "$TEST_TMP/stub.cwd")" \
  "and it is the directory the worker actually ran in"
git -C "$REPO" worktree remove --force "$kept" > /dev/null 2>&1

# ---- a run that does not finish leaves the evidence -------------------------
#
# Deleting the half-merged tree to keep the temporary directory tidy would throw
# away the conflict markers and the transcript, which are the only reason anybody
# would look.

CHECKOUTS_BEFORE=$(tree_print "$ONE" "$TWO")
out=$(AB_STUB_FAIL=3 PATH="$STUB:$PATH" AGENTBUS_SESSION=sess-boss \
        "$AB_ROOT/bin/agentbus" integrate --yes 2>&1)
rc=$?
failed_in=$(cat "$TEST_TMP/stub.cwd")
assert_equal 1 "$rc" "a worker that could not finish makes the verb fail"
assert_contains "$out" "this did not finish" "and it says so plainly"
assert_contains "$out" "the worker exited 3" "with what went wrong"
assert_contains "$out" "feat-one, feat-two never landed" \
  "and that the branches did not land, which git was asked rather than the worker"
assert_contains "$out" "CONFLICTS — a person has to choose" \
  "beside what the worker itself said about it"
assert_contains "$out" "left for you to look at" "and that the worktree was kept"
assert_file "$failed_in" "which it was"
assert_file "$(dirname "$failed_in")/worker.jsonl" "with the worker's own transcript beside it"
assert_contains "$out" "worktree remove --force" "and the line that cleans it up"
assert_equal "$CHECKOUTS_BEFORE" "$(tree_print "$ONE" "$TWO")" \
  "and a failed run still touched nobody's checkout"
git -C "$REPO" worktree remove --force "$failed_in" > /dev/null 2>&1

# ---- nothing to integrate is not a failure ----------------------------------

ab sess-one take "something still open" > /dev/null
out=$(ab sess-boss integrate --only feat-nonexistent 2>&1)
rc=$?
assert_equal 0 "$rc" "asking it to land a branch that is not a candidate is not an error"
assert_contains "$out" "nothing to integrate" "it says there is nothing to do"
assert_contains "$out" "without the spending" "and points at the read-only half"

finish
