# Changelog

What changed for somebody using it, rather than what changed in the source.

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
