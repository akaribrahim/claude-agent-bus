#!/usr/bin/env bash
# Landing: what would happen if the finished work landed on the trunk together.
#
# The thing this answers is the last job the person running several chats was
# still doing by hand — "these two both say they are done, can I put them both on
# main, and what will fight?" — and it answers it with no model in it at all. The
# ledger says what is finished and on which branch; git computes the rest.
#
# Two properties matter more than the wording.
#
#   1. It WRITES NOTHING. Every candidate branch is checked out in a worktree
#      somebody is working in right now. A merge, a checkout, an index refresh or
#      a stash would rewrite files under a running session mid-tool-call, which is
#      the one recovery this project's plan says never to do. The fingerprint
#      check below is over every file in every worktree AND the whole git
#      directory, so an index write or a stray object would fail it.
#   2. It TELLS A CONFLICT FROM A FAILURE. `git merge-tree` exits 1 both for a
#      merge that conflicts and for a ref it cannot resolve. Reporting the second
#      as "nothing conflicts" is the kind of green answer that gets somebody to
#      run a merge.

. "$AB_ROOT/tests/lib.sh"

REPO=$(make_repo landrepo)
printf 'one\ntwo\nthree\n' > "$REPO/shared.py"
printf 'top\nm1\nm2\nm3\nm4\nm5\nbottom\n' > "$REPO/common.py"
printf 'a\n' > "$REPO/api.py"
printf 'b\n' > "$REPO/web.py"
commit_all "$REPO"

API=$(make_worktree "$REPO" landapi feat-api)
WEB=$(make_worktree "$REPO" landweb feat-web)

# Three shapes on purpose, because the interesting answer is the difference
# between them: shared.py, which both branches change in the same place and which
# therefore fights; common.py, which both change at opposite ends and which does
# not; and one file each that nobody else touches. A view that reported "the
# files they both changed" as "the files that conflict" would be right about
# shared.py and wrong about common.py, and with only shared.py in the fixture the
# two lists are the same list and nothing can tell them apart.
printf 'ONE\ntwo\nthree\n' > "$API/shared.py"
printf 'TOP\nm1\nm2\nm3\nm4\nm5\nbottom\n' > "$API/common.py"
printf 'aa\n' > "$API/api.py"
commit_all "$API"
printf 'uno\ntwo\nthree\n' > "$WEB/shared.py"
printf 'top\nm1\nm2\nm3\nm4\nm5\nBOTTOM\n' > "$WEB/common.py"
printf 'bb\n' > "$WEB/web.py"
commit_all "$WEB"

new_session sess-api "$API"
new_session sess-web "$WEB"
A=$(ab sess-api name)
B=$(ab sess-web name)

view() {   # <python expression over `v` (the landing view for this repo)>
  python3 -c "
import importlib.machinery, importlib.util, json, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
sessions = ab.load_sessions()
me = [s for s in sessions if s['sid'] == 'sess-api'][0]
v = ab.merge_view(me['repo_key'], sessions, me['root'])
def cand(branch):
    return [c for c in v['candidates'] if c['branch'] == branch][0]
def pair(a, b):
    return [p for p in v['pairs'] if p['a'] == a and p['b'] == b][0]
def why(tid):
    return [s for s in v['skipped'] if s['id'] == tid][0]['why']
print($1)"
}

# ---- nothing is finished, so nothing is ready --------------------------------
#
# A view that reported a candidate here would be reporting a branch on which
# nobody has declared anything done, which is every branch anybody is working on.

ab sess-api take "rewrite the api loader" > /dev/null
assert_equal 0 "$(view 'len(v["candidates"])')" \
  "work that is merely open is not a landing candidate"
assert_contains "$(ab sess-api merges)" "nothing is ready to land on main" \
  "and the verb says so plainly rather than printing an empty table"

# ---- finished work, on a branch that is ahead --------------------------------

ab sess-api done --note "loader rewritten" > /dev/null
assert_equal 1 "$(view 'len(v["candidates"])')" "a finished task makes its branch a candidate"
assert_equal main "$(view 'v["trunk"]')" \
  "counted against the branch the repository itself calls default"
assert_equal 1 "$(view 'cand("feat-api")["ahead"]')" \
  "with the commits that branch has and the trunk does not"
assert_equal 0 "$(view 'cand("feat-api")["behind"]')" "and how far behind it is"
assert_equal 3 "$(view 'cand("feat-api")["files_n"]')" \
  "and the files the branch changed since it left the trunk"
assert_contains "$(view 'json.dumps(cand("feat-api")["files"])')" "api.py" \
  "named as the repository sees them"
assert_equal clean "$(view 'cand("feat-api")["onto"]')" \
  "and whether it merges into the trunk cleanly"
assert_equal t1 "$(view 'cand("feat-api")["tasks"][0]["id"]')" \
  "the task that declared it finished is named"
assert_equal "loader rewritten" "$(view 'cand("feat-api")["tasks"][0]["note"]')" \
  "with the note its author left"
assert_equal "$A" "$(view 'cand("feat-api")["tasks"][0]["agent"]')" "and who they are"

# The candidate is a BRANCH, not a task: two finished tasks on one branch land
# together whether anybody meant them to or not, so a view organised by task
# would offer a choice that does not exist.
ab sess-api take "tidy the api tests" > /dev/null
ab sess-api done t2 > /dev/null
assert_equal 1 "$(view 'len(v["candidates"])')" \
  "two finished tasks on one branch are one candidate, because one merge lands both"
assert_equal 2 "$(view 'len(cand("feat-api")["tasks"])')" "and both are named under it"

# ---- two branches, and what actually conflicts -------------------------------

ab sess-web take "restyle the web templates" > /dev/null
ab sess-web done --note "templates done" > /dev/null
assert_equal 2 "$(view 'len(v["candidates"])')" "the other chat's finished branch joins it"
assert_equal 1 "$(view 'len(v["pairs"])')" "and the pair is compared"
assert_equal conflict "$(view 'pair("feat-api", "feat-web")["state"]')" \
  "two branches that changed one line both ways are reported as conflicting"
assert_equal shared.py "$(view '" ".join(pair("feat-api", "feat-web")["conflicts"])')" \
  "naming the file that would actually fight, not every file they both touched"
assert_equal "common.py shared.py" \
  "$(view '" ".join(pair("feat-api", "feat-web")["both"])')" \
  "which is the shorter list: they both changed common.py too, and it merges"

text=$(ab sess-api merges)
assert_contains "$text" "2 branches ready to land on main" "the verb counts them"
assert_contains "$text" "feat-api and feat-web CONFLICT in shared.py" \
  "and says which two would fight, and over what"
assert_contains "$text" "merges into main cleanly" \
  "while still saying each one is fine against the trunk on its own"
assert_contains "$text" "restyle the web templates" "with the sentence its author wrote"

# A pair that touches the same file and merges anyway is a different answer from a
# pair that conflicts, and collapsing the two is what the write-log clash on the
# board already does. This is the half that needs git.
printf 'one\ntwo\nthree\nfour\n' > "$WEB/shared.py"
printf 'ONE\ntwo\nthree\n' > "$API/shared.py"
commit_all "$WEB"
assert_equal clean "$(view 'pair("feat-api", "feat-web")["state"]')" \
  "two branches editing opposite ends of one file do not conflict"
assert_equal "common.py shared.py" \
  "$(view '" ".join(pair("feat-api", "feat-web")["both"])')" \
  "and are still reported as having both touched it"
assert_contains "$(ab sess-api merges)" \
  "both touch common.py, shared.py — and merge cleanly" \
  "which the text states as the distinct thing it is"

# Put the conflict back, because the checks further down are about a repository
# where two branches really do fight. Both branches now add a fourth line and
# they disagree about what it says.
printf 'ONE\ntwo\nthree\nIV\n' > "$API/shared.py"
commit_all "$API"
assert_equal conflict "$(view 'pair("feat-api", "feat-web")["state"]')" \
  "a branch that moves under the preview is re-read rather than remembered"

# ---- uncommitted work is the difference between ready and looks ready --------

assert_equal 0 "$(view 'cand("feat-web")["dirty"] or 0')" \
  "a clean checkout has nothing uncommitted"
printf 'half done\n' > "$WEB/scratch.py"
printf 'edited\n' >> "$WEB/web.py"
assert_equal 2 "$(view 'cand("feat-web")["dirty"]')" \
  "work sitting in the checkout that a merge of the branch would not take is counted"
assert_contains "$(ab sess-api merges)" "(2 uncommitted)" "and said out loud"
rm -f "$WEB/scratch.py"
git -C "$WEB" checkout -q -- web.py

# ---- finished, but not ready -------------------------------------------------
#
# Each of these is a branch somebody could otherwise be told to merge.

# A finished task whose own dependency has not landed. This is the condition the
# comment in `ledger_view` was reaching for, and the one it named — `waiting` —
# is empty for every done task by construction, so filtering on it filters
# nothing.
THIRD=$(make_worktree "$REPO" landthird feat-third)
printf 'c\n' > "$THIRD/third.py"
commit_all "$THIRD"
new_session sess-third "$THIRD"
ab sess-api take "the thing the third one waits for" > /dev/null   # t4, open
ab sess-third take "build on t4" --needs t4 > /dev/null             # t5
ab sess-third done t5 > /dev/null
assert_equal 2 "$(view 'len(v["candidates"])')" \
  "a branch whose finished task is still waiting on unfinished work is held back"
assert_contains "$(view 'why("t5")')" "t4 to land" \
  "and the reason names what it is waiting for"
assert_contains "$(ab sess-api merges)" "Finished, but not ready" \
  "which the verb prints under its own heading rather than hiding"
ab sess-api done t4 > /dev/null
assert_equal 3 "$(view 'len(v["candidates"])')" \
  "and it becomes a candidate the moment that lands"

# A finished task on a branch with nothing the trunk does not already have.
FOURTH=$(make_worktree "$REPO" landfourth feat-fourth)
new_session sess-fourth "$FOURTH"
ab sess-fourth take "read the docs" > /dev/null
ab sess-fourth done > /dev/null
assert_contains "$(view 'why("t6")')" "nothing on it that main does not have" \
  "a branch with no commits of its own is not something to merge"
assert_equal 3 "$(view 'len(v["candidates"])')" "and is not offered as one"

# A branch that has been deleted since the work was declared finished. The task
# stays in the ledger on purpose — it is the record that the work happened — but
# there is no longer anything to merge.
end_session sess-third
git -C "$REPO" worktree remove --force "$THIRD" > /dev/null 2>&1
git -C "$REPO" branch -D feat-third > /dev/null 2>&1
assert_contains "$(view 'why("t5")')" "that branch is gone" \
  "work whose branch has been deleted says so instead of being merged"
assert_equal 2 "$(view 'len(v["candidates"])')" "and is not a candidate"

# ---- everything below happens inside one read-only window -------------------
#
# The strongest form of the claim: every file in every worktree of the repository
# and every file in the git directory, byte for byte, across every route into this
# code — the verb, the module, the merge-tree probe and two board polls. An index
# refresh, a stash, a ref, a reflog line or one unreferenced object from
# `merge-tree --write-tree` would all fail it.
#
# The fingerprint is taken here, before any of them, and compared after all of
# them. Taking it later is how this assertion first passed while measuring
# nothing: the three-way probe below was calling `merge_tree` without the
# redirected object directory, so it wrote two objects into the real store — and
# a baseline taken afterwards happily agreed with itself.
#
# The commit below is the second half of the same lesson. Everything above has
# already asked for these merges several times, so with the redirection removed
# their objects were in the store BEFORE the baseline and the comparison still
# agreed with itself. Moving a branch first means every merge computed inside the
# window is one nothing has computed before, so a write has somewhere new to show
# up. Nothing is committed between here and the comparison.
printf 'fresh\n' > "$API/fresh.py"
commit_all "$API"

# And the third half. `dirty_count` runs `git status` in somebody else's checkout,
# which refreshes the index as it goes — a write to a file a running session is
# using. `--no-optional-locks` is what stops it, but git only rewrites the index
# when its stat cache has gone stale, so in a fixture nothing has touched, a
# `status` with the flag removed writes nothing either and the check below passes
# for the wrong reason. `touch` makes the cache stale without changing a byte of
# content, which is exactly the state a session being worked in is always in.
find "$API" "$WEB" -name '*.py' -exec touch {} +

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
before=$(tree_print "$REPO" "$API" "$WEB")

# ---- a failed comparison is not a clean one ---------------------------------
#
# `git merge-tree` exits 1 for a conflicted merge AND for a ref it cannot
# resolve. The two must never come out the same: "nothing conflicts" about a
# branch that does not exist is what gets somebody to run a merge.

probe() {   # <python expression over `mt` (merge_tree, as production calls it)>
  python3 -c "
import importlib.machinery, importlib.util, os, shutil
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
env, scratch = ab.read_only_git_env('$REPO')
def mt(a, b):
    return ab.merge_tree('$REPO', a, b, env)
try:
    print($1)
finally:
    shutil.rmtree(scratch, ignore_errors=True)"
}
assert_equal clean "$(probe 'mt("main", "feat-api")[0]')" \
  "a merge that works is clean"
assert_equal conflict "$(probe 'mt("feat-api", "feat-web")[0]')" \
  "a merge that fights is a conflict"
assert_equal unknown "$(probe 'mt("feat-api", "no-such-branch")[0]')" \
  "and a ref git cannot resolve is neither, however similar its exit code"
assert_contains "$(probe 'mt("feat-api", "no-such-branch")[2]')" "not something we can merge" \
  "with git's own reason for it carried through"

# ---- the board shows it, and pays nothing on the poll ------------------------

board() {   # <expression over `d` and `land`> [warm]
  python3 -c "
import importlib.machinery, importlib.util, json, os, time
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
d = ab.board_state()
if '$2' == 'warm':
    for _ in range(200):
        d = ab.board_state()
        if d['landing']:
            break
        time.sleep(0.05)
def land():
    return d['landing'][0]
print($1)"
}

assert_equal 0 "$(board 'len(d["landing"])')" \
  "the first poll of a fresh board runs no merge-tree and says nothing yet"
assert_equal 2 "$(board 'len(land()["candidates"])' warm)" \
  "a later poll has the candidates, computed off the request path"
assert_equal conflict "$(board 'land()["pairs"][0]["state"]' warm)" \
  "and what would conflict between them"

view 'len(v["candidates"])' > /dev/null
ab sess-api merges > /dev/null
board 'len(d["landing"])' warm > /dev/null
assert_equal "$before" "$(tree_print "$REPO" "$API" "$WEB")" \
  "none of that changed one byte in any worktree or in the git directory"

# ---- and the redirection is what makes that true ----------------------------
#
# The outcome above would also hold if `merge_tree` were never reached at all, so
# the mechanism is asserted separately: the objects a preview merge produces go to
# a throwaway directory, they really arrive there, and without the redirection the
# same call really would write into the repository. The last of the three is
# measured on a repository of its own, so proving it does not spoil the one the
# check above is about.

env_check() {
  python3 -c "
import importlib.machinery, importlib.util, os, shutil
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
env, scratch = ab.read_only_git_env('$REPO')
try:
    print($1)
finally:
    shutil.rmtree(scratch, ignore_errors=True)"
}
assert_contains "$(env_check 'env["GIT_OBJECT_DIRECTORY"]')" "agentbus-preview-" \
  "the objects a preview merge produces are written to a throwaway directory"
assert_contains "$(env_check 'env["GIT_ALTERNATE_OBJECT_DIRECTORIES"]')" "objects" \
  "with the repository's real object store readable as an alternate"
assert_equal True "$(env_check 'os.path.isdir(env["GIT_OBJECT_DIRECTORY"])')" \
  "and the directory exists, or git would fall back to the real one"

# A conflicted merge, on a repository nothing else in this file touches, counted
# both ways. A clean merge of an already-merged pair writes nothing at all and
# would let both halves of this pass by doing nothing.
PROOF=$(make_repo landproof)
printf 'one\ntwo\nthree\n' > "$PROOF/s.py"
commit_all "$PROOF"
git -C "$PROOF" branch left > /dev/null 2>&1
git -C "$PROOF" branch right > /dev/null 2>&1
git -C "$PROOF" checkout -q left
printf 'LEFT\ntwo\nthree\n' > "$PROOF/s.py"
commit_all "$PROOF"
git -C "$PROOF" checkout -q right
printf 'RIGHT\ntwo\nthree\n' > "$PROOF/s.py"
commit_all "$PROOF"
git -C "$PROOF" checkout -q main

counts=$(python3 -c "
import importlib.machinery, importlib.util, os, shutil
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
store = os.path.join('$PROOF', '.git', 'objects')
def files(d):
    n = 0
    for _b, _d, names in os.walk(d):
        n += len(names)
    return n
env, scratch = ab.read_only_git_env('$PROOF')
try:
    was = files(store)
    ab.merge_tree('$PROOF', 'left', 'right', env)
    print(files(env['GIT_OBJECT_DIRECTORY']), files(store) - was, end=' ')
finally:
    shutil.rmtree(scratch, ignore_errors=True)
was = files(store)
ab.merge_tree('$PROOF', 'left', 'right', None)
print(files(store) - was)")
set -- $counts
if [ "${1:-0}" -gt 0 ]; then
  _ok "a conflicted preview merge really does write objects — $1 of them, diverted"
else
  _bad "a conflicted preview merge really does write objects" \
    "nothing arrived in the redirected object directory"
fi
assert_equal 0 "${2:-?}" "and none of them reach the repository's own object store"
if [ "${3:-0}" -gt 0 ]; then
  _ok "while the same call without the redirection writes $3 into it, which is the point"
else
  _bad "while the same call without the redirection writes into it" \
    "the unredirected call wrote nothing either, so the redirection proves nothing"
fi

# ---- the page draws it, and offers no way to spend money ---------------------

html=$(python3 -c "
import importlib.machinery, importlib.util, os
os.environ['AGENTBUS_HOME'] = '$AGENTBUS_HOME'
ldr = importlib.machinery.SourceFileLoader('ab', '$AB_ROOT/bin/agentbus')
ab = importlib.util.module_from_spec(importlib.util.spec_from_loader('ab', ldr))
ldr.exec_module(ab)
print(ab.BOARD_HTML)")
assert_contains "$html" 'id="landing"' "the page has somewhere to draw the landing view"
assert_contains "$html" "b.onto_conflicts" "and reads what would conflict with the trunk"
assert_contains "$html" "b.dirty" "and the uncommitted work sitting in a checkout"
assert_contains "$html" "d.landing" "from the snapshot rather than computing anything"
# The page must not be able to spend money. Not a stylistic point: a control that
# starts a paid session when it is clicked is a different kind of object from a
# window that only watches, and the board is the second one.
assert_not_contains "$html" "onclick=\"integrate" "no control on the page starts an integration"
assert_not_contains "$html" 'method: "POST"' "the page sends nothing back to the server"
assert_not_contains "$html" "XMLHttpRequest" "and asks for nothing except its own snapshot"

# ---- and it draws when it is actually run ------------------------------------
#
# Everything above is a search of the source, and a search cannot tell a field
# that is drawn from a field that is merely mentioned: a `fillLand` whose body
# never runs still contains every name a grep would look for. This repository has
# also already shipped a page that returned HTTP 200 with a script that did not
# parse, rendering nothing at all, and no assertion in the suite noticed.

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
  _bad "the board serves the page the landing view is drawn on" \
    "$(cat "$TEST_TMP/board.out")"
else
  req() {   # <path> [<method>] → "<status> <body>"
    python3 -c "
import sys, urllib.error, urllib.request
r = urllib.request.Request('$url' + sys.argv[1], method=sys.argv[2])
if sys.argv[2] != 'GET':
    r.data = b''
try:
    got = urllib.request.urlopen(r, timeout=10)
    print(got.status, got.read().decode('utf-8', 'replace'))
except urllib.error.HTTPError as e:
    print(e.code, '')" "$1" "${2:-GET}"
  }
  # The one that matters for a page that must not be able to spend money: there
  # is no way to send it an instruction at all. Asserted on the server's answer
  # rather than on the absence of a `do_POST` in the source, because a handler
  # somebody adds later is exactly what this is here to notice.
  assert_contains "$(req / POST)" "501" "the board refuses a POST outright"
  assert_contains "$(req / PUT)" "501" "and a PUT, so nothing can be asked of it"

  # The landing view is computed off the poll, so the first request may not have
  # it yet. This is the same wait the test's own board helper does.
  body=""
  for _ in $(seq 40); do
    body=$(req /data)
    case "$body" in *'"candidates": [{'*|*'"candidates":[{'*) break ;; esac
    sleep 0.25
  done
  assert_contains "$body" "200" "the data endpoint answers"
  assert_contains "$body" "feat-api" "with the candidate branches in it"
  printf '%s' "$body" | sed '1s/^200 //' > "$TEST_TMP/data.json"

  req / | sed '1s/^200 //' > "$TEST_TMP/page.html"
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
    if out=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/board.js" \
                  "$TEST_TMP/data.json" 2>&1); then
      _ok "the page renders the landing section when it is actually run"
      rows=$(printf '%s\n' "$out" | grep '^LANDING ' || true)
      assert_contains "$rows" "feat-api" "drawing a row per candidate branch"
      assert_contains "$rows" "feat-web | +2" "with how far ahead of the trunk it is"
      assert_contains "$rows" "| clean |" "and whether it lands on the trunk cleanly"
      assert_contains "$rows" "rewrite the api loader" \
        "and the finished work that made it a candidate"
      assert_contains "$rows" "CONFLICT in shared.py" \
        "and, between two of them, the file that would actually fight"
      assert_contains "$rows" "→ main" "under the repository and the trunk it would land on"
      assert_contains "$rows" "agentbus integrate --yes" \
        "with the command printed for the human to run"
      # Finished, and still not on the list. Without this the reader is left with
      # "I marked that done, so where is it" and the page has no answer — the
      # verb has printed it under its own heading since 2.6.0 and the page did
      # not draw it at all.
      assert_contains "$rows" "not ready: nothing on it that main does not have" \
        "and the finished work that is not a candidate, with the reason"
      # Printed as text on a row, not wired to anything. A row that could start a
      # paid session is the thing this section must never become.
      assert_not_contains "$rows" "[button" "and nothing on it is a control"
    else
      _bad "the page renders the landing section when it is actually run" "$out"
    fi
  else
    _ok "and it parses as JavaScript (skipped: no node on this host)"
    _ok "the page renders the landing section when it is actually run (skipped: no node)"
  fi
fi

kill $BOARD_PID 2>/dev/null
trap - EXIT

finish
