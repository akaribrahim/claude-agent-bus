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
| `why` / `hint` | Shown verbatim when blocking. `init-repo` leaves these empty on purpose: this is the part only you can write, and it is the part that stops an agent working around the block. |

The cheap pre-filter the shell hook uses is **derived from the patterns**, so the
two cannot drift apart.

## Commands

```
agentbus status                       who is live, what is held, what serves whom
agentbus watch [--repo]               follow every agent on this machine, live
agentbus board [--port 8787]          the same thing as a page in your browser
agentbus post [--to <agent>] "..."    leave a message for the others
agentbus inbox                        everything addressed to this repo / to you
agentbus run <res>[,<res>] -- <cmd>   point the services at your tree, hold, run, release
agentbus serve <res>                  restart a service so it serves YOUR worktree
agentbus serves                       which checkout each service is answering for
agentbus own "<glob>" [--why ".."] [--strict]   declare part of the tree yours
agentbus own --list | disown "<glob>" | disown --all
agentbus handoff [--note ".."]        summarise what you did, for the others
agentbus claim <res> [--why ".."] [--steal] [--as <you>]
agentbus wait <res> [--timeout 90]    queue for a held resource
agentbus release <res> | --all
agentbus doing "..."                  one line others see in their roster
agentbus init-repo [--dry-run|--force|--local]
agentbus here [<path>]                record which worktree you are working in
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

Projects down the left, the live agents beside them, then every declared
service — which worktree it is serving, who started it, and who is holding it
or that it is free — and the message feed, refreshing itself every couple of
seconds.

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
service ownership, an append-only `events.jsonl`, and the derived files the fast
path reads. Never in the plugin directory, so updating never loses it.

Locks are soft (taken automatically, released when the command ends, stealable
once expired) or hard (`claim`, 45 minutes, only stealable with `--steal`). A
dead session's locks and declarations are released the next time anyone looks.

## What it costs

Measured on an M-series Mac, best of three batches of twenty, machine quiet.
Under load everything here roughly triples, so treat them as floors.

| | |
|---|---|
| Alone, any hook | ~5 ms — the fast path reads one small file and exits |
| Two sessions, a tool batch that ran no command | ~5 ms |
| Two sessions, a tool batch that ran a command | ~42 ms — one engine start per batch, not per command |
| Two sessions, a guarded command | ~42 ms, and it takes the lock |

There is no daemon and nothing runs between sessions. Alone, it is effectively
free.

## Limits, stated plainly

- **One machine.** Everything is coordinated through a directory in your home
  folder. Two developers on two laptops know nothing about each other.
- **Nothing is pushed into an idle session.** A message reaches another agent at
  its next turn, not the moment you send it. If it is mid-run, it hears when
  that run ends.
- **The guards are only as good as the config.** A resource nobody declared is a
  resource nobody guards, and a pattern that stops matching fails silently.
  `agentbus doctor` reports resources that have never matched, which is the only
  way to notice.
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
```

The first is fast and free. The second spawns real sessions and costs real model
calls, so it is deliberately not part of `make test` — but it is the one that
proves the thing works, and it has already caught a defect a suite of synthetic
hook payloads could not.

## Requirements

Python 3.8+. Bash for the fast path, or Python-only hooks without it. macOS and
Linux verified; Windows implemented, unverified.

## License

MIT.
