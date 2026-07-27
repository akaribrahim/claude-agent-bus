# agent-bus

A Claude Code plugin that lets parallel sessions on one machine see each other,
take turns on shared services, keep those services pointed at the right checkout,
and talk — automatically, in every project.

## The problem

You can run several Claude Code sessions at once, each in its own git worktree.
Their file edits never collide, because the checkouts are separate. Everything
behind a single port or a single database does collide, and it collides in the
worst possible way — silently:

- A reloading dev server watches the tree it was started in. Edit your worktree
  while another one owns the port, and your change never runs. The endpoint keeps
  its old behaviour and you conclude your fix does not work.
- A device or browser talks to whichever bundler answered first. Your end-to-end
  run comes back green having exercised someone else's branch.
- One development database, shared. An additive migration is fine; a reseed
  invalidates every id the other sessions are holding.

None of this announces itself. The port hides which checkout is answering.

A README explaining the rules does not fix it, because an agent has to remember
to read the README. This does, because the decision is made in a `PreToolUse`
hook: the command does not run, and the agent is told what is wrong and how to
fix it.

## What it does

| | |
|---|---|
| **Presence** | Every session registers itself. New ones open knowing who else is live, in which worktree, on which branch, and what is currently held. |
| **Locks** | A command touching a declared shared resource takes it **for the length of that command** and gives it straight back. If another live session has it, the command is denied with the holder, the worktree and what they are doing. |
| **Service ownership** | Separately from the lock, agent-bus tracks *which checkout each service is actually serving* — and blocks a command that would talk to somebody else's tree, even when the lock is free. `agentbus serve <res>` stops that service and starts it from your worktree. |
| **Declared ownership** | A session can say `agentbus own "api/**"` before it starts. Other sessions in that checkout are then denied edits under it, with the owner's name and reason; sessions in another worktree are warned instead, since they are on their own branch. Ownership dies with the session, so there is nothing to clean up. |
| **Interference guard** | When a Bash command fails and its output names a file another live session wrote in the last few minutes, the agent is told — by name, with the timestamp — not to fix it and to re-run in a moment. This is the one that stops an agent "helpfully" repairing somebody else's half-finished edit. |
| **Handoff** | When a session ends, a summary of what it did is written into the surviving sessions' context: branch, files written, resources claimed, and above all any service it started that is *still running and still serving its tree*. A session that only read things leaves quietly. |
| **Messages** | An append-only stream. What agents write to each other is delivered into their context at their next turn; lock churn is not, because nobody can act on it. |

## Install

Clone it where Claude Code looks for personal plugins, then run the installer:

```bash
git clone https://github.com/akaribrahim/claude-agent-bus ~/.claude/skills/agent-bus
~/.claude/skills/agent-bus/install.sh
```

Windows (PowerShell):

```powershell
git clone https://github.com/akaribrahim/claude-agent-bus $env:USERPROFILE\.claude\skills\agent-bus
powershell -ExecutionPolicy Bypass -File $env:USERPROFILE\.claude\skills\agent-bus\install.ps1
```

Then restart Claude Code. Update with `git pull`; re-run the installer only if
the hook set changed.

The installer picks this machine's hook entry point, puts `agentbus` on `PATH`,
and allowlists `Bash(agentbus:*)` so it never raises a permission prompt. It
requires Python 3.8+ and nothing else. Claude Code loads the plugin from
`~/.claude/skills/agent-bus` in **every** project — discovered in place, so edits
take effect without reinstalling.

## Declaring what is shared

Per-repository and opt-in. Without a config you get presence and messaging and no
locks, which is the right default for a project with nothing to contend for.

```bash
cd your-repo
agentbus init-repo     # reads the repo, writes .claude/agent-bus.json — check it, commit it
```

The first run reads the repository instead of writing a template you have to
fill in:

```
agent-bus: looked at this repository and found

  server     :3000   bun run dev                    from package.json scripts.dev
  db                 (no start command)             from docker-compose.yml (postgres:16)
  e2e                implies server                 from playwright config
  worktree           this checkout's tree and index
```

It reads `package.json` scripts and the lockfile that says which package manager
runs them, `Makefile` targets, a `Procfile`, Django's `manage.py`, uvicorn or
FastAPI in the Python dependencies, database images in a compose file, and
Playwright/Cypress/Maestro. Every line says where it came from so you can check
it. A detected database gets **no** `start`: agent-bus must never restart
somebody's database. `--dry-run` prints without writing, `--force` overwrites.

`why` and `hint` come out empty, deliberately — that is the part only you can
write, and it is the part that stops an agent working around a block.

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
| `scope: "worktree"` | Contended only by sessions in the *same* checkout. |
| `why` / `hint` | Shown verbatim when blocking. This is where the hard-won knowledge goes, and it is the part that stops an agent from working around the block. |

The cheap pre-filter the shell hook uses is **derived from the patterns**, so the
two cannot drift apart. Commit the file and every machine and collaborator gets
the same guards; `--local` writes a machine-only override that wins by name.

## Commands

```
agentbus status                       who is live, what is held, what serves whom
agentbus post [--to <agent>] "..."    leave a message for the others
agentbus inbox                        everything addressed to this repo / to you
agentbus run <res>[,<res>] -- <cmd>   point the services at your tree, hold, run, release
agentbus serve <res>                  restart a service so it serves YOUR worktree
agentbus serves                       which checkout each service is answering for
agentbus handoff [--note ".."]        summarise what you did, for the others
agentbus own "<glob>" [--why ".."] [--strict]   declare part of the tree yours
agentbus own --list                   who has declared what
agentbus disown "<glob>" | --all
agentbus claim <res> [--why ".."] [--steal]
agentbus wait <res> [--timeout 90]    queue for a held resource
agentbus release <res> | --all
agentbus doing "..."                  one line others see in their roster
agentbus init-repo | doctor | whois | forget <agent|--stale> | install
```

Ownership globs are matched against the path **relative to the repository
root**, so one declaration means the same thing in every worktree. Two
properties to know rather than discover:

- **`*` crosses directory separators.** `src/*` covers `src/a/b/c.ts`. A glob
  with no wildcard means that directory and everything under it, so
  `agentbus own api` is the whole of `api/`. This is `fnmatch`, not shell
  globbing, and the difference is deliberate — claiming `src/*` and getting only
  its immediate children is the surprising direction.
- **Quote the glob**, or your shell expands it before agentbus sees it.

`agentbus doctor` reports what is installed, which config is in force, which
services are running and for whom, and which resources have **never matched a
command** — the silent failure mode when a port moves.

## How it works

| Hook | Job |
|---|---|
| `SessionStart` | Register; inject the roster, held resources, running services, and anything unread. |
| `UserPromptSubmit` | Heartbeat; deliver new messages between turns. |
| `PreToolUse` | Take the resources a Bash command needs, or deny it — because someone holds them, or because the service is serving another checkout. Block an `Edit`/`Write` to a file another session has declared theirs, or is editing right now in the same checkout. |
| `PostToolUse` | Give back what a command took as soon as it finishes; record what was written. |
| `PostToolBatch` | Deliver messages; give back what a *failed* command took, since `PostToolUse` does not fire for those; and if something in the batch failed and blamed a file somebody else is mid-edit in, say so. |
| `SessionEnd` | Write the handoff, release everything, deregister. |

State lives in `~/.claude/agent-bus/` — sessions, cursors, locks, service
ownership, an append-only `events.jsonl`, and the derived files the shell fast
path reads. Never in the plugin directory, so updating never loses it.

Locks are soft (taken automatically, released when the command ends, stealable
once expired) or hard (`claim`, 45 minutes, only stealable with `--steal`). A
dead session's locks are released the next time anyone looks.

## What it costs

Measured on an M-series Mac, per hook invocation:

| | |
|---|---|
| You are the only live session | **~4 ms** — a `live-count` gate short-circuits in shell builtins before anything is read |
| Two sessions, command touches nothing shared | **~6 ms** — the literal pre-filter says no |
| Something to actually decide | ~30 ms — the Python engine runs |
| Windows (hooks call Python directly) | ~30 ms per tool call regardless; there is no shell fast path |

## Limits, stated plainly

- **One machine.** Sessions coordinate through a shared directory, so two
  computers do not — and do not need to: they share no ports and no database.
  Distribute the tool with git; the state stays local.
- **No push into an idle session.** Claude Code's `FileChanged` event carries no
  context and no decision, so messages are delivered at session start, at each
  user turn, and after each tool batch. In practice an agent learns the moment it
  tries to do something, which is when it matters.
- **A service agent-bus did not start** can only be attributed where the platform
  exposes a process's working directory — macOS and Linux, not Windows. There it
  is reported as unknown, with a warning, rather than guessed.
- **Guards are as good as the config.** A resource nobody declared is a resource
  nobody protects. `doctor` will tell you when one has never matched anything.
- **Windows is implemented but lightly tested.** The installer wires the hooks
  straight to Python there, so nothing depends on a shell being present.

## Requirements

Claude Code 2.1.140+ (skills-directory plugins) and Python 3.8+.

## License

MIT
