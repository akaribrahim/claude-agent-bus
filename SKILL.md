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

The same checkout also shares a working tree and a git index. `git checkout`,
`stash`, `reset`, `add`, `commit` and package installs are serialised against
other sessions **in that same checkout** when the repo declares a `worktree`
resource — for the length of the command only.

## Declaring resources in a repository

Guarding is per-repository and opt-in. Without a config you still get presence
and messaging.

    agentbus init-repo          # writes <repo>/.claude/agent-bus.json — commit it
    agentbus init-repo --local  # machine-only override instead

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

## Escape hatch

`AGENTBUS_OFF=1` in front of a command skips every check for that command. Use
it when the bus is wrong, and say so with `agentbus post` — the other agents are
relying on what it reports.
