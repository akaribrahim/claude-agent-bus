#!/usr/bin/env bash
# A session takes the name its human gave the chat.
#
# A session registers the moment it opens, when the only thing distinguishing it
# is its branch — so it is `feat-login`, or `repo-main` on the trunk, and two
# sessions on one branch differ by a `#2`. Then the human renames the chat to
# something meaningful, and the bus never heard about it.
#
# It cannot be read from the hook payload. Measured against Claude Code 2.1.220
# with a settings-file hook that logged every event: SessionStart and
# UserPromptSubmit both carry `transcript_path`, and NEITHER carries a title.
# The `session_title` the code used to test for was never there, which is why
# the branch guarded by it always fired — and why resuming a renamed chat put
# the generated title back over the human's.
#
# And it cannot be done at SessionStart alone: the rename happens after the
# session has registered, because that is when its human has seen enough of it
# to know what to call it. So it is checked every turn.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo namerepo)
commit_all "$REPO"

TRANSCRIPT="$TEST_TMP/chat.jsonl"
: > "$TRANSCRIPT"

title_record() {   # <session id> <title> — what Claude Code appends on a rename
  python3 -c "
import json, sys
print(json.dumps({'type': 'custom-title', 'sessionId': sys.argv[1],
                  'customTitle': sys.argv[2]}))" "$1" "$2" >> "$TRANSCRIPT"
}
bulk() {   # pad the transcript, so the tail read is doing real work
  python3 -c "
import json
with open('$TRANSCRIPT', 'a') as fh:
    for i in range($1):
        fh.write(json.dumps({'type': 'assistant', 'filler': 'x' * 400}) + '\n')"
}
start()  { ab_hook session-start "$(payload session "sid=$1" "cwd=$REPO" \
             "transcript_path=$TRANSCRIPT")"; }
prompt() { ab_hook prompt-submit "$(payload session "sid=$1" "cwd=$REPO" \
             "transcript_path=$TRANSCRIPT")" > /dev/null; }

# ---- without a title, the branch still names it -----------------------------

# Somebody else has to be live first: a session that opens alone is told nothing
# and says nothing, so there would be no output to assert a title on. It sits in
# a worktree of the same repository — same repo key, so it still hears what is
# said, but on its own branch, so it is not competing for the trunk's name.
WT2=$(make_worktree "$REPO" namewt2)
new_session sess-other "$WT2"

out=$(start sess-a)
A=$(ab sess-a name)
assert_equal "namerepo-main" "$A" "a fresh session is named after its checkout"
assert_contains "$out" "sessionTitle" "and it names the chat, which had no title"
# On the decoded field, not the raw JSON: `·` is escaped as · on the wire.
assert_equal "namerepo-main · main" \
  "$(json_field "$out" hookSpecificOutput sessionTitle)" \
  "with its own name and branch"

# Claude Code appends a custom-title record when a hook answers with
# `sessionTitle`, exactly as it does for `/rename` — the real transcript of the
# session this was written in carries 52 of the plugin's own and 22 of its
# human's. Without that step the fixture cannot exercise the case below at all:
# the falsification that deletes the guard passed until this line existed.
title_record sess-a "$(json_field "$out" hookSpecificOutput sessionTitle)"

# What it wrote is remembered, so it cannot later rename itself after its own
# title — a session chasing its own tail, renaming every turn: `namerepo-main`
# would become `namerepo-main-main`, and then that title would be adopted too.
prompt sess-a
assert_equal "namerepo-main" "$(ab sess-a name)" \
  "the title it set itself is not adopted as a new name"
prompt sess-a
assert_equal "namerepo-main" "$(ab sess-a name)" "and not on the turn after that"

# ---- the human renames the chat, mid-session --------------------------------

bulk 200                            # 80KB of transcript after the rename point
title_record sess-a "agentbus"
bulk 20

prompt sess-a
assert_equal "agentbus" "$(ab sess-a name)" \
  "the session takes the name of its chat at the next turn"
assert_contains "$(ab sess-other inbox)" "took the name of its chat" \
  "and the others are told, so an address they hold still resolves"
assert_contains "$(ab sess-other inbox)" "was namerepo-main" "naming what it was"

# Idempotent: the same title must not rename it again every turn.
before=$(read_seq)
prompt sess-a
prompt sess-a
assert_equal "$before" "$(read_seq)" \
  "and an unchanged title says nothing further"

# ---- subagents follow their parent ------------------------------------------

ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-1 agent_type=general-purpose)" > /dev/null
ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$REPO" \
  agent_id=sub-2 agent_type=general-purpose)" > /dev/null
out=$(ab sess-other whois)
assert_contains "$out" "agentbus/1" "a subagent is named after the parent's new name"
assert_contains "$out" "agentbus/2" "and so is the second"

title_record sess-a "release prep"
prompt sess-a
assert_equal "release-prep" "$(ab sess-a name)" "renaming again is followed"
out=$(ab sess-other whois)
assert_contains "$out" "release-prep/1" \
  "and the subagents are renamed with it — their names are addresses"
assert_not_contains "$out" "agentbus/1" "the stale one is gone"

# ---- a resumed chat keeps the name its human gave it ------------------------
#
# SessionStart used to overwrite the title unconditionally, because it tested a
# payload field that is never sent. Reopening a chat you had named therefore
# renamed it back.

out=$(start sess-a)
assert_not_contains "$out" "sessionTitle" \
  "a chat that already has a human title is not retitled on resume"
assert_equal "release-prep" "$(ab sess-a name)" "and keeps the name it was given"

# ---- two chats named the same thing -----------------------------------------

TRANSCRIPT_B="$TEST_TMP/chat-b.jsonl"
: > "$TRANSCRIPT_B"
python3 -c "
import json
print(json.dumps({'type': 'custom-title', 'sessionId': 'sess-b',
                  'customTitle': 'release prep'}))" >> "$TRANSCRIPT_B"
ab_hook session-start "$(payload session sid=sess-b "cwd=$REPO" \
  "transcript_path=$TRANSCRIPT_B")" > /dev/null
assert_equal "release-prep#2" "$(ab sess-b name)" \
  "a second chat with the same title gets a distinct address"

# ---- a title that cannot be a name is ignored -------------------------------

title_record sess-a "   ///   "
prompt sess-a
assert_equal "release-prep" "$(ab sess-a name)" \
  "a title with nothing usable in it leaves the name alone"

# ---- accents are folded, not deleted ----------------------------------------
#
# `çöp ünlü ışık` used to come out as `p-nl-k`: whatever happened to be ASCII.

title_record sess-a "Ödeme akışı düzeltmesi"
prompt sess-a
assert_equal "odeme-akisi-duzeltmesi" "$(ab sess-a name)" \
  "a title with diacritics folds to something its owner recognises"

# ---- it costs a tail read, not the whole transcript -------------------------

bulk 6000     # ~2.5MB
title_record sess-a "bigchat"
python3 -c "
import os, time
size = os.path.getsize('$TRANSCRIPT')
import importlib.machinery, importlib.util
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
t0 = time.time()
for _ in range(20):
    got = ab.transcript_title('$TRANSCRIPT')
ms = (time.time() - t0) * 1000 / 20
print('%s %.1f %d' % (got, ms, size))" > "$TEST_TMP/cost"
read -r got ms size < "$TEST_TMP/cost"
assert_equal "bigchat" "$got" "the title is found in a multi-megabyte transcript"
under=$(python3 -c "print('yes' if float('$ms') < 5 else 'no ($ms ms)')")
assert_equal yes "$under" "and reading it costs under 5ms, because only the tail is read"

finish
