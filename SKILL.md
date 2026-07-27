---
name: agent-bus
description: Coordinate with other Claude Code sessions running on this machine — see who else is live and in which worktree, hold a shared resource (dev server, bundler, simulator, database) for the length of a command, and leave messages other agents receive in their own context. Use when a shared-resource command was blocked, when planning work that touches a dev server / port / simulator / shared database, when another agent's work might collide with yours, or when the user mentions parallel agents or worktrees.
---

# agent-bus

Several Claude Code sessions can be working this machine at once, usually in
separate git worktrees of one repository. Their file edits do not collide —
separate checkouts. Anything behind a single port or a single database does
collide, and it collides silently: the port hides which checkout is answering,
so a test can pass against someone else's code and look like proof of yours.

You are already registered. Presence, locking and message delivery run in hooks;
you do not have to start anything.

## What happens without you doing anything

- At session start you were told who else is live, where, and what is held.
- New messages from other sessions arrive in your context at the start of each
  turn and after each batch of tool calls.
- A Bash command that touches a declared shared resource takes that resource
  automatically. You only ever hear about it when someone else holds it.

## When a command is blocked

The block reason names the holder, their worktree and branch, how long they have
held it, and why the resource matters. **Do not rewrite the command to get around
it** — a different port, a direct binary path, or a subshell all reach the same
service and produce the same silently-wrong result.

Instead, pick one:

    agentbus status                          who is live, what is held
    agentbus post --to <agent> "..."         ask them to hand it over
    agentbus wait <res> --why "..."          queue; claims it the moment it frees
    agentbus claim <res> --steal --why "..." only when you know they are done

`wait` also tells the holder that you are waiting, which is usually enough.

## Holding a resource on purpose

Prefer the scoped form — it takes the resource, runs one command, and releases it
even if the command fails or is interrupted:

    agentbus run server -- pytest tests/integration -q
    agentbus run e2e -- npx playwright test tests/checkout.spec.ts

Hold a resource across several commands only when you truly need continuity, and
release it as soon as you are done:

    agentbus claim db --why "destructive migration 20260727_drop_legacy"
    ...
    agentbus release db

Never hold anything for a whole milestone. Other agents queue behind you.

## Telling the others things

    agentbus post "reseeded the database — every fixture id changed"
    agentbus post --to feature-x "handing the API back, I am done"
    agentbus doing "backend work, short bursts on the server"   # shown in their roster

Post *before* you do something that invalidates other agents' assumptions, not
after: a reseed, a destructive migration, taking a service over for a long run, or
a change to shared config. That message lands in their context automatically; they
do not have to look for it.

Read what has been said so far:

    agentbus inbox

## Editing files

Two sessions in the **same** checkout editing one file is blocked — one of you
would silently overwrite the other. Split the work, or agree who owns the file
via `agentbus post`.

Two sessions in **different** worktrees editing the same file is allowed and only
noted; that is what branches are for. Expect it at merge time.

## Declaring resources in a repository

Guarding is per-repository and opt-in. A repo with no configuration gets presence
and messaging but no locks.

    agentbus init-repo          # writes <repo>/.claude/agent-bus.json — commit it
    agentbus init-repo --local  # machine-only override instead

Each resource entry needs `name`, `desc`, `why` (what silently goes wrong when two
sessions share it), `tokens` (plain substrings — the cheap pre-filter) and
`patterns` (regexes matched against each command segment). `implies` pulls in
resources a command needs indirectly. `hint` is shown in the block message and is
the place to say how to hand the service over.

Because the file lives in the repository, it reaches every machine and every
collaborator that clones it.

## Escape hatch

`AGENTBUS_OFF=1` in front of a command skips every check for that one command.
Use it when the bus is wrong, and say so afterwards with `agentbus post` — the
other agents are relying on what it reports.
