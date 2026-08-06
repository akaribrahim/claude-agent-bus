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
the command does not run, and the agent is told what is wrong and how to fix it.

## What it looks like

Not invented — copied from a run. A session in `wt2` curls a dev server that
another session started from a different checkout:

```
agent-bus: BLOCKED. "web" (the demo server on :8099) is serving a different
checkout, so this command would exercise that code and report it as yours.

  serving   : …/repo
  you are in: …/wt2
  started by: repo-main, just now

  It serves the tree it was started in, so a request to it answers with THAT
  checkout's files.

Point it at your worktree — this stops the current one and starts
yours, and tells the other sessions it moved:
  agentbus serve web

Or run one command against your own tree and leave it there:
  agentbus run web -- <your command>
```

A session runs the build and the failure names a file somebody else is mid-edit
in:

```
agent-bus: this failure names files another live session is editing right now:
  api/service.py — repo-main#2, 5s ago
Do not fix them. That session is mid-edit and the error is probably transient;
re-run the command in a moment. If it persists, ask rather than edit:
  agentbus post --to repo-main#2 "your edit to service.py breaks my build — done soon?"
Fix only files you own.
```

And a session tries to edit a scope somebody claimed up front:

```
agent-bus: BLOCKED. repo-main has declared this part of the tree theirs.

  file    : api/service.py
  owner   : repo-main   branch main
  claimed : api/**, 1m ago
  reason  : "backend rebuild"
  worktree: …/repo   (the same one you are in)

Ask before taking it:
  agentbus post --to repo-main "I need api/service.py — what are you doing with it?"

Once they have agreed, take the file itself and the block lifts:
  agentbus claim 'file:…/api/service.py' --why "agreed with repo-main"

(Or the human can rerun the edit with AGENTBUS_OFF=1 in front of it.)
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

Per-repository and opt-in. Without a config you still get presence, messaging,
ownership, handoffs and the interference guard; what you do not get is locks,
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
| `env` | The shell variable `agentbus env` exports for this resource's port. |
| `key` | A regex whose first group names *which one*: `"key": "--udid\\s+(\\S+)"` turns one simulator lock into one per device. A command naming no instance contends with all of them. On the command line, where there is no command to read a device off, name it yourself: `agentbus claim simulator@ABC123`. |
| `why` / `hint` | Shown verbatim when blocking. `init-repo` leaves these empty on purpose: this is the part only you can write, and it is the part that stops an agent working around the block. |

The cheap pre-filter the shell hook uses is **derived from the patterns**, so the
two cannot drift apart.

## Commands

```
agentbus status                       who is live, what is held, what serves whom
agentbus watch [--repo]               follow every agent on this machine, live
agentbus board [--port 8787]          the same thing as a page in your browser
agentbus post "..."                   leave a message for the others in this repo
agentbus post --to <agent> "..."      ...for one agent, wherever they are working
agentbus post --all "..."             ...for every session on the machine
agentbus inbox                        everything addressed to this repo / to you
agentbus run <res>[,<res>] -- <cmd>   point the services at your tree, hold, run, release
agentbus serve <res>                  restart a service so it serves YOUR worktree
agentbus serves                       which checkout each service is answering for
agentbus own "<glob>" [--why ".."] [--strict]   declare part of the tree yours
agentbus own --list | disown "<glob>" | disown --all
agentbus handoff [--note ".."]        summarise what you did, for the others
agentbus claim <res>[,<res>] [--why ".."] [--steal] [--as <you>]
agentbus wait <res>[,<res>] [--timeout 90]      queue for a held resource
agentbus release <res>[,<res>] | --all
agentbus take "<what>" [--needs <task>]         say what you have started
agentbus take <task>                  pick up work whose session has gone
agentbus done [<task>] [--note ".."]  say it has landed
agentbus merges                       what the finished work would do if it landed
                                      together, and what would conflict. Reads only
agentbus integrate --yes [--only a,b] [--budget 2.00] [--keep]
                                      spawn a headless session to land it, in a
                                      scratch worktree. Spends model calls
agentbus doing "..."                  one line others see in their roster
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

## Watching it

`agentbus status` is a snapshot and `agentbus inbox` is what was addressed to
you. Neither answers the question somebody with four terminals open actually
has, which is *what is going on right now*.

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
onto as many lines as they need at full size, and an agent with a sentence about
what it is doing is given twice the width of one that has said nothing. Nothing
is squeezed to fit a row.

Each agent is drawn as a figure whose shape, eyes, crest, lean and colour are its
**name**, hashed — so the same agent is the same figure on every reload, in every
tab and on the second monitor, with no table anybody maintains. The courses under
its feet are commits past the trunk, the sheets it carries are files it has
written, and it only has arms when it is holding something. A figure recedes when
its session has gone quiet, and gets a ring when it is quiet **and** holding
messages it has never been shown — the one state on the page asking to be acted
on rather than watched. Click one for every field of it, as text you can select.

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
  anywhere that a session has been reaching for the machine at all.

A file two live sessions have both written is the one fact on the page about a
*pair*, so it is the one thing drawn as a line: a tether between the two figures,
labelled with the path, measured off the laid-out page in one frame — and the
strip it is drawn on keeps room above the heads for it. It is also said in words
on both of them, because a line between two figures is no use to somebody who
cannot see it.

None of that can show *intent*. Two chats fixing review findings in one
repository look identical from outside, and which of them is blocked on the
other is nowhere on the machine. So the agents write it themselves, in two lines
per piece of work:

```bash
agentbus take "fix the review findings in api/"          # → t1
agentbus take "rebase web onto main once api lands" --needs t1
agentbus done t1 --note "all four findings closed"
```

Each task appears **on the agent that took it**, beside what the bus watched that
agent do rather than instead of it, so a chat that has declared nothing still
shows everything above. Only the sentence and the reference are typed: the branch,
the checkout, the files the task has produced since it was taken, what its owner
is holding and — from a lock's own queue — what it is queued behind are all
derived, because a ledger with six fields to fill in is one nobody fills in when
it matters. It also says what the work was **built on that has already landed**,
which `--needs` alone stops mentioning the moment the thing lands, and who the
work was **carried from** if it changed hands. Taking and finishing reach the
other sessions in the repository the way a `post` does, which is the point:
nobody has to carry messages between chats by hand.

Work whose chat has gone reads as **dropped** and is shown rather than deleted —
a lock that grants nothing can be deleted because the resource frees itself, and
work cannot, because the branch is still there. It is drawn standing on the
ground it was taken in, with its branch and its checkout named, and `agentbus
take <task>` picks it up; a checkout whose last agent has left keeps its strip
with nobody on it, because that is where the work somebody has to pick up is
actually sitting. Ids are per repository. The header counts what is open, blocked
and dropped.

The feed draws a line where you last looked away. That mark lives in your
browser, not on the bus.

## Landing it

Two chats say they are done. Whether their work can go on the trunk together used
to be answerable only by merging and seeing — which means checking out a branch
somebody is working in and rewriting their files mid-tool-call. Git can answer it
exactly instead, and for nothing:

```bash
agentbus merges
```

```
agent-bus: 2 branches ready to land on main
  feat-api                 +3 commits, 7 files   ~/work/api-wt (2 uncommitted)
      t1   fix the review findings in api/ — dizzy-mole, "all four closed"
      merges into main cleanly
  feat-web                 +1 commit, 4 files    ~/work/web-wt
      t3   rebase web onto main — quiet-fox
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
| `UserPromptSubmit` | Heartbeat; deliver new messages between turns. |
| `PreToolUse` | Take the resources a Bash command needs, or deny it — because someone holds them, or because the service is serving another checkout. Block an `Edit`/`Write` to a file another session has declared theirs, or is editing right now in the same checkout. |
| `PostToolUse` | Give a finished command's claim straight back; record what was written. |
| `PostToolBatch` | Deliver messages; release what a *failed* command took, since `PostToolUse` does not fire for those; and if something in the batch failed and named a file somebody else is mid-edit in, say so. |
| `SessionEnd` | Write the handoff, release everything, deregister. |

**Subagents are parties of their own.** A subagent launched with the Task tool
runs inside its parent's process and its hooks carry the parent's session id, so
without help two of them running in parallel share one identity — a lock one
holds reads as "already yours" to the other, and both drive the simulator. What
tells them apart is `agent_id`, which Claude Code puts on every hook a subagent
causes and on none the session itself causes. Each registers on `SubagentStart`
as `parent/1`, takes locks in its own name, can be addressed with
`agentbus post --to parent/1`, and gives everything back on `SubagentStop`. A
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
even read the payload when you are the only session. On hosts without bash the
installer wires the hooks straight to Python instead.

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
| Two sessions, a tool batch that ran a command | ~46 ms — one engine start per batch, not per command |
| Two sessions, a guarded command | ~48 ms, and it takes the lock |

Nearly all of that ~46 ms is Python arriving: ~16 ms to start the interpreter
and ~26 ms to read and compile the engine, which a hook script never gets to
cache. The guard's own work — deciding, taking the lock — is the couple of
milliseconds between the last two rows.

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
- **Nothing is pushed into an idle session.** A message reaches another agent at
  its next turn, not the moment you send it. If it is mid-run, it hears when
  that run ends.
- **One chat cannot make another chat act.** Hooks fire on a session's own
  activity, so there is no way to inject a turn into an idle interactive session,
  and "coordinate between yourselves and both get to main" is therefore not
  something this can be made to do. What it does instead is remove the reason you
  were asking: `agentbus merges` answers the question for free, and `agentbus
  integrate` starts a session of its own — which can be driven, because agent-bus
  created it.
- **`integrate` is a rail, not a sandbox.** A worker cannot push to a configured
  remote and cannot close anybody's task, both enforced rather than requested. A
  determined `git push <literal-url>` would still get out; the rails are against
  the accident, which is the thing that actually happens.
- **The guards are only as good as the config.** A resource nobody declared is a
  resource nobody guards, and a pattern that stops matching fails silently.
  `agentbus doctor` reports resources that have never matched, which is the only
  way to notice.
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
- **Windows is verified but young.** Two sessions were run on Windows 10 with a
  Turkish locale and an embeddable Python; presence, messaging, locks, the
  ownership guard, `here`, `status`, `serves` and session renaming all behaved.
  What that run also found is fixed here: a marketplace install patched the
  clone rather than the cache copy Claude Code loads, so every hook died while
  the installer reported success; a UTF-8 BOM on a payload turned a guard off
  silently; and the console mangled every non-ASCII message. After a
  `claude plugin update`, re-run the installer — the cache path carries the
  version, so a bump leaves a fresh unwired copy.

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

## Requirements

Python 3.8+. Bash for the fast path, or Python-only hooks without it. macOS and
Linux verified. Windows 10 verified but young — see Limits for exactly how far
that run got, and note that the hook cost in the table above has not been
re-measured there since the 2.1.0 refactor.

## License

MIT.
