# Changelog

What changed for somebody using it, rather than what changed in the source.

## 2.6.0 — 2026-08-05

**"Can these two land together?"** — answered by git, for free, without touching
anything. And, separately and only when you ask for it, a session of agent-bus's
own that actually does the merge.

2.5.0 let the agents say what they had taken and what they were waiting for. What
was still being done by hand was the last step: two chats both say they are
finished, and finding out whether their work can go on the trunk together meant
merging and seeing — which means checking out a branch somebody is working in and
rewriting their files mid-tool-call, the one thing this project's own recovery
notes say never to do.

    agentbus merges

    agent-bus: 2 branches ready to land on main
      feat-api                 +3 commits, 7 files   ~/work/api-wt (2 uncommitted)
          t1   fix the review findings in api/ — dizzy-mole, "all four closed"
          merges into main cleanly
      feat-web                 +1 commit, 4 files    ~/work/web-wt
          t3   rebase web onto main — quiet-fox
          merges into main cleanly

    Between them:
      feat-api and feat-web CONFLICT in api/schema.py

**No model, no cost, no state.** The ledger already knows which work is finished
and on which branch; `git merge-tree` merges two commits in memory and names the
files that would actually fight, with no working tree, no index and no ref
anywhere in the picture. So this is the part that gets used every day, and it is
instant and free.

- **A candidate is a branch, not a task.** Two finished tasks on one branch land
  together whether anybody meant them to or not, so a view organised by task
  would offer a choice that does not exist.
- **"They both touched it" and "it conflicts" are different answers**, and the
  board could only give the first. Two chats editing opposite ends of one file is
  not a problem; the same three lines from both is.
- **Uncommitted work is reported**, because it is the whole difference between
  ready and looks-ready: the branch is ahead and its checkout still holds work a
  merge of the branch would not take.
- **Finished but not ready is said out loud**, with the reason: a branch that has
  been deleted, a branch with nothing on it the trunk does not have, or a task its
  own author called finished while the thing it was built on has not landed. Each
  is a branch somebody would otherwise be told to merge.
- The same view is on the board, read-only and computed off the poll, with the
  command printed as text. **There is deliberately nothing there to press.** A
  control that spends model calls when it is clicked is a different kind of object
  from a window that only watches, and the board is the second one. The page
  refuses a POST outright.

**It writes nothing, and that is asserted rather than asserted-to.**
`merge-tree --write-tree` does put the tree it merged into the object store, so
the object store is redirected as well: the writes land in a temporary directory
that is deleted afterwards. The test fingerprints every file in every worktree
and the whole git directory across every route into this code, with a
deliberately stale stat cache in place first — because `git status` refreshes the
index unless it is told not to, and in a fixture nothing has touched, a `status`
missing that flag writes nothing either and would pass for the wrong reason.

### And then, if you want it done

    agentbus integrate --yes

**One chat cannot make another chat act.** Hooks fire on a session's own
activity, so nothing can put a turn into an idle interactive session; that is a
limit of Claude Code and it is not going away. A session agent-bus *starts
itself* is different, because it was created programmatically. So the shape that
works is not "make those two chats coordinate" — it is "take the work they
finished and have a session of our own put it together".

`integrate` spawns a headless Claude Code session to merge the candidates,
resolve what conflicts, run whatever the repository uses to check itself, and
report. **It prints what it will do and what it will cost, and stops unless you
add `--yes`** — a flag rather than a question, because an agent may run this too
and an agent cannot answer one at a terminal.

Five rails, each in the engine rather than in the prompt, because a prompt is a
request:

- **A scratch worktree it creates and removes**, detached at the trunk. Never
  anybody's checkout, and never `main` in a checkout somebody is using.
- **It cannot push.** Every remote's `pushurl` is overridden in the worker's
  environment. The test measures this by pushing, and by pushing without it.
- **It registers on the bus like any other session**, so the other agents see it
  and the guards apply to it. The environment it is handed has the parent's
  session identity removed and `AGENTBUS_OFF` cleared — with the first it would
  file its writes under the chat that started it, and with the second it would be
  invisible to everything.
- **It cannot close anybody's task.** Not because it is asked not to: a candidate
  is made of tasks whose state is `done`, `done` refuses a task that is not the
  caller's own session's and `take` refuses one that is finished, so there is no
  order of verbs by which another session closes finished work. Saying work is
  done is its author's declaration to make.
- **The spend is capped** with `--max-budget-usd`, which the CLI itself enforces,
  so the ceiling printed before the run is not one this verb has to police.

**Whether it worked is asked of git, not of the worker.** Every branch has to be
an ancestor of what is in the scratch tree and nothing may be left uncommitted.
"I merged them" is a sentence. And a run that does not finish — a real conflict
needing a person, a check that failed — **leaves the half-merged tree and the
worker's own transcript exactly where they are**, because deleting them to keep
the temporary directory tidy throws away the only reason anybody would look.

Tested without a model against a stand-in CLI on PATH that does the merges with
plain git, which covers everything except the model's judgement. What genuinely
needs a real session — that the spawned worker appears in the roster under its own
name — is a new block in `tests/live/acceptance.sh`, where the paid tests live.

Also fixed, and it was measuring nothing: `ledger_view`'s note about a future
merge reader named three conditions, and the third filtered nothing. `waiting` is
only ever recorded against a task that is *not* yet finished, so a done task's
`waiting` is empty by construction and a candidate filtered on it would have
looked careful and measured the empty set. The condition that carries information
is the other direction. And `git_out` threw away the exit code, which is exactly
how `merge-tree` reports whether it conflicted — the reads go through `git_probe`
now, so a ref git cannot resolve is never reported as a merge with nothing to
fight about.

**Cost.** Nothing was added to the path a tool call pays: no hook reads any of
this, and the shell fast path in front of all of it is unchanged at about 5 ms,
which is what most tool calls actually pay. The board's poll runs no git for it
either — the landing view is cached for thirty seconds per repository and computed
in a background thread, the same bargain 2.4.0 made for the commit counts, and for
a heavier reason: a `merge-tree` per pair of branches for as long as a tab is open
is not a cost a window that only watches may impose.

A hook that does wake the engine got 2.7 ms slower, and for the honest reason
rather than an algorithmic one: the engine grew by 842 lines, and a hook is handed
a script rather than an import, so Python recompiles the whole file every time and
is never allowed to cache the result. Measured on this Mac, median of fifteen:
7860 lines compile in 25.8 ms and 8702 in 28.5 ms. The same trade 2.1.0 and 2.5.0
recorded.

## 2.5.0 — 2026-08-04

The agents can now say **what they have taken and what they are waiting for**,
and it goes on the board beside what they are observably doing.

2.4.0 gave the board everything that can be seen from the outside: each
session's branch, how far ahead of the trunk, the files it wrote, which of them
another chat wrote too, and which window is sitting idle on unread messages.
What none of that can show is intent. Two chats fixing review findings in one
repository, told to "coordinate between yourselves and get both of you to
main", both look identical from outside — and which of them is blocked on the
other existed nowhere except in the head of the person watching, who was
carrying messages between chats by hand.

    agentbus take "fix the review findings in api/"          # → t1
    agentbus take "rebase web onto main once api lands" --needs t1
    agentbus done t1 --note "all four findings closed"

**Two lines per piece of work, and nothing else asked for.** Everything a form
would have wanted is worked out from what the bus already records: who took it,
which branch and checkout they are in, the files the task has produced since it
was taken, what its owner is holding, and — from a lock's own `queue` — what
its owner is queued behind. A "blocked by" that the queue already implies is
not declared a second time. The only typed fields are the sentence and, at
most, one task it has to wait for, because nothing on disk can infer either: a
file change is visible and an intention is not, and a dependency between two
pieces of work is not a contention over a resource, so there is no lock to
queue for.

That is deliberate rather than tidy. The reason is in 2.3.0: `AGENTBUS_OFF`
became a reflex, 88 uses in 48 hours of which 76 overrode nothing. A ledger
with six fields to fill in is one nobody fills in on the afternoon it would
have mattered.

- **A task whose chat has gone reads as dropped immediately**, and is *shown*
  rather than deleted. A lock that grants nothing is deleted on sight because
  the resource frees itself; work does not — the branch it was started on is
  still there, and it is exactly what somebody merging is looking for. The
  state is derived from the live session list, so there is no moment in which
  the ledger claims a session that has ended is still working, and no sweep in
  between. `agentbus take t4` picks it up; it is refused off a session that is
  still live, which the refusal says, with the name to ask.
- **`take` and `done` are delivered** to the other sessions in the repository,
  the way a `post` is. That is the point: the person watching stops being the
  router. Finishing something names the agents it unblocked.
- On the board, each task sits **under the session that took it**, so a chat
  that has declared nothing still shows its branch, its files and its
  collisions exactly as before. Work whose chat has gone sits under its
  repository with the branch it was left on. The header counts what is open,
  what is blocked and what was dropped.
- Scoped **per repository**, like a plain `post` and unlike `--all`: two chats
  merging into one trunk is the case, a task graph across projects is not. Ids
  are per repository, which is what keeps them short enough to type.

**Cost.** No work was added to the path a tool call pays: nothing in `PreToolUse`,
`PostToolBatch` or `PostToolUse` reads the ledger. The new housekeeping runs where
session reaping already does — session start, once a turn, session end — and takes
12 microseconds on a machine with no tasks and 213 with a hundred of them. The
shell fast path in front of all of it is unchanged at about 5 ms, and that is what
most tool calls actually pay.

A hook that does wake the engine got about 2.5 ms slower, and for the honest
reason rather than an algorithmic one: the engine grew by 637 lines, and a hook is
handed a script rather than an import, so Python recompiles the whole file every
time and is never allowed to cache the result. Measured separately, those 637
lines cost 2.33 ms to compile — which is the whole of it. The same trade 2.1.0
recorded.

Also fixed, found while checking that: **`AGENTBUS_HOME=` — set and empty — put
the entire bus in whatever directory the caller was standing in.** An empty
variable is not an absent one, and a relative path is what `os.path.join("", …)`
produces. Nothing errored; presence and every guard simply stopped working,
because no other process could find any of it, and a `live-count` and a
`guard-tokens` appeared in a repository to be committed. Both fast paths already
substituted on empty, so the gate was looking in one place while the engine wrote
to another — the same shape as the executable-bit divergence closed in 2.1.0.

## 2.4.0 — 2026-08-04

`agentbus board` answers the two questions that cost time when several chats are
running at once: **what has each session produced, and which window needs
poking.**

Before this it could say who was live and in which checkout. It could not say
that two chats had both edited one file — you found that out during the merge —
and a session sitting idle on messages it had never been shown looked exactly
like one with nothing to do, so every chat got messaged instead of the one that
was waiting.

- Live agents are **grouped by repository**, and each session now shows **how far
  ahead of the trunk** it is, **the files it has written**, and **the ones
  another live session in the same repository has written too**, named as the
  repository sees them so two worktrees line up on one path.
- The default branch is **derived, not assumed** — `origin/HEAD` as the
  repository recorded it, then this machine's `init.defaultBranch`, then a
  conventional name that really exists. A worktree of a repository with no remote
  is counted correctly; one with no commits says so instead of guessing.
- **Idle with unread messages** is now the one thing on the page asking to be
  acted on: the row is tinted and the header counts it. The count is the same one
  that session will be handed at its next turn, not a second opinion.
- The feed draws a **line where you last looked away**. It lives in your browser,
  so the bus stays read-only and two tabs have nothing to fight over.
- The page is **updated in place rather than rebuilt**. It used to replace its own
  DOM every couple of seconds, which killed text selection mid-sentence, closed
  anything you had expanded, and made it impossible to show a change *as* a
  change. Now a value that moves carries a brief highlight and an arriving message
  fades in. Still no CDN, no font, no remote anything — and no value goes onto the
  page as markup any more, so a branch name or a message cannot arrive as HTML.

Counting commits means running git, so the poll does not: the numbers are cached
for ten seconds per checkout, refreshed in the background, and reported as not
yet counted rather than holding the page up. On a machine with five live sessions
in three repositories a poll costs about 11 ms and runs no git at all.

## 2.3.0 — 2026-08-04

Stop announcing a step over the guard that stepped over nothing.

Every `AGENTBUS_OFF=1` put a line on the bus, whether or not it overrode
anything, and that turns out to hide the ones that matter. Counted over 48 hours
on the machine this plugin is developed on: 88 of them, of which **76 — 86 per
cent — would not have matched a single resource.** Agents had learned to write
the prefix by habit; `sleep 30` and `ps ax | grep` were in there. The twelve
real ones were somewhere in that noise, six of them driving the one simulator
the plugin exists to serialise, and the roster is where somebody looking for
them would have looked.

- The announcement now happens only when the command really would have been
  guarded, and it **names what was stepped over** — `ran past the guard on
  'simulator', 'api'` rather than a bare prefix. The escape hatch is still
  recorded, because a guard everybody can step over quietly is not a guard; an
  opt-out that overrode nothing was never a step over the guard at all.
- **`ps`, `pgrep` and `lsof` are read-only.** Asking which processes are running
  is not running them, and `pgrep -f psql` was matching a database and being
  stepped over. `kill` and `pkill` are deliberately still guarded: killing the
  process that serves a resource is the most decisive way of touching it there
  is, and there is now an assertion whose job is to stop that being tidied away.

The opt-out path pays a resource match it used to skip, which is the same work
any guarded command already does.

## 2.2.0 — 2026-08-02

**`agentbus post --all`** reaches every live session on the machine, not just
the ones in your repository.

Presence was already machine-wide and messages were not. `agentbus status`
lists every session in every project, so an agent could see somebody it had no
way to speak to: a plain `post` stopped at the edge of the repository, and
`--to` needed a name you might not have. There was no way to say a thing that
is true of the *machine* — two projects driving the one simulator this plugin
exists to serialise, a machine-wide database being reseeded, a reboot, or this
plugin being replaced under everybody.

That default is still right and is unchanged: another project's chatter does
not arrive, which is what keeps a delivered message worth reading. `--all` is
the deliberate, occasional exception, and it says so — the sender is told how
many sessions will see it and how many of those are in another project, and the
reader is told which project it came from, because a sentence from a codebase
you are not in is noise until you know whose it is.

`--to` and `--all` together are refused rather than guessed at.

Found the way most things in this changelog were found: an agent updating this
plugin posted three times to tell every session on the machine that the engine
underneath them had just changed, read "posted to everyone on this repo" as the
broadcast it is not, and reached nobody at all. Nothing failed and nothing was
logged. The scopes now have a test file of their own — there was none, which is
why that was possible.

## 2.1.0 — 2026-08-02

Make the way out of a block a line you can actually run.

A guard is only as good as its exit. Twelve of this plugin's twenty-two defects
came from two habits: answering "who is acting and where" in thirteen places,
and answering "what does this command touch, and what is it locked under" in
the guard, in five command-line verbs, and a third time in the English of the
block message itself. When those answers disagreed, the tool contradicted
itself — and what a reader saw was advice that ran, reported success, and
changed nothing.

Both questions now have one answer each, and the advice at the bottom of a
block is generated from the same object that decided to block. A message can no
longer advertise a line the guard would refuse, because a message no longer
knows how to write a command down.

**Blocks you could not get out of**

- **A block about one device now names that device.** With a `key` resource,
  the guard locks `simulator@ABC123` while every exit it printed said
  `simulator`. Both of them — the wait and the steal — took a *different* lock
  that nobody was contending for, printed `claimed`, exited 0, and left the
  device exactly where it was. Only `AGENTBUS_OFF=1` ever got anyone past. The
  exits now name the lock that is actually in the way.
- **`agentbus claim <res>@<instance>`** takes one of several outright, and a
  mistyped base is refused instead of quietly writing a lock under the typo —
  which was the same defect one keystroke away.
- **The unidentified-party block's first suggestion works.** It said `agentbus
  claim <res> --as <your name>`; the guard let the line through and the command
  itself then refused it, because naming yourself does not prove an anonymous
  lock is yours. It now says `--as <your name> --steal`, and says why: nobody
  can confirm the claim is yours, so taking it is recorded on the bus as a
  takeover rather than a quiet adoption.

**Commands that reported success and did nothing**

- **`agentbus claim a,b` takes both.** The comma list is the form the guard
  understands and the form this plugin's own advice printed — and `claim`,
  `wait` and `release` all wrote a single lock named literally `a,b` while `a`
  and `b` stayed free. All three take the list now.
- **`agentbus wait` from a shell queues instead of lying.** Typed any way but
  the exact line the guard saw, a wait could not say which agent it was, was
  read as the session itself, and a session never contends with its own
  subagent — so it printed `claimed`, exited 0, and the sibling that had read
  the advice stayed blocked. Worse, it asked for a hard lock, which upgraded
  the sibling's one-command claim in place so that the command ending no longer
  gave it back.
- **`agentbus status` sees a device somebody is holding.** With no command in
  hand it only ever looked for the bare resource, so a resource held under an
  instance was reported as free — on the screen an agent reads before deciding
  whether it needs to wait for anything.
- **`agentbus run <device>`** takes what that device implies, not what happened
  to be typed.

**Saying where you are**

- **`git -C <path>` beats `agentbus here`.** A pin is a statement about where a
  session is working; `git -C` is a statement about one command, and the
  narrower one now wins.
- **`agentbus here --as <name>` sticks.** A session's declaration was protected
  by a flag and a subagent's was protected by a coincidence, so the next hook
  payload could overwrite what an agent had just declared.
- Both fast paths now agree about an engine that has lost its executable bit. A
  checkout in that state used to stop guarding on macOS and go on guarding on
  Windows, which is worse than either answer alone.

**Cost**

A hook that wakes the engine got about 4 ms slower, and the reason is honest
rather than algorithmic: the engine grew from 5800 to 6700 lines, and a hook is
handed a script rather than an import, so Python recompiles the whole file
every time and is never allowed to cache the result. The guard's own work is
still single-digit milliseconds. The shell fast path in front of it is
unchanged at about 5 ms, and it is what most tool calls actually pay.

The test suite went from 932 assertions to 1571, and three of them are
structural: they fail if the two questions above are ever answered in more than
one place again.

## 2.0.0 — 2026-08-02

Stop taking turns on one port. Give each checkout its own.

Counted over everything the bus has ever refused on this machine: 119 of 141
blocks were the same sentence — "that service is serving a different checkout" —
for three resources that could simply have been three services. 87 per cent of
every refusal, and all 107 handovers, existed because two worktrees were sharing
a port they did not have to share.

- **`"ports": "per-worktree"`** on a resource gives every checkout its own,
  derived from the checkout's path — so it is the same every time, with no state
  to lose, and a deleted registry changes nothing. The repository's **original**
  checkout keeps the port the config declares, which is what makes this
  additive: nothing changes for whoever works in the main clone, or for the
  README that names :8082.
- **`agentbus port <res>`** and **`agentbus env`** hand the numbers to a shell.
  `eval "$(agentbus env)"` covers the whole configuration, allocated or not.
- `${PORT}` in `start` and `ready` is substituted; failing that, a literal
  occurrence of the declared port is. A pattern for the new port is added, or a
  command aimed at it would match nothing. And the lock becomes per checkout,
  because two checkouts no longer share the thing being locked.
- **Reaching for another checkout's port is refused.** Isolation removes
  contention and introduces exactly one new way to be silently wrong: an agent
  types the port it read in a README and quietly exercises another tree's code.
  Nothing else would catch it — there is no lock to contend for and no service
  serving the wrong checkout, because everything is behaving as designed. The
  check does not depend on a pattern having matched, because each worktree's
  patterns name only its own port.
- Resources that do not opt in are untouched: a shared database still contends
  machine-wide, which is the point. Isolate what the machine can afford to
  duplicate; keep the bus for what it cannot — one simulator, one Maestro
  driver on port 7001, one staging database, one git index per checkout, and
  everything that was never about contention: presence, messages, the
  interference guard, handoffs.

## 1.9.0 — 2026-08-01

Two places the agents turned the guard off, both of them the tool's fault.

- **`agentbus here` now sticks.** Claude Code returns the shell to the directory
  a chat opened in between tool calls, so a session working in another checkout
  had every payload afterwards saying the old tree — and the bus followed it,
  undoing the declaration on the very next turn. An agent was told it was in a
  checkout it had left, refused services it had started itself, and ran the rest
  of its work with `AGENTBUS_OFF=1`. Saying `here` somewhere else moves it; it is
  a statement, not a cage, and a session that has never said anything is still
  followed.
- **A resource can have more than one of the thing.** Three agents shot a screen
  tour on three simulators, each with its own device, and one `simulator` lock
  serialised work that did not contend at all — so all three ran Maestro with
  the guard off. `"key": "--udid\\s+(\\S+)"` makes that one lock per device.
  A command that names no device contends with every one of them, because not
  knowing which you are about to drive is a reason to wait; and claiming the
  resource itself still covers them all.

## 1.8.0 — 2026-08-01

A guard matches the tool, not the target — and the way out of that did not work.

- **`AGENTBUS_OFF=1 <command>` now does what every block message said it did.**
  It did not: the assignment takes effect in the shell that runs the command,
  and the hook has already decided by then, in another process, with the
  session's own environment. An agent reaching for a staging database in another
  country was queued behind a lock on the local one, read the message, followed
  it exactly, and was refused a second time. It was right and the tool was
  wrong. Taking that exit is now recorded on the bus, so it stays an escape
  hatch rather than becoming a silent bypass.
- **`unless` patterns on a resource.** `patterns` recognise the tool; a `db`
  resource describing your local Postgres matches every `psql` there is. `unless`
  is how the config says which uses are not the guarded thing — a cloud
  hostname, a staging resource group, a throwaway container.
- The block message now offers that fourth way out, and says which of the four
  fits: wait, ask, steal, or "this is not the thing you are guarding".

## 1.7.0 — 2026-07-31

Windows stops paying for a decision it has not made yet.

Measured on the Windows 10 host from the 1.6.0 report: a hook with nothing to do
cost 281 ms, of which 178 ms was spent getting ready to decide there was nothing
to do — reading and compiling five thousand lines, then `import json, re`, then
creating thirteen directories that already existed. POSIX skips all of that in a
5 ms shell script; Windows had no equivalent.

- **`bin/hook.py`** is that fast path in Python. It imports `os` and `sys` and
  nothing else, scans the payload as text rather than parsing it, and makes the
  same decisions in the same order as `bin/ab-hook` — there is a test that puts
  every case through both and compares the answers, because a guard that fires
  on one platform and not the other is worse than one that fires on neither.
- When there **is** work it loads the engine as a *module*. Python writes no
  bytecode cache for a script, so running the engine directly recompiled it on
  every hook: 4 ms against 30 ms here, 71 ms there.
- `ensure_dirs` looks once instead of creating thirteen directories every time.
  74 microseconds here, 12 milliseconds there.
- The measurement script that found this is checked in at
  `tests/perf/hook-cost.py`. Its own "module-level definitions" line was
  mislabelled — that bucket is the engine's `import json, re`, not its own
  definitions, which cost 0.2 ms. Corrected, because a benchmark that names the
  wrong thing sends the fix to the wrong place.

## 1.6.0 — 2026-07-31

First real Windows hardware, and what it found. Two sessions on Windows 10 with
a Turkish locale and an embeddable Python. Most of the product worked first try
— presence, messaging, locks, the ownership guard, `here`, `serves`, renaming —
and the rest is below. Three of the six are not Windows-specific.

- **`agentbus own worktree` protected nothing and said it did.** `own` takes a
  path, `claim` takes a resource; they look identical on a command line. A glob
  with no wildcard means a directory, there is no `worktree` directory, so the
  declaration covered nothing — and it was recorded, `status` printed it under
  "Declared ownership" and "Free: worktree" in the same output, and the session
  told three other agents the checkout was safe. Refused now, pointing at
  `claim`. A glob that matches nothing yet is still allowed — claiming ground
  before you break it is legitimate — but it says so.
- **A marketplace install patched the wrong copy.** The install leaves the
  clone it fetched *and* a versioned copy under `plugins/cache`, and only the
  second is loaded. The installer derived its target from its own location, so
  run from the clone it patched the clone and announced "Claude Code loads it
  from here". On Windows the loaded copy then kept the committed POSIX wiring —
  `bash → ab-hook → python3` against a stub that is not Python — so every hook
  died, no session registered, and both the installer and `doctor` reported
  success because each described the copy it had just touched. Both now find
  every loaded copy; `doctor` names any that is still unwired.
- **A guard could fail open in silence.** A UTF-8 BOM — which PowerShell
  prepends when piping to a native executable — made the payload unparseable,
  and the handler returned nothing, which is byte-identical to "considered this
  and allowed it". Same path for a filename containing a byte undefined in the
  console codepage. Payloads are read as bytes and decoded UTF-8 now, and a
  parse failure says on stderr that the guard was skipped.
- **`git -C <path>` is read as the tree the command is about.** A chat that
  works on another worktree by path never changes directory, so the bus placed
  it in the repository it was launched in for ever — four chats rendered on one
  branch in one worktree while one was somewhere else. It also turns out that
  `git -C x add` matched no pattern anybody writes, because git's global options
  sit between the command and its subcommand: those are stripped before matching
  now, so `git -C <path> checkout` is guarded like any other.
- **Non-ASCII is legible on a Windows console**, and the machine is no longer
  called a Mac in text printed on machines that are not Macs.

## 1.5.0 — 2026-07-31

The two gaps left open, and a third found while closing them.

- **`agentbus claim worktree` protected nothing.** A `scope: "worktree"`
  resource is one lock per checkout, so the guard files it under
  `<name>@<digest>` — and every CLI verb used the bare name, so the two never
  met. `git add` in the same checkout sailed past an explicit claim,
  `agentbus wait` answered "claimed" while the block it was queueing for stood,
  and the deny message's own `--steal` advice was a no-op. `worktree` is the
  resource `init-repo` writes into every repository there is.
- **`agentbus claim 'file:…'` never reached the shell path.** The fast path
  greps an edit against `hot-for`, which held recent writes and declared globs
  but not claimed files — so the block that every file-collision message tells
  you to take was invisible outside Windows. Found by the test written for the
  first fix.
- **`agentbus here`** — a subagent can now say which worktree it is working in.
  Its payloads carry its parent's directory until it changes into its own, and
  no inference can tell that from the truth; one of them turned the plugin off
  with `AGENTBUS_OFF=1` rather than argue with a guard placing it in the wrong
  tree. A cwd equal to the parent's is now treated as the absence of evidence
  rather than as evidence.
- Lock events say `worktree`, not `worktree@3f9c1a`. Nobody typed that.

## 1.4.0 — 2026-07-31

Sessions are called what their humans call them.

- **A session takes the name of its chat.** It used to be named after its
  branch — `feat-login`, or `repo-main` on the trunk, with a `#2` when two
  sessions shared one — because that is all there is to go on at the moment it
  registers. Rename the chat and the bus follows, at the next turn.
- Its **subagents follow with it**: `agentbus/1`, `agentbus/2`. Their names are
  addresses, so leaving them behind would break `agentbus post --to`.
- **A resumed chat keeps the name you gave it.** SessionStart used to put the
  generated title back over yours, because it tested a payload field that is
  never sent: measured against Claude Code 2.1.220 with a hook that logged every
  event, neither SessionStart nor UserPromptSubmit carries a title — they carry
  `transcript_path`, which is where the title actually lives.
- Accents fold rather than drop, so a chat named in Turkish comes out as
  `odeme-akisi-duzeltmesi` and not as whichever letters happened to be ASCII.
- `agentbus name <x>` still overrides all of this.

## 1.3.0 — 2026-07-31

A way to watch the bus. (Relaid out the same day: projects down the left, live
agents as a table beside them, then services and the feed full width. The
services table lists every declared resource — which worktree it is serving,
who started it, and who is holding it or that it is free — rather than only the
ones somebody has started.)

- **`agentbus board`** serves a live page on `127.0.0.1:8787`: the live agents
  and their subagents, what each said it was doing, what is held and by whom,
  which checkout each service is answering for, and the message feed — grouped
  by repository, refreshing itself every couple of seconds. `status` is a
  snapshot and `watch` is a stream; neither answers "what is going on", which is
  a shape rather than a line.
- It is **loopback-only**. The bus holds every branch name, worktree path and
  message on the machine; there is a test that asserts a connection from this
  machine's own LAN address is refused, rather than trusting the line of code
  that binds it.
- It is **read-only**. A window that refreshes by itself must not reap sessions,
  advance cursors or rewrite the derived files, or watching the bus would change
  it. There is a test that plants a genuinely reapable session and asserts the
  board leaves it alone while `status` still clears it.
- The page is **self-contained** — no CDN, no external font. A dashboard that
  fetches a stylesheet tells that host when you are working and from which
  repository, and stops rendering on a plane.

## 1.2.0 — 2026-07-29

A day with four subagents working three worktrees, read back out of the event
log. Five things it found, none of which any test could have.

- **The way out of a block is no longer blocked.** Every denial ends in
  `agentbus wait <res>` and, as a last resort, `agentbus claim <res> --steal`.
  Both name a resource on an `agentbus` command line, so the guard claimed them
  like any other use and refused them — the plugin printing advice it would not
  let you follow. `wait`, `release` and `--steal` now pass untouched. A real use
  chained after one (`agentbus wait sim && maestro test`) is still guarded.
- **A lock now admits when it does not know whose it is.** `agentbus claim`
  typed as a command is seen by the guard, which knows which agent you are.
  The same line inside a runner script is not, and the CLI cannot tell a
  subagent from its parent — so the lock was recorded with no owner, and an
  empty owner meant "the session itself", which every subagent walks past.
  Three subagents each took the simulator that way, each was told it held it
  alone, and they went off and built a `mkdir` mutex in a scratch directory.
  Such a lock now blocks every agent in the session and says how to settle it:
  `--as <your name>`, which works on `claim`, `release`, `wait`, `run` and
  `serve`. A session with one subagent is unaffected — nothing there can be
  ambiguous in a way that hurts.
- **One agent can no longer hand back another's lock.** `agentbus release` from
  a script looks exactly like the parent's, and the parent is allowed past its
  own subagent's lock — so a sibling could give away a rig mid-run. Releasing
  now requires showing whose it is; `release --all` gives back your own.
- **A subagent is judged where it is running, not where it was launched.** Its
  worktree was recorded once, from wherever its parent was standing, so an agent
  that had itself pointed the API at its own checkout was then refused
  permission to use it. It turned the plugin off with `AGENTBUS_OFF=1` and
  carried on, which is the one outcome this cannot afford.
- **The log says what was taken.** The day's stream held 219 releases and 7
  takes: the guard claims silently before the CLI is running, and only the
  release spoke — once per implied resource. A deliberate `agentbus run` or
  `claim` now puts one line in for the whole group and one matching it at the
  end; automatic per-command claims stay silent both ways.
- **A service being pulled back and forth is said out loud.** `api` changed
  checkouts three times in seventeen seconds while three agents each believed
  the rig was answering for their own tree; two found out an hour later with
  `lsof`. Three handovers between two checkouts in ten minutes now tells
  everyone, once, and points at the lock that prevents it.

## 1.1.0 — 2026-07-28

Subagents are parties of their own.

- A subagent launched with the Task tool used to share its parent's identity,
  because its hooks carry the parent's session id. Two subagents running in
  parallel were therefore invisible to each other: a lock one held read as
  "already yours" to the other and both walked through. Two agents driving one
  simulator, inside a single session, silently — the failure this plugin exists
  to stop, happening where nobody was looking for it.
- Now each is its own party. It registers on `SubagentStart` as `parent/1`,
  appears in `whois`, in `status` and in what a new session is told; takes locks
  in its own name; can be addressed with `agentbus post --to parent/1` and
  receives messages in its own context; and gives everything back on
  `SubagentStop`.
- A subagent is told its own name at the end of its first batch of tool calls,
  and can sign with it: `agentbus post --as parent/2 "..."`. There is no other
  way for it to find out — its shell environment is its parent's — and the
  agents on this machine had noticed, and were writing "(agent /2)" into the
  body of every message by hand. You can only speak as yourself or as one of
  your own subagents.
- A parent and its own subagent never conflict, in either direction. Anything
  else deadlocks a parent against the agent it is waiting for.
- `agentbus run`, `claim`, `serve` and `wait` are guarded by the resource they
  name. A subagent's Bash environment is byte-identical to its parent's, so by
  the time the CLI is running nothing in it knows which subagent is calling; the
  decision is made in the hook, where `agent_id` is on the payload.
- `agentbus run <res>` now takes what `<res>` implies, as the guard always did.
  It used to take the named resource and nothing else, so `agentbus run
  simulator` held the simulator while a bare `maestro test` held the simulator
  *and* the bundlers and the API — the careful command was the weaker one, and
  another session could re-serve a bundler mid-run and the run would silently
  switch to its bundle. `agentbus claim` is not expanded, because a claim is
  deliberate, but it now says what it has not taken.
- A session that moves into a worktree mid-session is followed, and the guards
  decide from the tree the caller is actually in rather than from one root per
  session — which a session with subagents in two worktrees does not have.

Two new hook events, `SubagentStart` and `SubagentStop`, so **re-run
`install.sh` and then `/reload-plugins`** in each running session after updating.

## 1.0.0 — 2026-07-28

Two sessions no longer only take turns on a port; they stay out of each other's
work.

- **Declared ownership.** `agentbus own "api/**" --why "auth rewrite"` before you
  start. Another session in your checkout is then denied edits under that scope,
  with your name, branch and reason in the message; a session in a different
  worktree is warned instead, because it is on its own branch and nothing is
  being overwritten. `--strict` blocks that case too. Ownership dies with the
  session that declared it, so there is nothing to clean up and nothing left
  behind to puzzle the next agent. `agentbus own --list`, `agentbus disown`.
- **The interference guard.** When a command fails and its output names a file
  another live session wrote in the last five minutes, the agent is told whose
  file it is, how long ago they touched it, and not to fix it. This is the one
  that stops an agent "helpfully" repairing somebody else's half-finished edit
  and starting a fight neither session understands.
- **Handoff summaries.** A session that ends writes what it did into the
  surviving sessions' context: branch, the files it wrote, what it claimed, and
  above all any service it started that is *still running and still serving its
  tree*. A session that only read things leaves quietly. `agentbus handoff`
  does it on demand.
- **`init-repo` reads the repository** instead of writing a template to fill in
  by hand: `package.json` scripts and the lockfile that says which package
  manager runs them, `Makefile` targets, a `Procfile`, Django's `manage.py`,
  uvicorn or FastAPI in the Python dependencies, database images in a compose
  file, Playwright/Cypress/Maestro. It prints where every line came from. A
  detected database gets no `start` — agent-bus must never restart yours.
  `--dry-run` and `--force` added.
- **Installable in two commands** from a marketplace, and the hook wiring now
  ships in the repository. Before this it was generated by the installer, so a
  marketplace install produced a plugin that ran no hooks at all and said
  nothing about it.
- **A test suite**, `make test`, and a second one that drives real Claude Code
  sessions through the real CLI, `tests/live/acceptance.sh`.

Fixed along the way:

- A guarded command that **failed** never gave its resource back, so the other
  session waited out the full fifteen-minute soft lock for a command that was
  already over. `PostToolUse` does not fire for a tool call that errored; the
  release now also happens on `PostToolBatch`, which does.
- A message emitted by a session on its way out was never delivered, because
  that session's own exit took the live count below the threshold the fast path
  gates on. It surfaced at the survivor's next prompt instead of its next turn.

## 0.2.0

- Two sessions issuing a guarded command in the same instant could both proceed:
  the "is anybody holding this?" check ran outside the mutex and its answer was
  discarded. Forty concurrent pairs now yield exactly one denial each.
- Guards whose distinguishing words lived inside an alternation never fired at
  all. The shell pre-filter took the longest literal run in each pattern, which
  for `git\s+(checkout|add|cherry-pick)` is `cherry-pick` — a string almost no
  matching command contains, so `git add -A` took no lock. The filter now takes
  what is mandatory: literals outside the groups, or one from every branch.
- Locks that granted nothing — expired, or held by a session that had gone — are
  swept, so `status` stops showing a session holding the whole rig an hour after
  it finished.
- Explicitly claiming `file:<path>` now actually lifts a file block. The message
  had been advertising a command the guard never consulted.

## 0.1.0

The first version. Every session registers itself, so a new one opens knowing
who else is live, in which worktree and on which branch. A command that touches
a declared shared resource takes it for the length of that command and gives it
straight back; if another live session holds it, the command is denied with the
holder, the worktree and what they are doing. Separately from the lock,
agent-bus tracks which checkout each service is actually serving and blocks a
command that would talk to somebody else's tree even when the lock is free —
which is the failure the whole thing exists for. Messages between agents are
delivered into their context at their next turn.
