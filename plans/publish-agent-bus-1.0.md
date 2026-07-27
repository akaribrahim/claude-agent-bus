# Turn agent-bus into a published 1.0 plugin that stops agents interfering with each other

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`,
`Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

Maintained in accordance with the exec-plan skill. Note that the skill file contains a
section of conventions for a mobile/FastAPI private product repository; **none
of that applies here**. This repository is a standalone Claude Code plugin written in
Python and bash, with no database, no web framework and no mobile app.

## Purpose / Big Picture

Today a developer can run three or four Claude Code sessions on one machine and they will
quietly ruin each other's work. Not by overwriting files — separate git worktrees already
prevent that — but in two subtler ways that people hit constantly and complain about
publicly:

1. **The shared service lies about whose code it is running.** A dev server started from
   worktree A keeps answering on `:8000` while you work in worktree B. Your fix "doesn't
   work", or your test suite goes green against somebody else's branch. Nothing warns you.
2. **Agents are helpful at the wrong moment.** Session B runs the build, sees a type error
   caused by session A's half-finished edit, and "fixes" a file it does not own. Now both
   sessions are fighting over the same file and neither knows why.

This repository already solves (1). `agent-bus` is installed as a Claude Code plugin; it
registers every session on the machine, tracks which checkout each declared service is
actually serving, and blocks a command aimed at a service serving somebody else's tree.
That part works and is in daily use.

What this plan adds is (2), plus the three things that turn a working personal tool into
something a stranger can install and benefit from within five minutes:

- an **interference guard** that recognises, from a failing command's own output, that the
  files being blamed belong to another live session, and tells the agent not to touch them;
- **declared ownership**, so an agent can say "I own `src/api/**`" and other sessions are
  stopped from drifting into it, instead of everyone maintaining "never touch" lists by hand;
- an **automatic handoff summary** at session end, so the next agent reads what happened
  instead of re-deriving it;
- **zero-configuration detection**, so a fresh repository gets a useful draft config instead
  of an empty template — today a stranger installs the plugin, sees nothing happen, and
  concludes it is broken;
- a **test suite in the repository** and a **marketplace entry**, so the thing can be
  installed with one command and changed without fear.

After this plan, someone who has never seen this project can run

    claude plugin marketplace add akaribrahim/claude-agent-bus
    claude plugin install agent-bus

open two Claude Code sessions in two worktrees of their own repository, run
`agentbus init-repo`, and immediately observe: each session naming the other at startup; a
`curl` against a dev server serving the wrong checkout being refused with an explanation;
and a session that reads somebody else's build error being told, in its own context, not to
fix it.

## Progress

- [ ] (M1) Test harness in the repository — `tests/run.sh`, isolated state, current
      behaviour locked in green before anything changes.
- [ ] (M2) Interference guard — a failing command whose output blames another live
      session's files produces a "do not fix these" note instead of a repair attempt.
- [ ] (M3) Declared ownership — `agentbus own` / `disown`, enforced in `PreToolUse`,
      shown in the roster and in `status`.
- [ ] (M4) Handoff summary — `agentbus handoff` and an automatic summary at session end,
      delivered into the other sessions' context.
- [ ] (M5) Zero-config detection — `agentbus init-repo` reads the repository and drafts a
      real config with real ports and start commands.
- [ ] (M6) Package and publish 1.0 — marketplace entry, rewritten README with a real
      transcript, CHANGELOG, clean-clone install verified on this Mac.
- [ ] (M7) Community distribution — submissions to plugin directories, a short write-up
      and a recorded demo.
- [ ] (post-1.0) Windows verification on the author's work machine; README claim upgraded
      from "unverified" to "verified" or bugs filed.
- [ ] (M8, 1.1) Per-worktree port allocation in the plugin — `agentbus port` / `agentbus env`.
- [ ] (M9, 1.1) Wire the author's private product repository to per-worktree ports (separate pull request
      in that repository).

## Surprises & Discoveries

- Observation: the pre-filter that decides whether the Python engine is worth waking was
  taking the longest literal run in each regex, which for `git\s+(checkout|add|cherry-pick)`
  is `cherry-pick` — a string almost no matching command contains. Every guard whose
  distinguishing words lived inside an alternation was silently dead.
  Evidence: `git add -A` took no lock in a live session; fixed in commit `768f183` by taking
  literals from outside the groups, or one literal per branch when there is nothing outside.

- Observation: two independent reviews of the pre-1.0 code found that a check performed
  outside the mutex had its answer discarded, so two sessions issuing a guarded command in
  the same tick both proceeded.
  Evidence: 60 of 60 concurrent pairs were both allowed before the fix; 40 of 40 now yield
  exactly one denial.

## Decision Log

- Decision: 1.0 ships the interference guard, ownership, handoff, zero-config detection,
  tests and the marketplace entry. Per-worktree ports and shared/exclusive (reader/writer)
  locks are deferred to 1.1.
  Rationale: ports require changes inside each consuming repository, so they cannot be
  verified end-to-end without also editing an unrelated product repository. Everything in
  1.0 is verifiable inside this repository alone.
  Date/Author: 2026-07-27, Ibrahim + Claude.

- Decision: publish 1.0 verified on macOS only. Windows support stays in the code and is
  marked "implemented, not verified" in the README until it is exercised on real hardware.
  Rationale: claiming verification we have not performed is worse than an honest gap, and
  the author's Windows machine is not available during this work.
  Date/Author: 2026-07-27, Ibrahim + Claude.

- Decision: keep the messaging and presence layer as it is and invest nothing further in
  it, rather than replacing it with an existing peer-messaging MCP server.
  Rationale: several tools already do machine-local agent-to-agent messaging, one with
  substantial adoption. Ours is already built, costs nothing at rest, needs no background
  daemon, and — the part that matters — is wired into the block messages, which is where
  the plugin earns its keep. Competing on messaging would be rebuilding a solved problem.
  Date/Author: 2026-07-27, Ibrahim + Claude.

- Decision: ownership violations deny inside one checkout and warn across worktrees, unless
  the owner passes `--strict`.
  Rationale: two sessions editing the same path in different worktrees is what branches are
  for; denying it would be wrong and would train agents to distrust the tool. Inside one
  checkout it is a genuine overwrite.
  Date/Author: 2026-07-27, Ibrahim + Claude.

## Outcomes & Retrospective

To be written at the end of M6 (1.0 published) and again at the end of M9.

## Context and Orientation

### What this repository is

`claude-agent-bus` is a Claude Code plugin. Its working copy lives at
`~/.claude/skills/agent-bus`, and it is published at
`https://github.com/akaribrahim/claude-agent-bus` under MIT. A folder under a Claude Code
*skills directory* that contains a `.claude-plugin/plugin.json` manifest is loaded as a
plugin named `<folder>@skills-dir` in every project on that machine, with no marketplace and
no install step, and it is discovered **in place** rather than copied — so editing a file
here changes behaviour immediately. That is why the working copy and the git checkout are
the same directory.

### The files that exist today

    .claude-plugin/plugin.json   plugin manifest: name, version, description
    SKILL.md                     the instructions the model reads (the agent-facing protocol)
    README.md                    the human-facing documentation
    LICENSE                      MIT
    hooks/hooks.posix.json       hook wiring that calls bin/ab-hook (shells present)
    hooks/hooks.python.json      hook wiring that calls Python directly; __PYTHON__ is
                                 substituted by the installer (Windows / no bash)
    hooks/hooks.json             GENERATED by the installer, git-ignored, never edit by hand
    bin/ab-hook                  bash "fast path", ~125 lines
    bin/agentbus                 the Python engine and CLI, ~2400 lines
    install.sh / install.ps1     thin wrappers that find a Python and run `agentbus install`
    .gitignore                   ignores hooks/hooks.json, __pycache__, .DS_Store

### How it runs

Claude Code fires *hooks* — external commands — at points in a session. This plugin wires
six events (see `hooks/hooks.posix.json`): `SessionStart`, `UserPromptSubmit`, `PreToolUse`
(matching `Bash|Edit|Write|NotebookEdit`), `PostToolUse` (two entries: one matching
`Edit|Write|NotebookEdit`, one matching `Bash`), `PostToolBatch`, and `SessionEnd`.

Each hook receives a JSON object on standard input containing at least `session_id`, `cwd`,
`hook_event_name`, and — for tool events — `tool_name`, `tool_input`, `tool_use_id` and
(after the fact) `tool_response`. A hook may print JSON on standard output to influence the
session. The two shapes this plugin uses are:

    {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                            "permissionDecision": "deny",
                            "permissionDecisionReason": "…text the agent reads…"}}

    {"hookSpecificOutput": {"hookEventName": "PostToolBatch",
                            "additionalContext": "…text injected into the agent's context…"}}

**Two invariants that must never be broken.** A hook must always exit 0 — a non-zero exit
code of 2 blocks the tool call, and any crash in this plugin must never be the reason a
user's session breaks. And a hook must print either nothing or valid JSON; a stray `print`
inside a helper function corrupts the session's view of the hook result.

`bin/ab-hook` is a bash script that runs first and does almost nothing. It reads a counter
file to learn how many sessions are live, and when the answer is fewer than two it exits
immediately — about four milliseconds, using shell builtins only, without even reading the
payload. Only when something could plausibly matter does it exec `bin/agentbus hook <event>`,
which costs about thirty milliseconds. On hosts without bash (Windows without Git Bash) the
installer wires the hooks straight to Python and there is no fast path.

### Where state lives

All runtime state is under `~/.claude/agent-bus/`, never inside this repository, so updating
the plugin never loses it. The environment variable `AGENTBUS_HOME` overrides that path, and
**every test in this plan must set it** so tests never touch the author's live sessions.

    sessions/<sid>.json   one live session: agent name, worktree root, branch, pid
    sessions/<sid>.beat   empty file whose modification time is the last sign of life
    cursors/<sid>         highest event id this session has already been shown
    hot-for/<sid>         paths other live sessions wrote lately (the shell pre-filter)
    writes/<sid>.log      lines of "<epoch> <absolute path>" per write
    locks/<key>.json      one held resource
    autoclaim/<id>.json   what one in-flight command took automatically
    serves/<key>.json     which worktree a service is being served from, and by whom
    matched/<key>         empty file whose mtime is when a resource last matched a command
    repos/<key>.json      machine-local resource config override
    events.jsonl          append-only stream of everything anyone said or did
    events.seq            id of the last event; the shell fast path compares it to cursors
    live-count            number of live sessions; 1 means every hook short-circuits
    guard-tokens          one regular expression of literals worth waking the engine for

### The resource configuration

Guarding is per-repository and opt-in. A repository declares what its sessions contend for
in `<repo root>/.claude/agent-bus.json`, committed so the guards travel to every worktree,
machine and collaborator. A machine-local file in `repos/` may override entries by name.

A resource entry looks like this:

    {
      "name": "server",
      "desc": "the dev API on :8000",
      "why": "The reloader watches the tree it was started in, so a request to :8000
              exercises whichever checkout owns it — not necessarily yours.",
      "hint": "`agentbus serve server` restarts it from your worktree.",
      "port": 8000,
      "cwd": "api",
      "start": "uvicorn app:api --reload --port 8000",
      "ready": "curl -sf localhost:8000/health",
      "implies": ["db"],
      "scope": "worktree",
      "patterns": ["\\buvicorn\\b", ":8000\\b"]
    }

`patterns` are regular expressions matched against a command's **argv**, never against
prose: `strip_heredocs` removes heredoc bodies, `split_segments` splits on unquoted `;`,
`&&`, `||`, `|` and newlines, `tokens_of` tokenises with `shlex`, and `command_targets`
drops any token containing whitespace, on the reasoning that a token with spaces in it is a
message rather than a target. `bash -c '…'` recurses into its argument. This is why
`git commit -m "restart uvicorn"` does not claim the server.

`port`/`cwd`/`start`/`ready` let the plugin own the service lifecycle, which is what lets it
answer "which checkout is this serving". Without them a resource is a plain mutex.

`scope: "worktree"` makes a resource contended only by sessions sharing one checkout — used
for the working tree and git index.

### The functions you will be changing

All in `bin/agentbus` unless stated otherwise.

Session lifecycle: `register`, `load_sessions`, `forget_session`, `refresh_derived`,
`current_session`, `hook_session_start`, `hook_session_end`.

Events and delivery: `emit`, `read_events`, `interesting_to`, `deliver`, and the module
constant `DELIVERED_KINDS`, which is the set of event kinds worth interrupting another
agent's turn for (today `{"note", "serve"}`).

Guarding: `hook_pre_tool`, `guard_bash`, `guard_file`, `serving_check`, `deny`, `note_ctx`,
`resources_for`, `command_targets`.

Per-command claims: `remember_autoclaim`, `hook_post_bash`, `do_claim`, `do_release`.

Writes: `hook_record_write` (a Python fallback; the bash fast path normally records writes
itself), `recent_writes`, `rebuild_hot`.

Formatting: `roster_text`, `locks_text`, `short_path`, and the module constant `RULES`,
which is the paragraph injected at session start telling the agent how the system works.

CLI: `main` dispatches on the `COMMANDS` dictionary; hooks dispatch on `HOOKS`. Existing
commands are `status`, `whois`, `claim`, `release`, `wait`, `post`, `note`, `inbox`, `run`,
`serve`, `serves`, `name`, `doing`, `init-repo`, `doctor`, `register`, `install`, `forget`.

### Terms used in this plan

**Session** — one running Claude Code process, interactive, driven by a human in a terminal.
Not a subagent and not a Claude Code "teammate".

**Worktree** — a git working directory. One repository can have several, each on its own
branch, sharing one `.git` directory. Claude Code creates them under `.claude/worktrees/`
when asked, or you create them with `git worktree add`.

**Checkout** — used interchangeably with worktree in this document.

**Fast path** — `bin/ab-hook`, the bash script that decides in a few milliseconds whether
the Python engine needs to run at all.

**Guard** — a `PreToolUse` decision that stops a tool call and explains why.

## Plan of Work

### M1 — A test harness, before anything else changes

Nothing in this plan is safe to build until the current behaviour is pinned down, because
every milestone touches hook code that runs in every session on the machine. This milestone
adds a `tests/` directory and a runner, ports the ad-hoc scripts used during development
into it, and requires them green before any behavioural change.

Create `tests/run.sh`. It must set `AGENTBUS_HOME` to a temporary directory it creates and
deletes, so the author's live sessions are never touched; it must build throwaway git
repositories and worktrees in a temporary directory; and it must exit non-zero if any
assertion fails, printing which one. It takes an optional filter argument so a single test
file can be run alone.

Create `tests/lib.sh` with the helpers every test needs: `ab_hook <event> <json>` to feed a
synthetic payload to `bin/ab-hook`; `ab <args…>` to run the CLI as a given session by setting
`AGENTBUS_SESSION`; `assert_deny`, `assert_allow`, `assert_contains`, `assert_equal`; and
`make_repo` / `make_worktree` to build fixtures.

Create these test files:

`tests/test_matcher.py` — a Python test that loads the engine with
`importlib.machinery.SourceFileLoader` (the engine has no `.py` extension) and asserts, for
a fixture config, exactly which resources each command matches. It must cover: a plain
`curl` against a declared port matches; a quoted URL still matches; `bash -c '…'` recurses;
a commit message naming a tool matches nothing; a pull-request body naming a tool matches
nothing; a heredoc body naming a tool matches nothing; `grep -rn <tool>` matches nothing;
`git status` and `git log` match nothing while `git stash` and `git add -A` match the
worktree resource; and a command that the engine guards is always also matched by the
literal pre-filter derived from the patterns (this is the invariant that broke once and must
never break again).

`tests/test_locks.sh` — two sessions; a guarded command takes a lock; the lock is released
when the command's `PostToolUse` fires; the second session is denied while the first holds
it; forty concurrent pairs produce exactly one denial each.

`tests/test_serving.sh` — builds a real repository with two worktrees, each containing a
file that says which tree it is, and a resource whose `start` is `python3 -m http.server` on
an unused high port. Asserts: after `agentbus serve`, the port answers with worktree A's
file; a session in worktree B is denied even though no lock is held; after B runs
`agentbus serve`, the port answers with B's file; `agentbus run` hands over and executes in
one step.

`tests/test_solo.sh` — with one live session, a `PreToolUse` payload for a guarded command
produces no output, and twenty invocations of the fast path complete in under 400 ms total.

Add `make test` via a small `Makefile` whose `test` target runs `tests/run.sh`, and a
`.github/workflows/test.yml` that runs it on `ubuntu-latest` and `macos-latest` for pushes
and pull requests. The Linux job proves the code is not accidentally macOS-only.

### M2 — The interference guard

This is the mechanism that addresses the most commonly reported failure in parallel-agent
setups: a session reads a build or test failure caused by another session's in-flight edit
and "helpfully" repairs a file it does not own.

Two parts, one cheap and one novel.

The cheap part: extend the `RULES` paragraph injected at session start so that, whenever
another session is live, the agent is told plainly: *if a build or test failure names files
you did not edit, do not fix them — another session is probably mid-edit; wait and re-run.*

The novel part, which only this plugin can do because only it knows who touched what and
when: after a Bash command completes, inspect its output. If the output looks like a failure
and mentions a path that another live session wrote in the last few minutes, inject a note
naming the file, the session that owns it and how long ago they touched it.

Implementation. In `bin/ab-hook`, the `post-bash` branch currently execs the engine only
when an auto-claim file exists. Remove that condition: when two or more sessions are live,
`post-bash` always runs the engine. The cost is one engine start (about thirty milliseconds)
per Bash tool call, and only while somebody else is working.

In `bin/agentbus`, extend `hook_post_bash` so that after releasing the command's automatic
claims it calls a new function `interference_note(me, tool_response, sessions)`. That
function returns text or an empty string, and `hook_post_bash` prints it as
`additionalContext` for `hookEventName: "PostToolUse"`.

`interference_note` must be conservative — a false accusation is worse than silence:

- Return immediately unless the output matches a failure signal. Use a single compiled
  regular expression covering the common shapes: `error`, `Error`, `ERROR`, `FAILED`,
  `FAIL:`, `Traceback`, `Exception`, `✗`, `error TS`, `SyntaxError`, `cannot find`,
  `Cannot find`, `undefined reference`, `panic:`.
- Collect the recent writes of every **other** live session using the existing
  `recent_writes(sid, cutoff)` with a cutoff of five minutes — deliberately shorter than the
  fifteen-minute collision window, because we are claiming "right now".
- For each such path, test whether the output mentions it: the absolute path, the path
  relative to the writing session's root, or the basename **when the basename is at least
  six characters long and contains a dot** (so `main.py` counts and `x.ts` does not, which
  keeps common short names from producing false hits).
- Report at most three files, naming the session and how long ago it wrote each.
- If the current session also wrote one of those files inside the window, drop it: the
  failure may legitimately be its own.

The note must tell the agent what to do instead, in this shape:

    agent-bus: this failure names files another live session is editing right now:
      api/shared/features/userprofile/service.py — messages-scope, 40s ago
    Do not fix them. That session is mid-edit and the error is probably transient;
    re-run the command in a moment. If it persists, ask rather than edit:
      agentbus post --to messages-scope "your edit to service.py breaks my build — done soon?"
    Fix only files you own.

Tests: `tests/test_interference.sh` builds two sessions in one worktree, has session A
record a write to a file, then feeds session B a `PostToolUse` payload whose `tool_response`
contains a compiler error naming that file, and asserts the note appears and names A.
A second case asserts that a *successful* command output mentioning the same file produces
nothing, and a third asserts that a failure naming a file **A did not write** produces
nothing.

### M3 — Declared ownership

Today the file guard is reactive: it blocks a write to a file another session touched in the
last fifteen minutes. People running several agents report that the reliable pattern is the
opposite — declare scope up front, and prefer stating what an agent must *not* touch. This
milestone makes that a first-class, enforced thing instead of a paragraph in `CLAUDE.md`.

Add state: `owns/<sid>.json`, a JSON object `{"globs": [{"glob": …, "why": …, "at": …,
"strict": true|false}]}`. Add `OWNS = os.path.join(BUS, "owns")` to the path constants and
to `ensure_dirs`. `forget_session` must delete the file, so ownership dies with the session.

Add CLI verbs to `COMMANDS`:

- `agentbus own "<glob>" [--why "…"] [--strict]` — claim a scope. Multiple globs may be
  given. Prints what is now owned.
- `agentbus own --list` — show every live session's ownership, marking your own.
- `agentbus disown "<glob>" | --all` — release.

Globs are matched with `fnmatch.fnmatch` against the path **relative to the repository
root**, after `os.path.realpath`. Document in `SKILL.md` and `README.md` that `*` matches
across directory separators here, so `src/*` covers `src/a/b.ts`; this is a deliberate
simplification and must be stated rather than left to be discovered.

Enforcement goes in `guard_file`, before the existing recent-writes check, in a new function
`ownership_verdict(me, path, sessions)` returning `("deny"|"note"|"", text)`:

- If **I** own the path, allow silently — an explicit claim is the way out of any block.
- If another live session owns it and shares my worktree root, deny.
- If another live session owns it in a different worktree, note it, unless their claim was
  `--strict`, in which case deny.

The deny text must name the owner, their branch, the glob they claimed, their `--why`, and
offer the two real ways forward: ask them (`agentbus post --to <agent> "…"`), or take it if
they have agreed (`agentbus claim 'file:<path>' --why "agreed with <agent>"`, which the
existing file-lock override already honours).

Surface it: `roster_text` gains an `owns:` line per session, and `cli_status` prints an
ownership section. `hook_session_start` therefore shows a new session, at startup, exactly
which parts of the tree are spoken for.

Tests: `tests/test_ownership.sh` — same worktree deny; different worktree note; different
worktree with `--strict` deny; owner writes freely; `disown` restores; ownership disappears
when the session ends.

### M4 — Handoff summary

When a session finishes, what it learned is lost unless a human copies it forward. This
milestone writes that summary automatically and delivers it to the sessions still running.

Add a function `handoff_text(me)` that assembles, from state this plugin already has: the
branch and worktree; the number of files written and the most recent ten, as repository-
relative paths; any resources this session currently serves; the last `doing` line; and the
count of commands that took a guarded resource (derive from `matched/` timestamps, or track
a counter in the session record — pick one and record the choice in the Decision Log).

Add `agentbus handoff [--note "…"]` to `COMMANDS`, which emits that text as an event of kind
`handoff` with the optional note appended.

Call it automatically from `hook_session_end`, before `forget_session`, but only when the
session actually did something — at least one recorded write or one lock taken — and only
when another session is live. A handoff nobody reads is noise.

Add `"handoff"` to `DELIVERED_KINDS` so it reaches the other sessions' context rather than
sitting in the log.

Tests: `tests/test_handoff.sh` — a session that wrote files and then ended produces a
handoff event; the other session receives it on its next `PostToolBatch`; a session that did
nothing produces no handoff; a solo session produces no handoff.

### M5 — Zero-configuration detection

A stranger installs the plugin, opens two sessions, and nothing happens, because their
repository has no `.claude/agent-bus.json` and `init-repo` writes a generic template they
must fill in by hand. This milestone makes the first run useful.

Replace the body of `cli_init_repo` with a detector, `detect_resources(root)`, that reads the
repository and returns draft resources with real values. It must handle, in this order, and
skip silently anything it does not find:

- `package.json` — `scripts.dev`, `scripts.start`, `scripts.serve`. Derive the port from an
  explicit `--port N` or `PORT=N` in the script; otherwise from the framework: `next` → 3000,
  `vite` → 5173, `expo` → 8081, `react-scripts` → 3000, `nest` → 3000. The `start` command is
  the package manager's run form; detect the manager from the lockfile (`bun.lock` → `bun run`,
  `pnpm-lock.yaml` → `pnpm run`, `yarn.lock` → `yarn`, otherwise `npm run`).
- `Makefile` — targets named `dev`, `dev-api`, `serve`, `start`, `run`. The start command is
  `make <target>`; look for a port in the recipe body.
- `Procfile` — one resource per line, using the process name.
- `manage.py` next to a `settings.py` → Django: `python manage.py runserver`, port 8000.
- `pyproject.toml` or `requirements.txt` mentioning `uvicorn` or `fastapi` → port 8000 and a
  `uvicorn` pattern.
- `docker-compose.yml`/`.yaml` — services whose image looks like `postgres`, `mysql`,
  `mariadb`, `redis`, `mongo` become a single `db` resource with no `start` (agent-bus must
  not restart somebody's database) and patterns for `psql`, `mysql`, `redis-cli`, `alembic`,
  `prisma migrate`, `make seed`.
- End-to-end runners — a `playwright.config.*`, `cypress.config.*`, or a `maestro/` directory
  becomes an `e2e` resource with `implies` pointing at every detected server.
- Always emit the universal `worktree` resource with `scope: "worktree"` and patterns for git
  write subcommands and package installs. Every repository has one, and it costs nothing when
  only one session is live.

`init-repo` then prints what it found, in plain language, before writing:

    agent-bus: looked at this repository and found

      server   :3000   bun run dev            from package.json scripts.dev
      db               (no start command)     from docker-compose.yml (postgres:16)
      e2e              implies server         from playwright.config.ts
      worktree         this checkout's tree and index

    Wrote .claude/agent-bus.json. Read it, fix anything wrong, then commit it so every
    worktree and machine gets the same guards. `why` and `hint` are empty — filling them in
    is what stops an agent working around a block.

Keep `--local` (machine-only override) and add `--force` (overwrite an existing file) and
`--dry-run` (print, write nothing).

Tests: `tests/test_detect.sh` — build fixture repositories (a Next.js-shaped one, a
FastAPI-shaped one, one with a compose file, one empty) and assert the detected resource
names, ports and start commands; assert an empty repository still gets a `worktree` resource;
assert `--dry-run` writes nothing.

### M6 — Package, document, and publish 1.0

The work becomes a product here.

Add `.claude-plugin/marketplace.json` at the repository root so the repository is itself a
single-plugin marketplace and can be installed with two commands. Verify the schema by
actually running the install flow rather than trusting this plan's memory of it:

    claude plugin marketplace add akaribrahim/claude-agent-bus
    claude plugin install agent-bus

If the schema differs from what you wrote, fix the file and record the real shape in
`Artifacts and Notes`.

Rewrite `README.md` around the two failures in the Purpose section, in this order: the
problem told as a story a reader recognises; a **real transcript** of a block, copied from an
actual run rather than invented; installation; the configuration schema; the commands; how
it works; what it costs; and the limits, stated plainly — one machine only, no push into an
idle session, guards are only as good as the config, Windows implemented but unverified.

Add `CHANGELOG.md` describing 0.1, 0.2 and 1.0 in terms of behaviour rather than commits.

Set `version` to `1.0.0` in `.claude-plugin/plugin.json`.

Then verify the stranger's path on this Mac, which is the acceptance for this milestone:
clone the repository into a temporary directory with a temporary `HOME`, run the installer,
run `agentbus doctor`, and confirm it reports hooks installed, the command on `PATH`, and no
resources configured. Then run `agentbus init-repo` in a fixture repository and confirm the
detector output. This proves the experience of somebody who has never seen the project.

### M7 — Community distribution

Submit the plugin to the community directories that index Claude Code plugins and skills.
Write a short post — the same story as the README's opening, plus the transcript — and record
a demo: two terminals, a block, a handover, thirty seconds. Link both from the README.

Keep this milestone deliberately small. Discovery is worth doing once the thing is good, and
not before.

### M8 and M9 — 1.1, per-worktree ports

Not part of 1.0. `agentbus port <resource>` returns a deterministic port derived from the
worktree path so two checkouts never collide; `agentbus env` prints shell exports for every
declared resource; `serve`, `serving` and `serving_check` use the per-worktree port instead
of the declared one when allocation is enabled. Then, in a separate pull request against a
private product repository, its `Makefile`, `.env` handling and the mobile apps' API base URL are
wired to those variables, which is the only way to prove the design end to end.

## Concrete Steps

Work from the repository root:

    cd ~/.claude/skills/agent-bus

Before starting any milestone, confirm the tree is clean and the plugin still loads:

    git status --short
    ./bin/agentbus doctor

Expect `doctor` to print the bus directory, the live session count, which config is in force
for the current directory, and the path of the generated `hooks/hooks.json`. If it reports
`hooks: MISSING`, run `./install.sh` first.

After every change to `bin/agentbus`, before running anything else:

    python3 -m py_compile bin/agentbus && bash -n bin/ab-hook && echo OK

After M1 exists, the loop for every subsequent milestone is:

    make test                      # everything green before you start
    …make the change…
    make test                      # everything green after, including the new tests

To exercise a change by hand without touching live sessions, always isolate the state:

    export AGENTBUS_HOME=$(mktemp -d)/bus

Changes to `bin/agentbus` and `bin/ab-hook` take effect immediately in every running session
on the machine, because the hooks execute the files on disk. Changes to `hooks/*.json`,
however, are read when a session starts: after adding or removing a hook event you must run
`./install.sh` to regenerate `hooks/hooks.json`, and then `/reload-plugins` in each running
session, or the new event will not fire.

## Validation and Acceptance

Each milestone is accepted on observable behaviour, not on code having been written.

**M1** — `make test` exits 0 and prints one line per test file. Deliberately break one
pattern in the fixture config and confirm `tests/test_matcher.py` fails: a suite that cannot
fail proves nothing.

**M2** — In two real Claude Code sessions in one worktree: session A edits a file and leaves
it syntactically broken; session B runs the build. Session B's next turn contains a note
naming the file and session A, and B does not edit the file. The same build failure with the
file named by nobody produces no note.

**M3** — Session A runs `agentbus own "api/**" --why "backend rebuild"`. Session B, in the
same worktree, attempts an edit under `api/` and is denied, with A's name, branch and reason
in the message. Session B in a *different* worktree gets a note instead, and its edit
succeeds. `agentbus own --list` shows both. After A's session ends, B's edit is no longer
guarded.

**M4** — A session that wrote three files and served the API ends. The other session's next
turn contains a handoff naming the branch, the files and the service. A session that did
nothing ends silently.

**M5** — In a repository containing only a `package.json` with `"dev": "next dev"`,
`agentbus init-repo` writes a config containing a `server` resource with port 3000 and start
command `npm run dev`, plus a `worktree` resource, and prints the summary shown in M5. In an
empty directory that is a git repository, it writes only the `worktree` resource.

**M6** — From a temporary `HOME`, `claude plugin marketplace add akaribrahim/claude-agent-bus`
followed by `claude plugin install agent-bus` succeeds, and `agentbus doctor` in a fresh
shell reports the plugin installed. `git log --oneline -1` shows the 1.0.0 release commit.

## Idempotence and Recovery

Every step here is safe to repeat. `./install.sh` is idempotent: it rewrites
`hooks/hooks.json`, refreshes the `PATH` shim and adds the permission entry only if missing.
`agentbus init-repo` refuses to overwrite an existing config unless `--force` is passed.
`make test` creates and destroys its own state directory each run.

The one risky class of change is hook wiring, because a broken hook affects every session on
the machine. Two recoveries: set `AGENTBUS_OFF=1` in the environment, which makes both the
fast path and the engine no-op immediately; or delete `hooks/hooks.json` and restart the
sessions, which unwires the plugin entirely while leaving the CLI usable.

If a test leaves stray state behind, `AGENTBUS_HOME=<the temp dir> ./bin/agentbus forget
--stale` clears sessions, and the temp directory can simply be deleted.

Never delete anything under `~/.claude/agent-bus/sessions/` on a machine with live sessions:
those files are how running sessions identify themselves, and removing them makes each of
them invisible to the others until it re-registers.

## Artifacts and Notes

The block message the plugin produces today, from a real run, to be used verbatim in the
README (M6) and as the shape M2 and M3 messages should match:

    agent-bus: BLOCKED. "web" (the demo server on :8099) is serving a different checkout,
    so this command would exercise that code and report it as yours.

      serving   : …/scratchpad/repo/main
      you are in: …/scratchpad/repo/wt2
      started by: main-main, just now

      It serves the tree it was started in, so a request answers with THAT checkout's files.

    Point it at your worktree — this stops the current one and starts yours, and tells the
    other sessions it moved:
      agentbus serve web

Measured cost per hook invocation on an M-series Mac, to be repeated after M2 since that
milestone removes a gate:

    alone (live-count gate)                    ~4 ms
    two sessions, nothing shared touched       ~6 ms
    engine actually runs                       ~30 ms

## Interfaces and Dependencies

No new third-party dependencies. The engine uses only the Python standard library and must
keep working on Python 3.8. `hashlib`, `shlex`, `shutil`, `stat` and `subprocess` are
imported inside the functions that need them, not at module level, because every hook on
every tool call pays for the module's import list; keep it that way.

New module-level constants in `bin/agentbus`:

    OWNS = os.path.join(BUS, "owns")
    FAILURE_SIGNAL = re.compile(r"…", re.I)      # M2
    INTERFERENCE_WINDOW = 5 * 60                  # M2, seconds

New functions in `bin/agentbus`:

    def interference_note(me, tool_response, sessions):
        """Text warning that a failure names another live session's in-flight files,
        or "" when nothing applies."""

    def ownership_verdict(me, path, sessions):
        """("deny"|"note"|"", text) for an Edit/Write against declared ownership."""

    def handoff_text(me):
        """A summary of what this session did, for the sessions that outlive it."""

    def detect_resources(root):
        """Draft resource entries read from the repository's own files."""

    def cli_own(args): ...
    def cli_disown(args): ...
    def cli_handoff(args): ...

New files:

    Makefile                     a `test` target only
    tests/run.sh                 runner; isolates AGENTBUS_HOME; takes an optional filter
    tests/lib.sh                 assertions and fixture builders
    tests/test_matcher.py        argv matching and pre-filter invariant
    tests/test_locks.sh          per-command claims, contention, races
    tests/test_serving.sh        service ownership and handover
    tests/test_solo.sh           cost and silence when alone
    tests/test_interference.sh   M2
    tests/test_ownership.sh      M3
    tests/test_handoff.sh        M4
    tests/test_detect.sh         M5
    .github/workflows/test.yml   ubuntu-latest and macos-latest
    .claude-plugin/marketplace.json
    CHANGELOG.md

Files you will edit: `bin/agentbus`, `bin/ab-hook`, `hooks/hooks.posix.json`,
`hooks/hooks.python.json`, `SKILL.md`, `README.md`, `.claude-plugin/plugin.json`.

Files you must not edit by hand: `hooks/hooks.json` — it is generated by the installer and
git-ignored.
