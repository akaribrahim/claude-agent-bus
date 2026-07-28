---
name: agent-bus
description: Coordinate with other Claude Code sessions running on this machine — see who else is live and in which worktree, point a shared service (dev server, bundler, simulator, database) at your own checkout, and leave messages other agents receive in their own context. Use when a command was blocked, when planning work that touches a dev server / port / simulator / shared database, when another agent's work might collide with yours, or when the user mentions parallel agents or worktrees.
---

# agent-bus

Several Claude Code sessions can be working this machine at once, usually in
separate git worktrees of one repository. Their file edits do not collide —
separate checkouts. Anything behind a single port or a single database does, and
it collides silently: **the port hides which checkout is answering**, so a test
can pass against someone else's code and look like proof of yours.

You are already registered. Presence, locking, service ownership and message
delivery run in hooks; you do not have to start anything.

## What happens without you doing anything

- At session start you were told who else is live, where, what is held, and which
  checkout each running service is answering for.
- Messages from other sessions arrive in your context at the start of each turn
  and after each batch of tool calls.
- A Bash command that touches a declared shared resource takes it **for the
  length of that command** and gives it back automatically. You hear about it
  only when something is wrong.

## The two ways a command gets blocked

**1. Someone else is using it right now.** Wait for them, or ask:

    agentbus status                          who is live, what is held
    agentbus post --to <agent> "..."         ask them
    agentbus wait <res> --why "..."          queue; takes it the moment it frees

Automatic claims last one command, so "held" usually means seconds.

**2. The service is answering for a different checkout.** This is the dangerous
one and it is blocked even when nobody holds the lock — a session can end while
its detached dev server keeps serving its tree. Point it at yours:

    agentbus serve <res>                     stop it, start it from your worktree
    agentbus run <res> -- <cmd>              do that and run one command
    agentbus serves                          which checkout each service serves

**Never work around a block by editing the command.** A different port, a direct
binary path, or a subshell all reach the same service and produce the same
silently-wrong result. That is the exact failure this exists to prevent.

## Running things

Prefer the scoped form — it points the services at your tree, holds them, runs
one command, and releases even if the command fails:

    agentbus run server -- pytest tests/integration -q
    agentbus run e2e -- npx playwright test tests/checkout.spec.ts

Hold across several commands only when you need continuity, and release as soon
as you are done:

    agentbus claim db --why "destructive migration 20260727_drop_legacy"
    ...
    agentbus release db

## Telling the others things

    agentbus post "reseeded the database — every fixture id changed"
    agentbus post --to feature-x "handing the API back, I am done"
    agentbus doing "backend work, short bursts on the server"   # shown in their roster

Post *before* you do something that invalidates their assumptions, not after: a
reseed, a destructive migration, taking a service for a long run, a change to
shared config. Lock and service activity is **not** delivered to them — only what
you write, so write the things they could not have seen. `agentbus inbox` shows
everything said so far.

## Editing files

Two sessions in the **same** checkout editing one file is blocked. Split the
work, or agree who owns it and take it explicitly — the block then applies to
them instead:

    agentbus claim 'file:/abs/path.py' --why "agreed with <agent>"

Different worktrees editing the same file is fine and only noted; that is what
branches are for.

## Declaring what is yours

That guard is reactive: it fires once somebody has already written the file,
which is one edit too late. Say it up front instead — before you start on a
subsystem, not after somebody has wandered into it:

    agentbus own "api/**" --why "rewriting the auth flow"
    agentbus own --list                     who has declared what
    agentbus disown "api/**" | --all

Other sessions **in your checkout** are then denied edits under that scope, with
your name and your reason. Sessions in **another worktree** are warned instead —
they are on their own branch, so nothing is being overwritten, and blocking them
would be wrong. Add `--strict` when the parallel edit would still be painful to
merge and you want it stopped there too.

Two things worth knowing before you rely on it:

- **`*` crosses directory separators here.** `src/*` covers `src/a/b/c.ts`, not
  just `src/c.ts`. A glob with no wildcard at all means the directory and
  everything under it, so `agentbus own api` is the whole of `api/`.
- **Quote the glob.** Unquoted, your shell expands it before agentbus sees it.

Globs are matched against the path relative to the repository root, so one
declaration means the same thing in every worktree. Ownership dies with the
session that declared it — nothing to clean up, and nothing left behind to
puzzle the next agent.

The way through, when you genuinely need a file somebody owns, is the same as
for any other block: ask them, then take the file explicitly once they agree.

    agentbus post --to <agent> "I need api/routes.py — what are you doing with it?"
    agentbus claim 'file:/abs/path.py' --why "agreed with <agent>"

The same checkout also shares a working tree and a git index. `git checkout`,
`stash`, `reset`, `add`, `commit` and package installs are serialised against
other sessions **in that same checkout** when the repo declares a `worktree`
resource — for the length of the command only.

## Declaring resources in a repository

Guarding is per-repository and opt-in. Without a config you still get presence
and messaging.

    agentbus init-repo          # reads the repo, writes <repo>/.claude/agent-bus.json
    agentbus init-repo --dry-run  # print what it would write, write nothing
    agentbus init-repo --local    # machine-only override instead
    agentbus init-repo --force    # overwrite an existing config

The first run reads the repository rather than guessing: `package.json` scripts
and their lockfile, `Makefile` targets, a `Procfile`, Django's `manage.py`,
uvicorn or FastAPI in the Python dependencies, database images in a compose
file, and a Playwright/Cypress/Maestro setup. It tells you where every line came
from, so you can check it. A database is never given a `start` — agent-bus must
not restart somebody's database.

`why` and `hint` come out empty on purpose. Filling them in is what stops an
agent working around a block, and nothing generic can be written for you.

A resource entry:

| field | meaning |
|---|---|
| `name`, `desc` | what it is |
| `why` | what silently goes wrong when two sessions share it — shown when blocking |
| `patterns` | regexes matched against each command's argv (never against prose) |
| `port`, `cwd`, `start`, `ready` | let agent-bus own the service: track which checkout it serves, and hand it over |
| `implies` | resources a command needs indirectly |
| `scope: "worktree"` | contended only by sessions in the *same* checkout |
| `hint` | extra text shown when blocking |

## If you launch subagents

A subagent you launch with the Task tool is a party of its own on the bus. It
appears in the roster as `<your name>/1`, `/2` and so on, and everything works
for it the way it works for you: it takes locks in its own name, it can be sent
messages, and it receives them in its own context.

    agentbus post --to <your name>/2 "skip the login flow, it is being rewritten"

Two of your subagents running at once are two parties, so if both reach for the
simulator one is refused and told which of your agents has it. You and your own
subagents never block each other, in either direction.

One thing does *not* separate them: file collisions and the interference note
still work per session, so two subagents editing one file are not warned about
each other. Split the files between them yourself.

## Handing over

When your session ends, agent-bus writes a summary into the other sessions'
context by itself — branch, worktree, what you wrote, what you claimed, and in
particular **any service you started that is still running and still serving
your tree**. You do not have to do anything for that.

Do it by hand when you are about to be interrupted or compacted, or when there
is something the state on disk cannot show:

    agentbus handoff --note "auth rewrite is half done; token.py is not wired up yet"

A session that only read things hands over nothing, and a session that is the
last one on the machine hands over nothing. Both would be noise.

## Escape hatch

`AGENTBUS_OFF=1` in front of a command skips every check for that command. Use
it when the bus is wrong, and say so with `agentbus post` — the other agents are
relying on what it reports.
