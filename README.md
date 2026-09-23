# agent-bus

A Claude Code plugin for running several sessions on one machine without them
quietly ruining each other's work.

## The problem

You open two Claude Code sessions, each in its own git worktree. Their file
edits never collide — separate checkouts. Two other things collide constantly,
and both do it silently.

**The shared service lies about whose code it is running.** A reloading dev
server watches the tree it was started in. You edit your worktree while the
other one owns `:3000`, and your change never runs: the endpoint keeps its old
behaviour and you conclude your fix does not work. Or your test suite goes
green — against somebody else's branch. Nothing announces this. The port hides
which checkout is answering.

**Agents are helpful at the wrong moment.** The other session is halfway
through editing `api/service.py`. Yours runs the build, sees a syntax error in a
file it has never touched, and fixes it. Now two sessions are editing one file,
each undoing the other, and neither knows why.

A README explaining the rules does not fix either one, because an agent has to
remember to read the README. This does, because the decision is made in a hook:
the first time, the command does not run, and the agent is told what is wrong,
who to ask and how to fix it. If it still needs to, it runs the same command
again — that goes through, and whoever it lands on is told.

## What it looks like

Not invented — copied from a run. A session in `wt2` curls a dev server that
another session started from a different checkout:

```
agent-bus: STOPPED ONCE. "web" (the demo server on :8099) is serving a different checkout, so this command would exercise that code and report it as yours.

  serving   : …/repo
  you are in: …/wt2
  started by: repo-main, just now

  It serves the tree it was started in, so a request to it answers with THAT checkout's files.

One step, and the shortest one: this points every service your
command needs at your worktree, takes their locks, runs your
command against your own tree and tells the other sessions:
  agentbus run web -- <your command>

Or move them for good, and run your command yourself afterwards:
  agentbus serve web

If what that checkout serves is what you mean to test, run the same
command again and it goes through — knowing the result is theirs:
  <your command>
```

A session runs the build and the failure names a file somebody else is mid-edit
in:

```
agent-bus: this failure names files another live session is editing right now:
  api/service.py — repo-main#2, 5s ago
Do not fix them. That session is mid-edit and the error is probably transient;
re-run the command in a moment. If it persists, ask rather than edit:
  SendMessage → to "repo-main#2"   (idle)
  "your edit to api/service.py breaks my build — done soon?"
Fix only files you own.
```

And a session tries to edit a scope somebody claimed up front:

```
agent-bus: STOPPED ONCE. repo-main has declared this part of the tree theirs.

  file    : api/service.py
  owner   : repo-main   branch main
  claimed : api/**, 0s ago
  reason  : "backend rebuild"
  worktree: …/repo   (the same one you are in)

Ask before taking it — a message wakes them, so this is worth doing and not a formality:
  SendMessage → to "repo-main"   (idle)
    "I need api/service.py — what are you doing with it?"

If they agree, or you still need to, make the same edit again: it goes
through, and repo-main is told. Or take the file itself, so the stop applies
to them instead:
  agentbus claim 'file:…/repo/api/service.py' --why "agreed with repo-main"
```

## Install

From the marketplace, in two commands:

```bash
claude plugin marketplace add akaribrahim/claude-agent-bus
claude plugin install agent-bus
```

That wires the hooks. It cannot put a command on your `PATH`, and every message
above ends in one, so run the installer once as well — your next session will
tell you so if you forget:

```bash
~/.claude/plugins/cache/agent-bus/agent-bus/*/install.sh
```

Or clone it into the personal plugins directory and skip the marketplace:

```bash
git clone https://github.com/akaribrahim/claude-agent-bus ~/.claude/skills/agent-bus
~/.claude/skills/agent-bus/install.sh
```

Windows (PowerShell) — verified on Windows 10 with an embeddable Python:

```powershell
git clone https://github.com/akaribrahim/claude-agent-bus $env:USERPROFILE\.claude\skills\agent-bus
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\.claude\skills\agent-bus\install.ps1
```

Then restart Claude Code. The installer picks this machine's hook entry point,
puts `agentbus` on `PATH` and allowlists `Bash(agentbus:*)` so it never raises a
permission prompt. It needs Python 3.8+ and nothing else — no daemon, no
service, no dependencies. `agentbus doctor` reports what it found.

## Declaring what is shared

Per-repository and opt-in. Without a config you still get presence, addresses,
declared ownership and the interference guard; what you do not get is locks,
which is the right default for a project with nothing to contend for.

```bash
cd your-repo
agentbus init-repo
```

The first run reads the repository rather than handing you a template:

```
agent-bus: looked at this repository and found

  server     :3000   bun run dev                    from package.json scripts.dev
  db                 (no start command)             from docker-compose.yml (postgres:16)
  e2e                implies server                 from playwright config
  worktree           this checkout's tree and index
```

It reads `package.json` scripts and the lockfile that says which package manager
runs them, `Makefile` targets, a `Procfile`, Django's `manage.py` next to a
`settings.py`, uvicorn or FastAPI in the Python dependencies, database images in
a compose file, and Playwright/Cypress/Maestro. Every line says where it came
from, so you can check it. A detected database gets **no** `start`: agent-bus
must never restart yours, since a reseed invalidates the rows the other sessions
are holding. `--dry-run` prints without writing, `--force` overwrites, `--local`
writes a machine-only override that wins by name.

Read what it wrote, fix what is wrong, then commit it — and every worktree,
machine and collaborator gets the same guards.

```json
{
  "resources": [
    {
      "name": "server",
      "desc": "the dev API on :8000",
      "why": "The reloader watches the tree it was started in, so a request to :8000 exercises whichever checkout owns it — not necessarily yours.",
      "port": 8000,
      "cwd": "api",
      "start": "uvicorn app:api --reload --port 8000",
      "ready": "curl -sf localhost:8000/health",
      "patterns": ["\\buvicorn\\b", ":8000\\b"]
    },
    {
      "name": "e2e",
      "desc": "the browser and the runner",
      "why": "One browser on this machine, and the run only means something against the server serving your checkout.",
      "implies": ["server"],
      "patterns": ["\\bplaywright\\b"]
    },
    {
      "name": "worktree",
      "desc": "this checkout's working tree and index",
      "scope": "worktree",
      "why": "One session's `git stash` changes the other's files mid-task; `git add -A` sweeps their half-finished work into a commit.",
      "patterns": ["\\bgit\\s+(checkout|switch|stash|reset|rebase|add|commit)\\b"]
    }
  ]
}
```

| field | meaning |
|---|---|
| `patterns` | Regexes matched against each command's **argv** — after read-only heads (`grep`, `cat`, `git log`) are skipped, quoted prose is dropped and heredoc bodies are removed. A commit message that names a tool is not a use of that tool. |
| `port`, `cwd`, `start`, `ready` | Let agent-bus own the service: it can then say which checkout is being served and move it to yours. Without them a resource is a plain mutex. |
| `implies` | Resources a command needs indirectly (an e2e run needs the server). |
| `unless` | Regexes that mean this use is **not** the guarded thing. `patterns` recognise the tool; a `db` resource describing your local Postgres matches every `psql` there is, including one aimed at staging. |
| `scope: "worktree"` | Contended only by sessions in the *same* checkout. |
| `ports` | `"per-worktree"` gives every checkout its own port for this resource, derived from its path. The repository's original checkout keeps the declared one, so nothing changes for whoever works there. Use `${PORT}` in `start` and `ready`. |
| `env` | The shell variable this resource's port is exported as — by `agentbus env`, and in the environment of every service agent-bus starts and every command under `agentbus run`. Defaults to `AGENTBUS_PORT_<NAME>`. So a bundler that bakes an API address into what it builds can read `$AGENTBUS_PORT_API` in its `start` line instead of a `.env` naming one checkout's port — which is the half of per-worktree ports no guard can reach, since the request then leaves a simulator rather than a watched shell. |
| `key` | A regex whose first group names *which one*: `"key": "--udid\\s+(\\S+)"` turns one simulator lock into one per device. A command naming no instance contends with all of them. On the command line, where there is no command to read a device off, name it yourself: `agentbus claim simulator@ABC123`. |
| `why` / `hint` | Shown verbatim when blocking. `init-repo` leaves these empty on purpose: this is the part only you can write, and it is the part that stops an agent working around the block. |

The cheap pre-filter the shell hook uses is **derived from the patterns**, so the
two cannot drift apart.

## Commands

```
agentbus status                       who is live, what is held, what serves whom
agentbus watch [--repo]               follow every agent on this machine, live
agentbus board [--port 8787]          the same thing as a page in your browser
agentbus run <res>[,<res>] -- <cmd>   point the services at your tree, hold, run, release
agentbus serve <res>[,<res>]          restart services so they serve YOUR worktree
agentbus serves                       which checkout each service is answering for
agentbus own "<glob>" [--why ".."] [--strict]   declare part of the tree yours
agentbus own --list | disown "<glob>" | disown --all
agentbus claim <res>[,<res>] [--why ".."] [--steal] [--as <you>]
agentbus wait <res>[,<res>] [--timeout 90]      queue for a held resource
agentbus release <res>[,<res>] | --all
agentbus merges                       what the branches in flight would do if they
                                      landed together, and what would conflict
agentbus integrate --yes [--only a,b] [--budget 2.00] [--keep]
                                      spawn a headless session to land them, in a
                                      scratch worktree. Spends model calls
agentbus init-repo [--dry-run|--force|--local]
agentbus here [<path>]                record which worktree you are working in
agentbus port <res>                   the port this checkout should use
agentbus env                          every declared port, as shell exports
agentbus doctor | whois | forget <agent|--stale> | install
```

Ownership globs are matched against the path **relative to the repository
root**, so one declaration means the same thing in every worktree. Two
properties to know rather than discover: **`*` crosses directory separators**
(`src/*` covers `src/a/b/c.ts`, and a glob with no wildcard at all means that
directory and everything under it), and **quote the glob** or your shell expands
it before agentbus sees it.

## Talking to another session

agent-bus used to carry messages between sessions. It does not any more: Claude
Code ships `ListAgents` and `SendMessage`, which reach a session directly and
**wake it** — an idle session acts on one within seconds, without its human,
though whether it writes back is its own judgement. This plugin never could do
that, and the difference is not a detail. It is what turns
"ask whoever is holding the database" from advice into an action.

What agent-bus contributes is the part the tool cannot know: who holds what, who
is already waiting, and the address that actually reaches them. So every block
prints the call to make, addressed and with the sentence written:

```
db is held by seeder/1 — a subagent of seeder. Took it 3m ago, "consuming fixtures".

  agentbus wait db --timeout 600     queue for it; takes it the moment it frees

Then tell them it is queued. A message wakes them, so this is an
answer you have in a moment rather than a formality:
  SendMessage tool → to "seeder"      ask seeder — it holds this through seeder/1
  "I have queued for db — `agentbus status` shows me waiting.
   Release it when your command is done and mine takes it."
```

Two things in there are the whole design. **The queue comes first**, because
asking is not waiting: you join the queue, say so, and get on with something
else while they finish. And **the address is read, never guessed** — from
Claude Code's own session registry, because the name this plugin knows a session
by and the name that tool answers to agree only by coincidence. A subagent
cannot be addressed at all, so a lock one holds is announced to its session with
the subagent named.

`agentbus post` and `agentbus inbox` still exist for one release. They deliver
nothing, print the call that works, and exit non-zero.

## Watching it

`agentbus status` is a snapshot. It does not answer the question somebody with
four terminals open actually has, which is *what is going on right now*.

```bash
agentbus watch          # a live line per event, in the terminal
agentbus board          # the same thing as a page: http://127.0.0.1:8787
```

The page is **a box per project** and, inside it, **a strip of ground per
checkout**, full width, with the worktree path written above the strip as its
heading and the agents working in that tree standing on it. Whoever stands on one
strip shares that tree, which is the fact a grid of equal cards cannot state. The
boxes are full width and stacked, so a project with one quiet agent in it is a
short box rather than a card sharing a row. Projects are ordered by how many
agents they have, busiest first, and so are the checkouts inside a project — five
agents in one repository and one each in four others is the ordinary shape of a
machine running several chats, and the crowd belongs at the top.

A checkout's heading is one line and is cut on the **left**, because a checkout is
told apart by its tail: `…/.claude/worktrees/fix-timeouts` identifies it where
`~/work/demo-app/.clau…` does not. Only the drawing is cut — the whole path is
there to select and copy, and it is on the heading's tooltip untruncated.

A band is as tall as what is in it. One quiet agent is a strip; five agents wrap
onto as many lines as they need at full size, and an agent with subagents under
it is given twice the width of one standing alone. Nothing is squeezed to fit a
row.

Each agent is drawn as a figure whose shape, eyes, crest, lean and colour are its
**name**, hashed — so the same agent is the same figure on every reload, in every
tab and on the second monitor, with no table anybody maintains. The courses under
its feet are commits past the trunk, the sheets it carries are files it has
written, and it only has arms when it is holding something. A figure recedes when
its session has gone quiet, and gets a ring when it is quiet **and** holding
messages it has never been shown — the one state on the page asking to be acted
on rather than watched. Click one for every field of it, as text you can select.

Under each agent, indented and on ground of its own, is **its subagents as a
tree**. A subagent is a party in its own right here — it holds locks under its own
id and it contends with its siblings — so its row says what kind of agent it is,
how long it has been running, what it is holding, and **the checkout it is
working in when that is not its parent's**,
which is what `agentbus here --as <name>` is for. The row is shorter than a
session's and is not padded to look equal: unread messages, commits ahead and
files written are counted per session, so they are the parent's facts and are not
repeated on the child as though they were its own.

Under each agent is **what it last actually did** —
`editing api/routes.py, 4s ago`, `ran alembic upgrade, 12s ago`. Nothing is asked
of the agents for this: the hooks already see every tool call, so the shell fast
path records the last one per party and the page draws it. It costs a `printf` on
the path that does not wake the engine, no clock read (the file's mtime is the
timestamp), and one line per party which is overwritten rather than appended to. A
session that is alone on the machine records nothing, by the same gate that
already makes a solo session free.

Below the yard: what would land, every declared service — which worktree it is
serving, who started it, and who is holding it or that it is free — and the
message feed. It refreshes itself every couple of seconds and rows are updated in
place rather than redrawn, so a selection survives a poll and a value that
changes says so for a moment.

The bands are per checkout rather than per repository because two things you
cannot see anywhere else are what each session has produced and where that
collides:

- **how far ahead of the trunk** each checkout is, counted against the default
  branch the repository itself names rather than an assumed `main`;
- **the files it has written**, and the ones **another live session in the same
  repository has written too** — which is what you want before merging two
  chats' work, not during;
- **how many bus messages it has not been shown**, and, if it has gone quiet
  holding any, the figure is ringed and counted in the header. That is the window
  to go and poke, and it is the one thing on the page asking to be acted on;
- **how many of its commands took a shared resource**, which is the only sign
  anywhere that a session has been reaching for the machine at all;
- **the tool call it last made**, per party, so a chat that has said nothing about
  itself still shows what it is up to — and a chat that said something is checked
  against it.

A file two live sessions have both written is the one fact on the page about a
*pair*, so it is the one thing drawn as a line: a tether between the two figures,
labelled with the path, measured off the laid-out page in one frame — and the
strip it is drawn on keeps room above the heads for it. It is also said in words
on both of them, because a line between two figures is no use to somebody who
cannot see it.

There used to be a ledger here — `agentbus take` and `agentbus done`, two lines
an agent typed per piece of work — on the argument that nothing else can show
*intent*. It is gone in 3.0.0, and the reason is worth stating rather than
quietly dropping: one agent in six ever used it. What an agent is doing has been
derived from its own tool calls since 2.9.0 without anybody typing anything, and
a second place to say the same thing is a place that is empty exactly when it
matters. Intent between two agents is now a message, which is a thing Claude
Code does properly and this plugin never could.

What was worth keeping from it is on the lock instead. A resource in use shows
**who is waiting for it**, so the holder can hand it over without being asked —
that queue existed all along, and until 3.0.0 nothing rendered it anywhere its
holder would look.

The feed draws a line where you last looked away. That mark lives in your
browser, not on the bus.

## Landing it

Several chats have branches in flight. Whether their work can go on the trunk
together used to be answerable only by merging and seeing — which means checking
out a branch somebody is working in and rewriting their files mid-tool-call. Git
can answer it exactly instead, and for nothing:

```bash
agentbus merges
```

```
agent-bus: 2 branches ready to land on main
  feat-api                 +3 commits, 7 files   ~/work/api-wt (2 uncommitted)
      dizzy-mole on it right now
      merges into main cleanly
  feat-web                 +1 commit, 4 files    ~/work/web-wt
      merges into main cleanly

Between them:
  feat-api and feat-web CONFLICT in api/schema.py

Finished, but not ready:
  t5   build the exporter — t4 is waiting for t2 to land
```

The candidate is a **branch**, not a task, because a branch is what gets merged:
two finished tasks on one branch land together whether anybody meant them to or
not. "They both touched it" and "it conflicts" are kept apart — two chats editing
opposite ends of one file is not a problem and the board's write-log collision
cannot tell the difference. Uncommitted work is reported because it is the whole
difference between ready and looks-ready. And *finished but not ready* is said out
loud with the reason, because each of those is a branch you would otherwise be told
to merge.

**It writes nothing.** Not a merge, not a checkout, not an index refresh, not a
stash. `git merge-tree` merges two commits in memory, and even the tree it
produces is redirected into a temporary directory so the object store comes out
byte-identical. The same view is on the board twice over: a badge on the right of
each checkout's own strip saying what that tree would land, and the whole table
below the yard — the pairs that would fight, the finished work that is *not* ready
and why, and the command printed as text with nothing there to press. A control
that spends model calls when clicked is a different kind of object from a window
that only watches.

### And if you want it done

```bash
agentbus integrate --yes
```

One chat cannot make another chat act — hooks fire on a session's own activity, so
nothing can put a turn into an idle interactive session. A session agent-bus
**starts itself** is different, because it was created programmatically. So this
spawns one: it merges the candidates in a scratch worktree of its own, resolves
what conflicts, runs whatever the repository uses to check itself, and reports.

Without `--yes` it prints the plan, the command line it would run and the cost,
and does nothing. A flag rather than a prompt, because an agent may run this too.

- **A scratch worktree it creates and removes**, detached at the trunk. Never
  anybody's checkout, and never `main` in one somebody is using.
- **It cannot push.** Every remote's `pushurl` is overridden in its environment.
- **It registers on the bus like any other session**, so it is in the roster and
  the guards apply to it. It is not a special citizen.
- **It cannot close anybody's task** — the engine refuses, not the prompt. Saying
  work is finished is its author's declaration to make.
- **The spend is capped** with the CLI's own `--max-budget-usd`.

Whether it worked is asked of git, not of the worker: every branch has to be an
ancestor of what is in the scratch tree. And if it could not finish — a real
conflict needing a person, a check that failed — it says so and **leaves the
worktree and the transcript** rather than deleting the evidence.

Sessions are named after their chats. A session registers the moment it opens,
when its branch is the only thing to go on, so it starts as `feat-login` or
`repo-main`; rename the chat and the bus follows at the next turn, subagents
included (`agentbus/1`, `agentbus/2`). `agentbus name <x>` overrides it.

A chat that has gone quiet for hours is **retired** from the roster: it stops
holding locks and stops being listed as live, whether or not its window is still
open. What it *told* the bus outlives that. Come back to it and it is still
called what you called it, still as old as it is, and still working in the
checkout it declared with `agentbus here` — and the rename is not announced to
everybody a second time.

Two things it deliberately is not. It is **loopback-only**: the bus is every
branch name, worktree path and message on your machine, and none of that should
be one misconfigured bind away from your network. And it is **read-only** — it
never reaps a session, advances a cursor or rewrites a derived file, because a
window that refreshes by itself must not change what it is showing you.

`agentbus doctor` reports what is installed, whether the command is on `PATH`,
which config is in force, which services are running and for whom, and which
resources have **never matched a command** — the silent failure mode when a port
moves.

## How it works

| Hook | Job |
|---|---|
| `SessionStart` | Register; inject the roster, held resources, running services, declared ownership, and anything unread. |
| `UserPromptSubmit` | Heartbeat; deliver anything that changed under this session between turns. |
| `PreToolUse` | Take the resources a Bash command needs, or deny it — because someone holds them, or because the service is serving another checkout. Block an `Edit`/`Write` to a file another session has declared theirs, or is editing right now in the same checkout. Record a `SendMessage` on its way past, deciding nothing. |
| `PostToolUse` | Give a finished command's claim straight back; record what was written. |
| `PostToolBatch` | Deliver notices; release what a *failed* command took, since `PostToolUse` does not fire for those; and if something in the batch failed and named a file somebody else is mid-edit in, say so. |
| `SessionEnd` | Release everything, deregister. |

**Subagents are parties of their own.** A subagent launched with the Task tool
runs inside its parent's process and its hooks carry the parent's session id, so
without help two of them running in parallel share one identity — a lock one
holds reads as "already yours" to the other, and both drive the simulator. What
tells them apart is `agent_id`, which Claude Code puts on every hook a subagent
causes and on none the session itself causes. Each registers on `SubagentStart`
as `parent/1`, takes locks in its own name, and gives everything back on
`SubagentStop`. It cannot be messaged from outside — `SendMessage` reaches
sessions — so a block held by one addresses its session and names the subagent,
which is the common case rather than the corner: 64 of the 87 takeovers this
plugin has recorded were held by a subagent. A
parent and its own subagent never block each other, in either direction —
anything else deadlocks a parent against the agent it is waiting for.

That decision is made in the hook rather than in the CLI on purpose: a
subagent's Bash environment is byte-identical to its parent's, so by the time
`agentbus run` is executing, nothing in it knows which subagent is calling.
Which means the spelling matters. `agentbus claim sim` typed as a command is
seen by the guard and locked in the caller's name; the same line inside a runner
script is not seen at all, and the lock it makes has to record that it cannot
name its party — whereupon it blocks every agent in the session rather than
letting every agent past. `--as <your name>` settles it from inside a script.

A bash fast path runs first and decides in a few milliseconds whether the Python
engine needs to run at all — shell builtins only, short-circuiting before it has
even read the payload when you are the only session, and again for a command
every segment of which only reads, since there is nothing in one for the engine
to find. On hosts without bash the installer wires the hooks straight to Python
instead, which makes the same decisions in the same order.

State lives in `~/.claude/agent-bus/` — sessions, cursors, locks, ownership,
service ownership, one task ledger per repository, an append-only `events.jsonl`,
and the derived files the fast path reads. Never in the plugin directory, so
updating never loses it, and never in the repository either: a ledger one chat
commits and another rebases away is not a ledger.

Locks are soft (taken automatically, released when the command ends, stealable
once expired) or hard (`claim`, 45 minutes, only stealable with `--steal`). A
dead session's locks and declarations are released the next time anyone looks.

## What it costs

Measured on an M-series Mac with `tests/perf/hook-cost.py`, median of fifteen,
machine quiet. Under load everything here roughly triples, so treat them as
floors.

| | |
|---|---|
| Alone, any hook | ~5 ms — the fast path reads one small file and exits |
| Two sessions, a tool batch that ran no command | ~5 ms |
| Two sessions, a command that only reads | ~5 ms — the fast path answers it |
| Two sessions, a tool batch that ran a command | ~24 ms — one engine start per batch, not per command |
| Two sessions, a guarded command | ~24 ms, and it takes the lock |

Nearly all of that ~24 ms is Python arriving: ~15 ms to start the interpreter,
and the rest unpickling the engine's cached bytecode. Compiling it is ~31 ms more
and is paid once per change to the file rather than once per hook, because both
fast paths reach the engine by importing it — a file the interpreter is handed as
a script is never cached, and that is what `agentbus hook <event>` still costs if
you call it by hand. `agentbus doctor` reports whether the cache is there; a
plugin directory that cannot be written to never gets one. The guard's own work —
deciding, taking the lock — is under a millisecond of the last two rows.

There is no daemon and nothing runs between sessions. Alone, it is effectively
free.

`agentbus merges` and the board's landing view cost git rather than tokens: a
handful of `rev-list`, one `diff` and one `merge-tree` per candidate branch, plus
one `merge-tree` per pair. The board never pays it on a poll — the view is cached
for thirty seconds per repository and computed in a background thread.

`agentbus integrate` is the only thing here that costs money. It is capped with
the CLI's own `--max-budget-usd`, $2.00 unless you say otherwise, and it prints
what it is about to spend and stops unless you add `--yes`.

## Limits, stated plainly

- **One machine.** Everything is coordinated through a directory in your home
  folder. Two developers on two laptops know nothing about each other.
- **This plugin cannot push anything into an idle session, and no longer tries.**
  Its own notices — a lock taken from under you, a service moved to another
  checkout — still reach another agent at its next turn rather than the moment
  they happen. Messages do not go through it at all: Claude Code's `SendMessage`
  carries those, it reaches the session directly, and it wakes it. Both of the
  limits this section used to state under this heading were about a channel that
  is gone.
- **One chat CAN now make another chat act, and that changes what a block is.**
  Until 3.0.0 "ask the holder" was advice nobody could take: a posted note waited
  for the reader's next turn, which for an idle session is whenever its human
  comes back. On this machine, on 2026-09-04, a session was blocked on the
  database at 14:38:31 and stepped past the guard with `AGENTBUS_OFF` at
  14:38:42. Eleven seconds is how long asking was considered. A message wakes the
  recipient and it acts without its human, so since 3.1.0 a guard stops a
  command once and hands the conversation to the two agents: ask the holder,
  then go ahead on a second try — which goes through, and they are told — or
  queue if it can wait. What this plugin contributes is the part the tool cannot
  know — who holds what, who is waiting, and the address that actually reaches
  them.
- **What it will not do is send for you.** There is no CLI that puts a message in
  another session's conversation, so every block prints the call for the agent to
  make rather than making it. That is a boundary worth keeping: a coordination
  layer that can speak as you is one that can say something you would not.
- **`integrate` is a rail, not a sandbox.** A worker cannot push to a configured
  remote and cannot close anybody's task, both enforced rather than requested. A
  determined `git push <literal-url>` would still get out; the rails are against
  the accident, which is the thing that actually happens.
- **The guards are only as good as the config.** A resource nobody declared is a
  resource nobody guards, and a pattern that stops matching fails silently.
  `agentbus doctor` reports resources that have never matched, which is the only
  way to notice.
- **A stop is a stop, not a wall — and one of them answers back.** Since 3.1.0
  the same agent's second try at the same thing goes through, as `AGENTBUS_OFF=1`
  always did; `AGENTBUS_TOLD_FOR=0` in the environment puts the old refusal back
  for a machine that wants it. For a lock that is sometimes exactly right,
  because a `psql` aimed at a staging box in another country only looks like the
  one this machine shares. For the wrong-port check it rarely is: your own port
  exists. So going past that one goes into the other sessions' context rather
  than only into the log, naming the port, whose checkout
  it serves and the command that was skipped — once per party and port, counted
  after that, so a run of one mistake costs its readers one message. What that
  buys is that nobody finds out afterwards. It does not stop anybody.
- **The task ledger is only as good as the habit.** Everything derivable is
  derived precisely because agents forget, but the two lines that are typed can
  still go untyped — and then the board says nothing was taken. What it will not
  do is lie: a task nobody closed goes on showing what its owner is really
  writing, and one whose chat ended reads as dropped by itself.
- **Locks see Bash tools only.** A shared service reached through an MCP tool, or
  a file written by something other than `Edit`/`Write`, is invisible to them.
- **Subagents share their parent's writes.** Locks, presence and messages treat
  each subagent as its own party, but the file-collision guard and the
  interference note still work per session, so two subagents editing one file
  are not warned about each other.
- **Windows is verified but young.** Sessions have been run twice on Windows 10
  with a Turkish locale and an embeddable Python; presence, messaging, locks,
  the ownership and file-collision guards, `here`, `status`, `serves`, the
  board, `merges` and session renaming all behaved. Both rounds found real
  defects and both are fixed here — the second round's are in 2.13.0, and the
  headline one is that no service could be attributed to a checkout on Windows
  at all, including one agent-bus had started itself.

  Two things still ask something of you there. After a `claude plugin update`,
  re-run the installer: the cache path carries the version, so a bump leaves a
  fresh copy wired to the committed hooks, which name a shell entry point
  Windows does not have. `agentbus status` now says so when it is the case.

  And a clone made before 2.12.0 still has CRLF working copies that
  `.gitattributes` cannot repair by itself — 17 of the 25 shell files on one such
  clone, which is `bash tests/run.sh` dying on `$'\r'`. `git add --renormalize .`
  does *not* fix it: that normalizes the index, and the index was already LF.
  What re-checks the files out is

  ```bash
  git rm --cached -r . && git reset --hard
  ```

  or a fresh clone. If you also drive `agentbus` from Git Bash and get
  `Permission denied` on the interpreter, that is not this: some endpoint
  protection refuses a Windows executable launched from inside `sh -c`, and the
  same interpreter called directly works. Use the `.cmd` shim there.

## Tests

```bash
make test                      # the plugin's own logic, isolated state, no network
tests/live/acceptance.sh all   # two real Claude Code sessions through the real CLI
tests/live/acceptance.sh land  # just the one that spawns an integration worker
```

The first is fast and free. The second spawns real sessions and costs real model
calls, so it is deliberately not part of `make test` — but it is the one that
proves the thing works, and it has already caught a defect a suite of synthetic
hook payloads could not.

Before your first commit, `make hooks`. It points git at `.githooks/`, which
refuses a commit whose files or message carry a secret — by the same table the
bus masks its log with — or any string listed in `notes/never-publish.txt`, a
gitignored file for the names that must never reach a public repository.
`make test` runs the same check over every tracked file.

## Requirements

Python 3.8+. Bash for the fast path, or Python-only hooks without it. macOS and
Linux verified. Windows 10 verified but young — see Limits for exactly how far
that run got, and note that the hook cost in the table above has not been
re-measured there since the 2.1.0 refactor.

## License

MIT.
