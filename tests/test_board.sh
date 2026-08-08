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

# The stylesheet's comments have to be balanced, and this is not pedantry: this
# file is two thirds prose about why each rule is the way it is, so an edit that
# leaves a stray `*/` in it is likely rather than exotic — and it happened while
# the packing below was being written. CSS recovers from one by treating
# everything up to the next `{` as a selector, which swallows the rule that
# follows and applies it to nothing. The page still serves 200, the script still
# parses, every assertion in this file still passes, and one whole rule block is
# gone. Nothing else here can see that, because nothing else here reads CSS.
assert_equal "balanced" "$(python3 -c "
import re, sys
css = re.search(r'<style>(.*?)</style>', sys.argv[1], re.S)
if not css:
    print('no stylesheet'); sys.exit()
s, i, depth = css.group(1), 0, 0
while i < len(s):
    if s.startswith('/*', i):
        depth += 1; i += 2
    elif s.startswith('*/', i):
        depth -= 1
        if depth < 0:
            print('stray */ after: ' + s[max(0, i - 50):i].strip()); sys.exit()
        i += 2
    else:
        i += 1
print('balanced' if depth == 0 else 'a comment is never closed')" "$html")" \
  "every comment in the stylesheet opens and closes, so no rule is swallowed"

# The other half of the packing, and the only half a stylesheet-blind harness can
# reach: the attribute the fill writes onto a plot and the attribute the floor
# packs on have to be the same string. Rename one and every assertion about the
# mark still passes while nothing is ever full width again. Both names are read
# out of the page and compared, so this cannot be satisfied by naming either of
# them in a test.
assert_equal same "$(python3 -c "
import re, sys
h = sys.argv[1]
css = set(re.findall(r'\.floor>div\[([a-z][a-z-]*)\]', h))
js = set(re.findall(r'setAttribute\(\"([a-z][a-z-]*)\", \"1\"\)', h))
print('same' if css and js and css == js
      else 'stylesheet packs on %s, the fill writes %s' % (sorted(css), sorted(js)))" \
  "$html")" \
  "the floor packs on the very attribute the fill writes onto a plot"

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

# ---- the shape of the page: a strip of ground per checkout -------------------
#
# The band is the whole claim of this page: whoever stands on one strip shares
# that tree, and the strip is full width with the path on its left because a grid
# of equal cards can say who is live and not who is standing where. So the
# fixture has to carry the case that distinguishes them — one project with
# several agents spread over two checkouts, and another with a single agent —
# because a page that drew one card per agent would satisfy every assertion about
# the agents and none about where they are.
#
# The quiet project is named to sort FIRST alphabetically and LAST by population.
# With both projects one agent each, or with the names the other way round, an
# ordering assertion would pass against a page that never sorted at all.
new_session sess-g "$REPO"
G=$(ab sess-g name)
ab sess-g doing "reading the ledger" > /dev/null
QUIET=$(make_repo alpharepo)
commit_all "$QUIET"
new_session sess-q "$QUIET"
Q=$(ab sess-q name)
assert_equal 1 "$(state 'who("'"$B"'")["guarded"]')" \
  "the snapshot counts the commands a session took a shared resource for"

# ---- a subagent is a party, and carries what a party carries -----------------
#
# It holds locks under its own `agent_id`, it contends with its siblings, and it
# can take work — the whole `same_party` machinery exists for it. On the board it
# was a half-size figure at its parent's feet plus a chip counting them, carrying
# no branch, no checkout and no work, so a subagent holding the simulator was a
# dot. The fixture therefore gives one session TWO subagents with the second in
# the OTHER worktree, because "the checkout it is in" only means anything when
# one of them is somewhere its parent is not.

# A THIRD checkout, and not the one sess-b is standing in: the strips are matched
# by the path written on them, and a subagent whose own path is another strip's
# would put that strip's name inside this one — which is how "they stand on
# separate strips" passes while nobody can tell.
WT3=$(make_worktree "$REPO" boardwt3)
ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$WT3" \
  agent_id=sub-2 agent_type=Explore)" > /dev/null
S1=$(agent_field sess-a sub-1 name)
S2=$(agent_field sess-a sub-2 name)
sa() {   # <subagent name> <python expression over `a`>
  state "(lambda a: $2)([x for x in who('$A')['agents'] if x['name'] == '$1'][0])"
}

assert_equal 2 "$(state 'len(who("'"$A"'")["agents"])')" \
  "both subagents of one session are in the snapshot"
assert_equal Explore "$(sa "$S2" 'a["type"]')" \
  "each with the kind of agent it is"
assert_equal "$WT3" "$(sa "$S2" 'a["root"]')" \
  "and the checkout it is working in, which for this one is not its parent's"
assert_equal "$REPO" "$(sa "$S1" 'a["root"]')" \
  "while its sibling is standing where the session is"
assert_equal boardwt3 "$(sa "$S2" 'a["branch"]')" \
  "with that checkout's branch and not the session's"

# What it holds, from the locks and under its own id. Taken through the guard,
# because that is the only path that knows which party ran the command.
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$WT3" agent_id=sub-2 \
  "cmd=psql -c 'select 1'" id=sub-db)" > /dev/null
assert_equal db "$(sa "$S2" 'a["holds"]')" \
  "a lock a subagent took is drawn on the subagent, not lumped onto the session"
assert_equal "" "$(sa "$S1" 'a["holds"]')" \
  "and its sibling, which took nothing, holds nothing"
assert_equal "$S2" "$(state '[l for l in d["locks"] if l["resource"] == "db"][0]["agent"]')" \
  "and the lock itself names the subagent, not the session it belongs to"

# And the work it declared. `sid` alone cannot route this: it is the parent's sid
# too, so the ledger has to say which party.
ab sess-a take "migrate the ticket table" --as "$S2" > /dev/null
assert_equal sub-2 "$(state '[t for t in d["tasks"] if "ticket table" in t["what"]][0]["agent_id"]')" \
  "work a subagent took names the party that took it, not only its session"

# ---- what it last actually did ----------------------------------------------
#
# Derived from the tool calls the hooks already see, rather than asked of the
# agents. One `agentbus doing` call is 72 ms of engine, but the cost that matters
# is a tool call a minute per agent, its round trip, and the agent's own context
# filling with status reports — and on the live bus one agent in six used `take`
# at all. So the fast path writes one line per party and the board reads it.

ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=cd $WT2 && python -m pytest tests -q" id=did-1)" > /dev/null
assert_file "$AGENTBUS_HOME/acted/sess-b" \
  "the fast path records what a session last did"
assert_equal Bash "$(state 'who("'"$B"'")["did"]["tool"]')" \
  "which the board reads back as the tool that was called"
assert_equal "python -m pytest tests -q" "$(state 'who("'"$B"'")["did"]["what"]')" \
  "and the command, with the cd into the checkout the strip above already names"
assert_equal True "$(state 'd["now"] - who("'"$B"'")["did"]["at"] < 30')" \
  "timed by the file's own mtime, so the fast path spends no date subprocess"

# An edit, said the way the repository says it: the row is standing on a strip
# that already gives the checkout, and the absolute path was 100 characters of
# worktree before the filename.
ab_hook pre-tool "$(payload file sid=sess-b "cwd=$WT2" tool=Edit \
  "path=$WT2/api/routes.py")" > /dev/null
assert_equal api/routes.py "$(state 'who("'"$B"'")["did"]["what"]')" \
  "an edited path is drawn relative to the checkout, not absolutely"
assert_equal Edit "$(state 'who("'"$B"'")["did"]["tool"]')" \
  "and the tool that did it is the tool the board says"
assert_equal "" "$(state 'who("'"$B"'")["did"]["where"]')" \
  "and nothing says where it is, because the strip it is drawn on says that"

# ---- and where the file is, when it is NOT in the checkout -------------------
#
# `~/.claude` is Claude Code's own storage and not the work. An agent editing its
# own memory file under `~/.claude/projects/<flattened-path>/memory/` is doing
# something real, and it was drawn exactly the way a source file is: the headline
# was sixty characters of machine-flattened project path with the filename cut
# off the end of it. That segment is the project's own root with the separators
# swapped — the fact the strip's heading already carries — so it goes, and what
# KIND of place the file is in is said in words instead. The whole path is still
# in the title, so nothing is lost, only moved.
ab_hook pre-tool "$(payload file sid=sess-b "cwd=$WT2" tool=Edit \
  "path=$HOME/.claude/projects/-Users-someone-shopfront/memory/basket-plan.md")" \
  > /dev/null
assert_equal "projects/…/memory/basket-plan.md" \
  "$(state 'who("'"$B"'")["did"]["what"]')" \
  "a file in Claude Code's own storage loses the flattened project path"
assert_equal "in ~/.claude" "$(state 'who("'"$B"'")["did"]["where"]')" \
  "and says which kind of place it is in, so a cut path is not read as the repo's"
# Only a segment that really is a flattened path, and only directly under
# `projects/`. A directory somebody named themselves is not noise.
ab_hook pre-tool "$(payload file sid=sess-b "cwd=$WT2" tool=Edit \
  "path=$HOME/.claude/projects/named-by-hand/notes.md")" > /dev/null
assert_equal "projects/named-by-hand/notes.md" \
  "$(state 'who("'"$B"'")["did"]["what"]')" \
  "while a directory that is not a flattened path is left exactly as it is"
# Somewhere else entirely: still a fact, still said, and still marked as being
# outside the tree this figure is standing on.
ab_hook pre-tool "$(payload file sid=sess-b "cwd=$WT2" tool=Edit \
  "path=$HOME/notaproject/lib.py")" > /dev/null
assert_equal "~/notaproject/lib.py" "$(state 'who("'"$B"'")["did"]["what"]')" \
  "a path in neither the checkout nor the harness keeps its own shape"
assert_equal "outside this checkout" \
  "$(state 'who("'"$B"'")["did"]["where"]')" \
  "and is marked as being outside the checkout rather than passed off as in it"
# A command has no `where` at all: it ran in the checkout by construction.
ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=make check" id=did-w)" > /dev/null
assert_equal "" "$(state 'who("'"$B"'")["did"]["where"]')" \
  "a command is never marked, because a command ran where the session is"

# Nothing is cut to a character count here any more. The board cuts this line to
# the width of the cell it is drawn in, which is a length this side cannot know,
# and a second cut upstream only took the end the board was keeping: at 96
# characters from the right, a path lost its filename. So the whole line arrives,
# and the title on the page is the whole line.
LONGCMD="npm run build --workspace @shop/checkout -- --minify --sourcemap --target es2019 --outdir dist/checkout"
ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" "cmd=$LONGCMD" id=did-l)" \
  > /dev/null
assert_equal "$LONGCMD" "$(state 'who("'"$B"'")["did"]["what"]')" \
  "a long command reaches the page whole, to be cut where its width is known"

# One line per party, overwritten. Not a log: nothing on the bus may grow with
# how long the machine has been up.
assert_equal 1 "$(wc -l < "$AGENTBUS_HOME/acted/sess-b" | tr -d ' ')" \
  "the line is overwritten and never appended to"

# And read-only extends to it. The line is the fast path's; a window that
# refreshes by itself must not so much as touch its mtime, which IS its
# timestamp — a poll that did would keep resetting every agent's "4s ago" to now.
stamp() { python3 -c "
import os
print(os.path.getmtime('$AGENTBUS_HOME/acted/sess-b'))"; }
was=$(stamp)
state 'len(d["sessions"])' > /dev/null
state 'len(d["sessions"])' > /dev/null
assert_equal "$was" "$(stamp)" \
  "and polling the board leaves it exactly as the fast path wrote it"

# Subagents too, which is what fills the tree rows above with something live.
# The parent is given a line of its own first, so that "the sibling has none"
# means the sibling's own and not merely that nothing has been recorded anywhere.
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$REPO" \
  "cmd=git log --oneline -3" id=did-2a)" > /dev/null
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$WT3" agent_id=sub-2 \
  "cmd=alembic upgrade head" id=did-2)" > /dev/null
assert_equal "alembic upgrade head" "$(sa "$S2" 'a["did"]["what"]')" \
  "a subagent's own last action is recorded against the subagent"
assert_equal None "$(sa "$S1" 'a["did"]')" \
  "and the sibling that has run nothing has no line, rather than its parent's"
assert_equal "git log --oneline -3" "$(state 'who("'"$A"'")["did"]["what"]')" \
  "nor is the subagent's command attributed to the session it belongs to"

# A command the guard has no interest in still gets a line: the tool call that
# matters most to somebody watching the board is usually the one that needed no
# coordination at all, so the write happens BEFORE the gates that decide whether
# the engine is worth waking.
#
# That it does not wake the engine is asserted in tests/test_pyhook.sh, against a
# stub engine that records being run — and of both entry points. Asserting it
# here off the event sequence would measure nothing: a non-guarded command emits
# no event whether the engine ran or not.
rm -f "$AGENTBUS_HOME/acted/sess-b"
out=$(ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=echo nothing here matches a guard" id=did-3)")
assert_empty "$out" "recording it says nothing to the session"
assert_file "$AGENTBUS_HOME/acted/sess-b" \
  "and a command no guard cares about still gets its line"

# Bounded by the party going away, and swept for the party that never got to
# say goodbye — a session killed with -9 fires no SessionEnd.
ab_hook subagent-stop "$(payload subagent-stop sid=sess-a "cwd=$WT3" \
  agent_id=sub-2)" > /dev/null
assert_no_file "$AGENTBUS_HOME/acted/sess-a__sub-2" \
  "a subagent that stops takes its line with it"
printf 'Bash who-is-this\n' > "$AGENTBUS_HOME/acted/sess-nobody"
ab sess-a status > /dev/null
assert_no_file "$AGENTBUS_HOME/acted/sess-nobody" \
  "and a line left by a party nobody knows is swept, so the directory is bounded"

# An id that may not become a filename gets no line at all, and neither entry
# point may be talked into following one out of the directory. Asserted in
# tests/test_pyhook.sh, where the engine is a stub that writes nothing: an
# unsanitised session id is ALSO a filename to the engine — `cursors/../escape`
# is the same file as `acted/../escape` — so here the engine's own write would
# land on top of the fast path's and the assertion could not fail.

# Put the second subagent back: the drawing assertions below are about a session
# with two of them, one somewhere else.
ab_hook subagent-start "$(payload subagent-start sid=sess-a "cwd=$WT3" \
  agent_id=sub-2 agent_type=Explore)" > /dev/null
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$WT3" agent_id=sub-2 \
  "cmd=psql -c 'select 1'" id=sub-db2)" > /dev/null
ab_hook pre-tool "$(payload bash sid=sess-a "cwd=$WT3" agent_id=sub-2 \
  "cmd=alembic upgrade head" id=did-5)" > /dev/null
ab_hook pre-tool "$(payload file sid=sess-a "cwd=$REPO" agent_id=sub-1 \
  tool=Edit "path=$REPO/api/basket.py")" > /dev/null
ab_hook pre-tool "$(payload bash sid=sess-b "cwd=$WT2" \
  "cmd=cd $WT2 && python -m pytest tests -q" id=did-6)" > /dev/null

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

  # ---- and then it is RUN, against the data it just served ------------------
  #
  # Everything above about the page is a search of its source, and a search
  # cannot tell a band that is drawn from a class name that is mentioned. This
  # runs the served script over the served snapshot in the smallest DOM the
  # page's reconciler uses and reads what came out.
  get /data | sed '1s/^200 //' > "$TEST_TMP/data.json"
  get / | sed '1s/^200 //' > "$TEST_TMP/page.html"
  python3 -c "
import re, sys
h = open('$TEST_TMP/page.html').read()
m = re.search(r'<script>(.*?)</script>', h, re.S)
open('$TEST_TMP/board.js', 'w').write(m.group(1) if m else '')
sys.exit(0 if m else 1)" \
    && _ok "the served page carries a script" \
    || _bad "the served page carries a script" "no <script> in the served HTML"

  if ! command -v node > /dev/null 2>&1; then
    _ok "and it parses as JavaScript (skipped: no node on this host)"
    _ok "the page draws its bands when it is run (skipped: no node on this host)"
  else
    if out=$(node --check "$TEST_TMP/board.js" 2>&1); then
      _ok "and it parses as JavaScript"
    else
      _bad "and it parses as JavaScript" "$out"
    fi
    if out=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/board.js" \
                  "$TEST_TMP/data.json" 2>&1); then
      _ok "the page draws its bands when it is run"
      bands=$(printf '%s\n' "$out" | grep '^AGENTS \[band' || true)
      chars=$(printf '%s\n' "$out" | grep '^AGENTS \[\]' || true)
      prjs=$(printf '%s\n' "$out" | grep '^AGENTS \[prj' || true)
      # Who is standing on which strip: the character rows that follow a band
      # line and precede the next one, COUNTED. Searching a strip's text for an
      # agent's name finds it whether that agent is standing there or is only
      # named by somebody else's collision — which is exactly how "they stand on
      # separate strips" passes while they do not. It is what this assertion did
      # twice before it counted rows instead.
      standing() {   # <worktree path> → the characters on that strip
        printf '%s\n' "$out" | awk -v p="$1" '
          /^AGENTS \[band/ { on = index($0, p) > 0; next }
          /^AGENTS \[prj/  { on = 0 }
          on && /^AGENTS \[\] / { print }'
      }
      here=$(printf '%s\n' "$bands" | grep -F "$REPO" || true)
      there=$(printf '%s\n' "$bands" | grep -F "$WT2" || true)
      assert_contains "$here" "$REPO" \
        "a strip of ground per checkout, labelled with the worktree"
      assert_contains "$there" "$WT2" \
        "including the second worktree of the same repository"
      assert_equal 2 "$(standing "$REPO" | grep -c . || true)" \
        "the agents that share a checkout stand on one strip"
      assert_contains "$(standing "$REPO")" "$A" "one of them named there"
      assert_contains "$(standing "$REPO")" "$G" "and the other beside it"
      assert_contains "$here" "2 agents here" \
        "and the strip says how many are standing on it"
      assert_equal 1 "$(standing "$WT2" | grep -c . || true)" \
        "while an agent in another worktree stands on a strip of its own"
      assert_contains "$(printf '%s\n' "$prjs" | head -1)" "$(basename "$REPO")" \
        "the project with the most agents is drawn first"
      assert_contains "$(printf '%s\n' "$prjs" | head -1)" "3 agents · 2 checkouts" \
        "counting its agents and its checkouts"
      assert_contains "$(printf '%s\n' "$prjs" | tail -1)" "$(basename "$QUIET")" \
        "and the single-agent project after it, not in alphabetical order"
      assert_contains "$chars" "wiring the board" \
        "what an agent said it was doing, on the character that said it"
      assert_contains "$chars" "1 claim" \
        "and how many of its commands took a shared resource"

      # The figure is the agent's NAME, hashed — the same face on every reload,
      # in every tab and on the second monitor, with no table to maintain. Asked
      # of the page's own function in the page's own scope, because a test that
      # reimplemented the hash would agree with itself and nothing else.
      cp "$TEST_TMP/board.js" "$TEST_TMP/idprobe.js"
      cat >> "$TEST_TMP/idprobe.js" <<'JS'
console.log("ID " + JSON.stringify([idOf("windlass"), idOf("windlass"),
                                    idOf("halyard")]));
JS
      three=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/idprobe.js" \
                   "$TEST_TMP/data.json" 2>&1 | sed -n 's/^ID //p')
      assert_equal yes "$(python3 -c "
import json, sys
a = json.loads(sys.argv[1])
print('yes' if a[0] == a[1] and a[0]['hue'] is not None else 'no')" "$three")" \
        "one agent's figure is the same figure every time it is drawn"
      assert_equal yes "$(python3 -c "
import json, sys
a = json.loads(sys.argv[1])
print('yes' if a[0] != a[2] else 'no')" "$three")" \
        "and two agents are not drawn as the same figure"

      # ---- the shape of what was built, read out of the built DOM ----------
      #
      # Three things below are structure, not decoration, and each of them is
      # what makes a piece of the layout possible at all:
      #
      #   * a project that CONTAINS its checkouts is what can be drawn as one
      #     bounded thing. As siblings after a heading they cannot be boxed,
      #     which is why five projects read as one long labelled list.
      #   * the worktree path written into an inner run of its own is what lets
      #     the CUT come from the right without the path's leading `~/` being
      #     reordered to the far end. Write the path onto the outer element and
      #     that run is gone — and every assertion about the text still passes
      #     while a short path reads `work/shopfront~/`.
      #   * the chip that names an agent and its checkout hanging on the FIGURE
      #     is the whole of the third fix. It hung on the row, which for a
      #     checkout with one agent in it is the full width of the strip, so the
      #     browser popped it a thousand pixels from the thing it named.
      #
      # What is NOT here, said out loud: one line, cut on the left, and
      # selectable are CSS, and this harness has no stylesheet and no layout. So
      # they are checked by eye in a real browser, and what is asserted here is
      # the DOM each of them stands on — which is what would break silently.
      cp "$TEST_TMP/board.js" "$TEST_TMP/yardprobe.js"
      cat >> "$TEST_TMP/yardprobe.js" <<JS
setTimeout(function(){
 var A = document.getElementById("agents"), out = {boxes: 0, bands: [], tips: []};
 function isFig(n){return n.tag === "svg" && n.className.indexOf("fig") >= 0;}
 function figs(n){var k = 0;
  n.children.forEach(function(c){if(isFig(c)) k++;}); return k;}
 /* Found by walking, at whatever depth they ended up: what each assertion below
    is about has to be able to fail on its own, and a probe that reached the
    strips only through the boxes would make every one of them fail together the
    moment the nesting changed. */
 function walk(n){
  if(n.title) out.tips.push({cls: n.className, t: n.title, figs: figs(n)});
  if(n.c && n.c.path && n.c.floor)
   out.bands.push({path: n.c.path.shownText(), tip: n.c.path.title,
     runs: n.c.path.children.length, floor: n.c.floor.className});
  n.children.forEach(walk);}
 out.boxes = Object.keys(A.__rows || {}).length;
 walk(A);
 console.log("YARD " + JSON.stringify(out));
 /* And again, after a poll in which a chat took a new name — which the live bus
    does whenever somebody renames a session. Same session id and same checkout,
    so the reconciler hands back the SAME row, which is how anything written
    once on the first fill goes on saying the wrong thing forever. */
 function face(n){var a = CHARS[n], f = null, s = "";
  if(!a) return "";
  a.children.forEach(function(c){if(isFig(c)) f = c;});
  if(!f) return "";
  (function dig(x){if(x.className === "shell") s = x.getAttribute("d");
    x.children.forEach(dig);})(f);
  return f.style.getPropertyValue("--h") + " " + s;}
 var was = {t: CHARS["$G"].title, f: face("$G")};
 last.sessions.forEach(function(s){
   if(s.agent === "$G") s.agent = "$G-renamed";});
 render(last);
 console.log("TIP " + JSON.stringify({before: was,
   after: {t: CHARS["$G-renamed"].title, f: face("$G-renamed")}}));
}, 0);
JS
      probed=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/yardprobe.js" \
                    "$TEST_TMP/data.json" 2>&1)
      YARD=$(printf '%s\n' "$probed" | sed -n 's/^YARD //p')
      TIP=$(printf '%s\n' "$probed" | sed -n 's/^TIP //p')
      look() {   # <json> <python expression over `d`>
        python3 -c "
import json, sys
d = json.loads(sys.argv[1])
def band(tail):    # the one strip whose path ends this way
    return [b for b in d['bands'] if b['path'].endswith(tail)][0]
def tip(who):      # the chip that names this agent and its checkout
    return [t for t in d['tips'] if t['t'].startswith(who + ' — ')][0]
print($2)" "$1"
      }

      assert_equal 2 "$(look "$YARD" 'd["boxes"]')" \
        "one bounded container per project at the top of the yard, and nothing else"
      assert_contains "$(printf '%s\n' "$prjs" | head -1)" "$WT2" \
        "with that project's own checkouts drawn inside it"
      assert_not_contains "$(printf '%s\n' "$prjs" | tail -1)" "$WT2" \
        "and the next project's box holding none of them, so the two are separable"
      assert_equal "$WT2" "$(look "$YARD" 'band("boardwt2")["tip"]')" \
        "the untruncated worktree path on the heading that draws it, cut or not"
      assert_equal 1 "$(look "$YARD" 'band("boardwt2")["runs"]')" \
        "written into an inner run of its own, which is what the left-hand cut needs"
      assert_equal art "$(look "$YARD" 'tip("'"$A"'")["cls"]')" \
        "the chip that names an agent and its checkout hangs on the figure's own box"
      assert_equal 1 "$(look "$YARD" 'tip("'"$A"'")["figs"]')" \
        "which is the box holding that one figure, and not the row around it"
      assert_equal 0 "$(look "$YARD" \
        'len([t for t in d["tips"] if t["cls"].split()[0] == "ch"])')" \
        "nothing carries one on the row, which is as wide as the whole strip"
      assert_equal 2 "$(look "$YARD" \
        'len([b for b in d["bands"] if "tied" in b["floor"].split()])')" \
        "and a strip with a collision declares the headroom its arc needs"
      assert_equal "$G-renamed — $REPO" "$(look "$TIP" 'd["after"]["t"]')" \
        "the chip is rewritten every poll, so a renamed session cannot strand it"
      assert_equal no "$(look "$TIP" \
        '"yes" if d["before"]["f"] == d["after"]["f"] else "no"')" \
        "and the figure is redrawn from the new name, because the figure IS the name"

      # ---- the subagent tree, and the live line, read out of the DOM --------
      #
      # A subagent row is INSIDE its parent's row. That containment is what makes
      # the tree a tree, and it is the half of the drawing this harness can see:
      # the indentation, the spine and the elbow are CSS, and there is no
      # stylesheet and no layout here. So what is asserted is the nesting and the
      # TEXT of each row, which is what would break silently; the drawing itself
      # was checked in a real browser at 1500px and at 760px, in both themes.
      #
      # The other half is what the row must NOT have grown. Unread, commits past
      # the trunk and files written are counted per SESSION, so a subagent row
      # carrying any of them would be inventing a fact about the child — and
      # every assertion about what it DOES carry would still pass.
      cp "$TEST_TMP/board.js" "$TEST_TMP/treeprobe.js"
      cat >> "$TEST_TMP/treeprobe.js" <<JS
setTimeout(function(){
 var A = document.getElementById("agents"), out = {kids: [], own: [], row: null};
 function txt(n){return n.shownText().replace(/\s+/g, " ").trim();}
 function walk(n, host){
  /* The plot a character was drawn into holds \`__ch\`; a subagent row carries
     the class. Walked rather than reached through a known path, so that a kid
     that ended up somewhere else is reported as being nowhere. */
  if(n.__ch && n.c && n.c.nm){
   host = n.c.nm.shownText();
   /* The session's OWN blocks. Its printed row necessarily contains everything
      drawn under it, subagents included, so "the parent stopped claiming its
      subagent's work" can only be asked of the parent's own task list. */
   out.own.push({name: host, tasks: Object.keys(n.c.tasks.__rows || {}).length,
     did: n.c.did.visible() ? txt(n.c.did) : ""});
  }
  if(n.className.split(" ").indexOf("kid") >= 0 && n.c)
   out.kids.push({name: n.c.nm.shownText(), under: host, text: txt(n),
     wt: n.c.wt.visible() ? n.c.wt.shownText() : "",
     did: n.c.did.visible() ? txt(n.c.did) : "",
     tasks: Object.keys(n.c.tasks.__rows || {}).length,
     /* The FIGURES in the row, at any depth. Counting the box that holds one
        counts the box: a row whose figure was built and never appended has the
        box and no figure, and every assertion about the box would still pass. */
     figs: (function(k){(function dig(x){
       if(x.tag === "svg" && x.className.indexOf("fig") >= 0) k.n++;
       x.children.forEach(dig);})(n); return k.n;})({n: 0})});
  n.children.forEach(function(c){walk(c, host);});
 }
 walk(A, "");
 /* And the one property the live line has that no string can show: its clock
    reading changes on every poll, so it must be written WITHOUT the highlight,
    or a page left open for hours flashes every two seconds. Polled twice — once
    with time moved on, once with a genuinely new action. */
 var row = null;
 (function find(n){
   if(n.__ch && n.c && n.c.nm.shownText() === "$B") row = n;
   n.children.forEach(find);})(A);
 if(row){
  out.row = {was: row.c.did.c.w.shownText()};
  last.now += 90;
  render(last);
  out.row.when = row.c.did.c.w.shownText();
  out.row.whenCls = row.c.did.c.w.className;
  out.row.whatCls = row.c.did.c.t.className;
  last.sessions.forEach(function(s){
    if(s.agent === "$B") s.did = {tool: "Bash", what: "make check",
                                  at: last.now - 1};});
  render(last);
  out.row.after = row.c.did.c.t.shownText();
  out.row.afterCls = row.c.did.c.t.className;
 }
 console.log("TREE " + JSON.stringify(out));
}, 0);
JS
      TREE=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/treeprobe.js" \
                  "$TEST_TMP/data.json" 2>&1 | sed -n 's/^TREE //p')
      kid() {   # <subagent name> <python expression over `k`>
        python3 -c "
import json, sys
d = json.loads(sys.argv[1])
k = [x for x in d['kids'] if x['name'] == sys.argv[2]][0]
print($2)" "$TREE" "$1"
      }
      assert_equal 2 "$(look "$TREE" 'len(d["kids"])')" \
        "both subagents are drawn as rows of their own, not as dots at the feet"
      assert_equal "$A" "$(kid "$S2" 'k["under"]')" \
        "each one inside the row of the session that started it, which is the tree"
      assert_equal "$A" "$(kid "$S1" 'k["under"]')" \
        "including the sibling, so neither is drawn loose in the yard"
      assert_equal 1 "$(kid "$S2" 'k["figs"]')" \
        "with a figure of its own, hashed from its own name"
      assert_contains "$(kid "$S2" 'k["text"]')" Explore \
        "saying what kind of agent it is"
      assert_contains "$(kid "$S2" 'k["text"]')" running \
        "and how long it has been running"
      assert_contains "$(kid "$S2" 'k["text"]')" "holds db" \
        "and what it is holding under its own id, which was a dot before"
      assert_equal "$WT3" "$(kid "$S2" 'k["wt"]')" \
        "and the checkout it is in, because it is not the one its parent is on"
      assert_equal "" "$(kid "$S1" 'k["wt"]')" \
        "while the sibling sharing its parent's checkout does not repeat it"
      assert_contains "$(kid "$S2" 'k["did"]')" "alembic upgrade head" \
        "and what it last actually did, derived from its own tool calls"
      assert_contains "$(kid "$S1" 'k["did"]')" "api/basket.py" \
        "each party's own, and the sibling's is the sibling's"
      assert_equal 1 "$(kid "$S2" 'k["tasks"]')" \
        "and the work it declared, on its row rather than its parent's"
      # The row is SHORT, and must not be padded to look equal.
      for field in "files written" unread "+1"; do
        assert_not_contains "$(kid "$S2" 'k["text"]')" "$field" \
          "a subagent row does not carry \"$field\", which is counted per session"
      done
      own() {   # <agent name> <python expression over `k`>
        python3 -c "
import json, sys
d = json.loads(sys.argv[1])
k = [x for x in d['own'] if x['name'] == sys.argv[2]][0]
print($2)" "$TREE" "$1"
      }
      sess_row=$(printf '%s\n' "$out" | grep '^AGENTS \[\] ' | grep -F "$A" || true)
      assert_contains "$sess_row" "files written" \
        "while the session's own row keeps every field it had"
      assert_equal 0 "$(own "$A" 'k["tasks"]')" \
        "and stops claiming the work its subagent declared"
      assert_contains "$(own "$B" 'k["did"]')" "python -m pytest" \
        "a session's own last action is on the session's row"
      # The twitch: a clock reading that moves on must not highlight anything.
      assert_equal yes "$(python3 -c "
import json, sys
r = json.loads(sys.argv[1])['row']
print('yes' if r and r['when'] != r['was'] and 'ago' in r['when'] else 'no')" \
        "$TREE")" \
        "the live line's clock reading follows the poll"
      assert_equal w "$(look "$TREE" 'd["row"]["whenCls"]')" \
        "and is written without the highlight, so an open tab does not twitch"
      assert_equal tgt "$(look "$TREE" 'd["row"]["whatCls"]')" \
        "nor is the action highlighted when only the clock moved"
      assert_equal "make check" "$(look "$TREE" 'd["row"]["after"]')" \
        "a new action replaces the old one"
      assert_contains "$(look "$TREE" 'd["row"]["afterCls"]')" hit \
        "and that one IS highlighted, because it is the news"

      # ---- how the figures are PACKED onto a strip --------------------------
      #
      # 2.9.0 gave a cell a subagent tree and a derived line of its own, and the
      # rule that a cell with anything to say takes two of the floor's columns
      # stopped holding: an agent with a tree came out twice as tall as the four
      # beside it, and five figures on one strip read as a ragged wall. The rule
      # now is that an agent carrying a BLOCK — a sentence, declared work, or
      # subagents — takes the whole strip and everything short wraps beside it.
      #
      # What this harness can see of that, and what it cannot, said plainly:
      #
      #   * it CAN see which plots are marked as carrying a block, and in which
      #     ORDER they were drawn. Both are DOM, and both are the rule itself.
      #   * it CANNOT see that a marked plot is full width or that an unmarked
      #     one shares a line. There is no stylesheet and no layout here, so a
      #     width has no shadow to assert against. Those were checked in a real
      #     browser at 1500px and at 760px, in both themes, against a payload
      #     with five figures on one strip and one of them carrying a tree.
      #
      # The one that matters most is negative: what an agent last DID is no
      # longer a reason to widen its cell, because that line is one line now. Put
      # it back and every cell on the board becomes a block again, and every
      # positive assertion here would still pass.
      cp "$TEST_TMP/board.js" "$TEST_TMP/packprobe.js"
      cat >> "$TEST_TMP/packprobe.js" <<JS
setTimeout(function(){
 var A = document.getElementById("agents");
 /* Every strip, and the plots standing on it in the order they were drawn. */
 function strips(){
  var fs = [], res = [];
  (function dig(n){
    if(n.c && n.c.path && n.c.floor)
     fs.push({path: n.c.path.shownText(), floor: n.c.floor});
    n.children.forEach(dig);})(A);
  fs.forEach(function(f){
    res.push({path: f.path, cells: f.floor.children.map(function(p){
      return {name: p.c && p.c.nm ? p.c.nm.shownText() : "?",
              block: p.getAttribute("data-block") || ""};})});});
  return res;
 }
 /* Every last-action line, and the box the CUT stands on. The target has to sit
    inside that box: flatten the two and the line can no longer be cut at all,
    and nothing else on the page would notice. */
 var dids = [];
 (function dig(n, host){
   if(n.__ch && n.c && n.c.nm) host = n.c.nm.shownText();
   if(n.className.split(" ").indexOf("kid") >= 0 && n.c)
    host = n.c.nm.shownText();
   if(n.className.split(" ").indexOf("did") >= 0 && n.c)
    dids.push({who: host, cls: n.className, held: n.c.t.parentNode.className,
      tgt: n.c.t.shownText(), title: n.title,
      wh: n.c.wh.visible() ? n.c.wh.shownText() : ""});
   n.children.forEach(function(c){dig(c, host);});})(A, "");
 var out = {before: strips(), dids: dids};
 /* And again, with the agent that said something saying nothing — while writing
    more files than the one beside it, which is the next key the figures are
    sorted by. If the block test is not the FIRST key, this one comes first. */
 last.sessions.forEach(function(s){
   if(s.agent === "$G"){s.doing = ""; s.agents = []; s.wrote_n = 99;}});
 /* A long action, to see what the element keeps as against what is drawn. */
 last.sessions.forEach(function(s){
   if(s.agent === "$B") s.did = {tool: "Bash", what: "$LONGCMD",
     where: "outside this checkout", at: last.now - 2};});
 render(last);
 out.after = strips();
 (function dig(n, host){
   if(n.__ch && n.c && n.c.nm) host = n.c.nm.shownText();
   if(host === "$B" && n.className.split(" ").indexOf("did") >= 0 && n.c)
    out.long = {tgt: n.c.t.shownText(), title: n.title,
      wh: n.c.wh.visible() ? n.c.wh.shownText() : "", cls: n.className};
   n.children.forEach(function(c){dig(c, host);});})(A, "");
 console.log("PACK " + JSON.stringify(out));
}, 0);
JS
      PACK=$(node "$AB_ROOT/tests/board-render.js" "$TEST_TMP/packprobe.js" \
                  "$TEST_TMP/data.json" 2>&1 | sed -n 's/^PACK //p')
      pack() {   # <python expression over `d`, with `cell` and `did` helpers>
        python3 -c "
import json, sys
d = json.loads(sys.argv[1])
def cells(where, tail):     # the plots on the strip whose path ends this way
    return [b for b in d[where] if b['path'].endswith(tail)][0]['cells']
def cell(where, tail, who):
    return [c for c in cells(where, tail) if c['name'] == who][0]
def did(who):
    return [x for x in d['dids'] if x['who'] == who][0]
print($1)" "$PACK"
      }
      assert_equal 1 "$(pack 'cell("before", "'"$(basename "$REPO")"'", "'"$A"'")["block"]')" \
        "an agent with subagents under it and a sentence on it is marked as a block"
      assert_equal "" "$(pack 'cell("before", "boardwt2", "'"$B"'")["block"]')" \
        "while an agent whose only line is what it last did is not, which is what the one-line cut buys back"
      assert_equal "$A $G" "$(pack '" ".join(c["name"] for c in cells("after", "'"$(basename "$REPO")"'"))')" \
        "the figures carrying a block are drawn before the short ones"
      assert_equal "1 " "$(pack '" ".join(c["block"] for c in cells("after", "'"$(basename "$REPO")"'"))')" \
        "which is the same test the packing uses, and not the files-written count"
      assert_equal cut "$(pack 'did("'"$B"'")["held"]')" \
        "the last action's target sits inside the one box that may be cut"
      assert_not_contains "$(pack 'did("'"$B"'")["cls"]')" path \
        "a command is not marked as a path, so its cut comes off the flags at the end"
      assert_contains "$(pack 'did("'"$S1"'")["cls"]')" path \
        "and an edited file is, so its cut comes off the directories and keeps the name"
      assert_equal "" "$(pack 'did("'"$B"'")["wh"]')" \
        "nothing says where a file in this checkout is; the strip above says it"
      assert_equal "$LONGCMD" "$(pack 'd["long"]["tgt"]')" \
        "the element keeps the whole action however narrow the cell, so it copies whole"
      assert_equal "Bash — $LONGCMD outside this checkout" \
        "$(pack 'd["long"]["title"]')" \
        "and the title is the whole of it, cut or not"
      assert_equal "outside this checkout" "$(pack 'd["long"]["wh"]')" \
        "with where the file is in a node of its own, which the cut can never reach"
    else
      _bad "the page draws its bands when it is run" "$out"
    fi
  fi
fi

kill $BOARD_PID 2>/dev/null
trap - EXIT

finish
