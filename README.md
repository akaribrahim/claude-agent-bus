# agent-bus

A Claude Code plugin that lets parallel sessions on one machine see each other,
take turns on shared services, and talk — automatically, in every project.

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
hook: the command does not run, and the agent is told who holds the resource and
how to get it.

## What it does

| | |
|---|---|
| **Presence** | Every session registers itself. New ones open knowing who else is live, in which worktree, on which branch, and what is currently held. |
| **Locks** | A command touching a declared shared resource takes it automatically. If another live session holds it, the command is **denied** with a real reason — holder, worktree, how long, and what goes wrong if you proceed. |
| **Messages** | An append-only stream, delivered into the other agents' context at their next turn. No polling, no file anyone has to remember to open. |

It costs nothing when you are alone: a `live-count` gate short-circuits every
hook, and on POSIX the fast path is ~5 ms of shell builtins. The Python engine
wakes only for a real message or a possible collision.

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

Then restart Claude Code. Update later with `git pull` (re-run the installer only
if the hook set changed).

The installer picks this machine's hook entry point, puts `agentbus` on `PATH`,
and allowlists `Bash(agentbus:*)` so it never raises a permission prompt. It
requires Python 3.8+ and nothing else. Claude Code loads the plugin from
`~/.claude/skills/agent-bus` in **every** project — it is discovered in place, so
edits take effect without reinstalling.

## Declaring what is shared

Guarding is per-repository and opt-in. Without a config you still get presence
and messaging; you just get no locks — which is the right default for a project
with nothing to contend for.

```bash
cd your-repo
agentbus init-repo     # writes .claude/agent-bus.json, then edit and commit it
```

```json
{
  "resources": [
    {
      "name": "server",
      "desc": "the dev API on :8000",
      "why": "The reloader watches the tree it was started in, so a request to :8000 exercises whichever checkout owns it — not necessarily yours.",
      "hint": "Restart it from your own checkout before you rely on the result.",
      "tokens": ["uvicorn", "8000"],
      "patterns": ["\\buvicorn\\b", ":8000\\b"]
    },
    {
      "name": "e2e",
      "desc": "the browser and the runner",
      "why": "One browser on this machine, and the run only means something against the server serving your checkout.",
      "implies": ["server"],
      "tokens": ["playwright"],
      "patterns": ["\\bplaywright\\b"]
    }
  ]
}
```

- `tokens` — plain substrings; a shell fast path uses them to decide whether the
  engine is worth waking at all. Cheap, never a false negative.
- `patterns` — regexes matched per command segment, after read-only heads
  (`grep`, `cat`, `git`, …) are skipped, so `grep -rn uvicorn src/` is a mention,
  not a use.
- `implies` — resources a command needs indirectly.
- `why` / `hint` — shown verbatim when a command is blocked. This is where the
  hard-won knowledge goes; it is the part that stops an agent from working around
  the block.

Commit the file and every machine and collaborator gets the same guards.
`agentbus init-repo --local` writes a machine-only override instead, and local
entries win over the repo's by name.

## Commands

```
agentbus status                       who is live, what is held, recent activity
agentbus post [--to <agent>] "..."    leave a message for the others
agentbus inbox                        everything addressed to this repo / to you
agentbus run <res>[,<res>] -- <cmd>   hold a resource for exactly one command
agentbus claim <res> [--why ".."] [--steal]
agentbus wait <res> [--timeout 300]   queue for a held resource
agentbus release <res> | --all
agentbus doing "..."                  one line others see in their roster
agentbus name [<new>]                 read or set this session's name
agentbus init-repo | doctor | whois | install | register
```

## How it works

| Hook | Job |
|---|---|
| `SessionStart` | Register; inject the roster, held resources, and anything unread. |
| `UserPromptSubmit`, `PostToolBatch` | Heartbeat; deliver new messages mid-work. |
| `PreToolUse` | Take the resources a Bash command needs, or deny it. Block an `Edit`/`Write` to a file another session is editing **in the same checkout**. |
| `PostToolUse` | Record what this session wrote, and push it into the other sessions' collision filters. |
| `SessionEnd` | Release everything and deregister. |

State lives in `~/.claude/agent-bus/` — sessions, cursors, locks, an append-only
`events.jsonl`, and the derived files the shell fast path reads. Never in the
plugin directory, so updating never loses it.

Locks are soft by default (taken automatically, expire after 15 minutes of
disuse, stealable once the holder goes idle) or hard (claimed explicitly, 45
minutes, only stealable with `--steal`). A dead session's locks are released the
next time anyone looks.

## Limits, stated plainly

- **One machine.** Sessions coordinate through a shared directory, so two
  computers do not — and do not need to: they share no ports and no database.
  Distribute the tool with git; the state stays local.
- **No push into an idle session.** Claude Code's `FileChanged` event carries no
  context and no decision, so messages are delivered at session start, at each
  user turn, and after each tool batch. In practice an agent learns the moment it
  tries to do something, which is when it matters.
- **It tracks ownership; it does not move services.** Nothing here restarts your
  dev server against your worktree. Put that command in the resource's `hint`.
- **Guards are as good as the config.** A resource nobody declared is a resource
  nobody protects.
- **Windows is implemented but lightly tested.** On POSIX the entry point is a
  bash fast path; on Windows the installer wires the hooks straight to Python, so
  nothing depends on a shell being present. `agentbus doctor` reports what got
  installed.

## Requirements

Claude Code 2.1.140+ (skills-directory plugins) and Python 3.8+.

## License

MIT
