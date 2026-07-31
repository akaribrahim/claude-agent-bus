# Changelog

What changed for somebody using it, rather than what changed in the source.

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
