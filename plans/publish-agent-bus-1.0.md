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

- [x] (M1) Test harness in the repository — `tests/run.sh`, isolated state, current
      behaviour locked in green before anything changes.
      Done 2026-07-27. `make test` → 5 files, 135 assertions, 0 failures, ~25s.
      Files: `Makefile`, `tests/run.sh`, `tests/lib.sh`, `tests/mkpayload.py`,
      `tests/check_syntax.py`, `tests/test_matcher.py`, `tests/test_locks.sh`,
      `tests/test_serving.sh`, `tests/test_solo.sh`, `.github/workflows/test.yml`.
      Proved able to fail: see Surprises & Discoveries.
- [x] (M2) Interference guard — a failing command whose output blames another live
      session's files produces a "do not fix these" note instead of a repair attempt.
      Done 2026-07-27. `make test` → 6 files, 214 assertions, 0 failures.
      `bin/agentbus`: `FAILURE_SIGNAL`, `INTERFERENCE_WINDOW`, `MAX_INTERFERENCE_FILES`,
      `response_text`, `repo_relative`, `output_mentions`, `interference_note`, rewritten
      `hook_post_bash`, extended `RULES`. `bin/ab-hook`: the auto-claim gate on `post-bash`
      removed. New `tests/test_interference.sh` (79 assertions). No hook event added or
      removed, so no `./install.sh` and no `/reload-plugins` were needed.
      **Redesigned 2026-07-28, because the real-session acceptance failed.** Claude Code does
      not fire `PostToolUse` for a tool call that errored, so the guard never ran for the one
      thing it exists for. The guard, and the release of a failed command's claim, both moved
      to `PostToolBatch`: new `batch_bash_output`, `release_batch_claims`, `release_autoclaim`;
      `hook_post_bash` is release-only again; `bin/ab-hook` has its auto-claim gate back and
      its `post-batch` branch wakes the engine only for a batch that actually ran a command.
      Acceptance now passes against two real Claude Code sessions — `tests/live/acceptance.sh`.
- [x] (M3) Declared ownership — `agentbus own` / `disown`, enforced in `PreToolUse`,
      shown in the roster and in `status`.
      Done 2026-07-27. `make test` → 7 files, 306 assertions, 0 failures.
      `bin/agentbus`: `OWNS`, `owns_path`/`load_owns`/`save_owns`, `normalise_glob`,
      `glob_matches`, `glob_prefix`, `owners_of`, `ownership_text`, `ownership_verdict`,
      `owns_summary`, `ownership_text_block`, `cli_own`, `cli_disown`; `rebuild_hot`,
      `guard_file`, `roster_text`, `cli_status`, `forget_session`, `ensure_dirs`,
      `repo_relative` (moved up from the M2 block) all extended. `bin/ab-hook` unchanged.
      New `tests/test_ownership.sh` (92 assertions). SKILL.md and README.md document the
      glob semantics. No hook event added or removed, so no `./install.sh` was needed.
      Acceptance verified against two real Claude Code sessions on 2026-07-28.
- [x] (M4) Handoff summary — `agentbus handoff` and an automatic summary at session end,
      delivered into the other sessions' context.
      Done 2026-07-28. `make test` → 8 files, 356 assertions, 0 failures.
      `bin/agentbus`: `bump_guarded`, `still_serving`, `did_something`, `handoff_text`,
      `cli_handoff`; `DELIVERED_KINDS` += `handoff`; `deliver` indents multi-line events;
      `hook_session_end` writes the summary before `forget_session`; `hook_post_batch` no
      longer gated on the live count; `positional` learned `--note`.
      `bin/ab-hook`: the live-count gate now exempts `post-batch` — see Surprises.
      New `tests/test_handoff.sh` (49 assertions). SKILL.md and README.md updated.
      No hook event added or removed, so no `./install.sh` was needed.
      Acceptance verified against two real Claude Code sessions on 2026-07-28.
- [x] Real-session acceptance harness — `tests/live/acceptance.sh [m2|m3|m4|all]`, 32
      assertions against Claude Code driven through its own CLI, on an isolated bus.
      Not part of `make test`: it costs real model calls and takes minutes.
- [x] (M5) Zero-config detection — `agentbus init-repo` reads the repository and drafts a
      real config with real ports and start commands.
      Done 2026-07-28. `make test` → 9 files, 430 assertions, 0 failures.
      `bin/agentbus`: `CONFIG_README`, `WORKTREE_RESOURCE`, `FRAMEWORK_PORTS`, `DB_IMAGES`,
      `lit`, `read_text`, `port_in`, `package_manager`, `unique_name`, `detect_node`,
      `detect_make`, `detect_procfile`, `detect_python`, `detect_db`, `detect_e2e`,
      `detect_resources`, `detection_summary`, rewritten `cli_init_repo` with `--force` and
      `--dry-run`; `TEMPLATE` deleted. New `tests/test_detect.sh` (62 assertions).
      SKILL.md and README.md updated. Both acceptance cases in Validation run verbatim.
- [x] (M6) Package and publish 1.0 — marketplace entry, rewritten README with a real
      transcript, CHANGELOG, clean-clone install verified on this Mac.
      Done 2026-07-28. `make test` → 10 files, 452 assertions, 0 failures; live acceptance
      32/32. New `.claude-plugin/marketplace.json`, `CHANGELOG.md`, `tests/test_install.sh`;
      `hooks/hooks.json` now committed; README rewritten around the two failures with block
      messages copied from real runs; version 1.0.0. `bin/agentbus`: `install_hint_once`,
      the installer's location check, `doctor`'s command line, and `git_facts` on an unborn
      HEAD. Both halves of the Validation acceptance run from a temporary `HOME` against a
      real `git clone`.
      Pushed 2026-07-28, and the acceptance then run verbatim against GitHub: `claude
      plugin marketplace add akaribrahim/claude-agent-bus` followed by `claude plugin
      install agent-bus` in a temporary `HOME` installs 1.0.0 enabled with its hooks wired,
      and `agentbus doctor` in a fresh shell reports hooks installed, the command on PATH
      and no resources configured.
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

- Observation (M1): the suite was green on its first run, which proves nothing on its own,
  so five known-bad states were injected and each had to be caught. All five were, and the
  first two are the historical bugs above:
  (1) the pre-filter taking the longest literal run anywhere in a pattern, `768f183` — caught,
  4 assertions including `git add -A`;
  (2) `guard_bash` discarding `do_claim`'s answer, `c95399c` — caught by the 40-pair race
  assertion, and by nothing else;
  (3) a pattern in the fixture config pointed at the wrong port — caught, 2 assertions;
  (4) a hook printing a non-JSON line — caught, "hook pre-tool prints valid JSON";
  (5) a hook exiting 3 — caught, "hook pre-tool exits 0".
  Every injection was made in a copy of the tree under `$TMPDIR`, never in the working copy:
  three other Claude Code sessions were live and they execute `bin/agentbus` from disk on
  every tool call.

- Observation (M1): the first two injections were aimed at code the test I ran did not reach
  — the solo test exits at the `live-count` gate long before the `pre-tool` branch — and so
  reported success while the plugin was broken. Re-running them against `test_locks.sh`,
  which has two live sessions, caught both. Worth remembering when judging any later
  "the tests still pass": passing only means the paths the tests execute are intact.

- Observation (M1): the fast-path cost assertion was flaky on the first attempt — 509 ms for
  20 calls against a 400 ms budget — because this Mac was running three other Claude Code
  sessions and the suite itself. Every source of noise can only make a batch slower, so the
  measurement is now the best of three batches rather than a single one. Best-of-three has
  been 60–90 ms for 20 calls, well inside the budget, over six consecutive runs.

- Observation (M1): `hooks/hooks.posix.json` and `hooks/hooks.python.json` express the same
  wiring in two different shapes — the event is the tail of a shell command line in one and
  the last element of an `args` array in the other — so nothing was stopping them drifting
  apart. The syntax gate now reduces both to the same structure and compares them, and
  compares the generated `hooks/hooks.json` against whichever source produced it, which is
  what makes "you forgot to re-run ./install.sh" a test failure rather than a silent no-op.

- Observation (M2): anchoring the failure signal as `\berrors?\b` — which reads like the
  careful choice — silently misses every Python failure. `ImportError`, `SyntaxError`,
  `TypeError` and `ValueError` have no word boundary before "error", so the guard would
  have stayed quiet for the single most common way a Python build fails. Caught by the test
  for a long basename, which failed for a reason that had nothing to do with basenames.
  The signal is now anchored only at the end (`errors?\b`), and the plan's own list is why:
  it enumerated both `Error` and `SyntaxError`, which only makes sense if a suffix counts.

- Observation (M2): the obvious optimisation for the removed gate — have `bin/ab-hook`
  grep the payload for a failure word before waking the engine, the way `pre-tool` greps
  for guard tokens — is slower, not faster, and measurably so. Bash's `read -r -d ''` is a
  byte-at-a-time builtin loop, so slurping the payload alone costs 6.8 ms at 200 bytes,
  18.6 ms at 30 KB and 84.8 ms at 200 KB, while the engine's flat cost is 38.8 ms however
  large the output is. The crossover is around 5 KB, which is well below a real build's
  output. So the plan's "always run the engine" is not merely the simpler choice, it is the
  faster one for anything but a trivial command, and the idea can be retired rather than
  left as a maybe.

- Observation (M2): a read-only smoke test of the new path against the live bus — four real
  sessions, real write logs, `AGENTBUS_DEBUG=1` — exited 0 and correctly produced no note.
  The other live session had seven writes inside the window and all of them were named in
  the synthetic failure output, but that session is working in a different repository, so
  the same-repository filter suppressed them. The first real-data exercise of that filter
  was an accident and it behaved.

- Observation (M3): the milestone as written would have shipped an ownership guard that
  almost never fired. `guard_file` is only reached when the shell fast path decides to wake
  the engine, and for `Edit`/`Write` that decision is `grep -qF -f hot-for/<sid>` against
  paths other sessions have *already written*. A declaration is precisely a statement about
  files nobody has written yet, so the engine would have been woken only after the owner had
  edited the file — one edit too late, which is the exact failure declaring scope up front
  exists to prevent. Fixed by having `rebuild_hot` also write the fixed leading text of every
  other session's declarations into `hot-for`, which reuses the existing grep instead of
  adding new shell logic. The first falsification confirms it: dropping that one line makes
  23 of 77 assertions fail.

- Observation (M3): a test can pass because the fast path exited, not because the engine
  agreed. "The owner writes freely" passed even with the self-exemption deleted, because a
  session's own declarations are deliberately kept out of its own `hot-for` file, so the
  fast path returned before the engine was consulted. On a host without bash — the Windows
  entry point — the engine *is* consulted, and the owner would have been blocked by their
  own declaration there and nowhere else. The suite now asserts the owner case through
  `ab_engine` as well, and with that the falsification is caught. This is the second time
  in this plan that a green assertion was measuring the wrong thing (see M1), and both
  times the tell was the same: the assertion passed in a state where the feature was
  obviously broken.

- Observation (M3): adding a `record-write` to a test contaminated four later assertions,
  which then passed or failed through the fifteen-minute reactive collision guard rather
  than through ownership. Caught because one of them expected an allow and got a denial
  quoting the wrong guard entirely. Fixtures that write state are shared state; the fix was
  a dedicated file for that case and an assertion on *which* guard produced the block, not
  merely that something did.

- Observation (M4): the handoff could not be delivered in the two-session case — the common
  one — and the bug was older than this milestone. The shell fast path gave up on every
  gated event when `live-count` was not greater than one, and a session ending is precisely
  what takes the count from two to one. So the departing session's own exit swallowed its
  message: it was written to `events.jsonl` and the survivor's `PostToolBatch` never looked.
  It was not lost for ever — `prompt-submit` is ungated, so it would surface at the human's
  next prompt — but "at the next turn" is what the milestone promises and what a session
  mid-work needs. The same hole applies to any `note` or `serve` event emitted just before
  its author left. Fixed by exempting `post-batch` from the live-count gate and having it
  ask the question that actually matters instead: is any live session behind the end of the
  stream. `hook_post_batch` lost its matching Python-side gate for the same reason.

- Observation (M4): a benchmark said that gate was worthless — 105 ms against 107 ms for
  twenty calls — and the benchmark was measuring nothing. The patched copy of `bin/ab-hook`
  had been dropped into a bare temporary directory, so `[ -x "$ENGINE" ] || exit 0` fired on
  line 21 of both variants and every run was timing bash's startup. Re-run with the whole
  plugin tree copied, the same comparison is 109 ms against 405 ms at a 65 KB payload, and
  109 ms against 845 ms at 128 KB. The gate is worth keeping, and the test that guards it
  now uses a payload large enough for the difference to exist: at 143 bytes the two are
  indistinguishable, which is why the first version of that assertion passed against a
  deliberately broken build.

- Observation (M4): `matched/` cannot answer "how many commands did this session claim for",
  which the plan offered as one of two ways to get that number. It holds one file per
  repository and resource for the whole machine and its mtime records when that resource
  last matched *anybody's* command. The counter lives in the session record instead.

- Observation (M2, found while running the real acceptance): **Claude Code does not fire
  `PostToolUse` when a tool call errors.** M2 was built on `PostToolUse` exactly as the plan
  specifies, and it therefore never fired for the only thing it exists to catch — a failing
  build. All 79 synthetic assertions passed, because they fed the engine payloads by hand.
  In two real sessions, session B ran the build, saw the SyntaxError naming a file session A
  had written seconds earlier, reported "No agent-bus message was shown", and set about
  fixing it. Confirmed twice: `--include-hook-events` shows `PostToolUse:Bash` for a
  successful command and no such event at all for a failing one, and an independent hook
  installed through `--settings` recorded zero `PostToolUse` invocations for a batch whose
  command exited 1. Claude Code 2.1.220.
  It has a second consequence nobody had noticed: a guarded command that *fails* never
  reached `hook_post_bash` either, so its automatic claim was never released and the other
  session was blocked for the full fifteen-minute soft TTL. That bug predates M2.
  Both are fixed by moving the work to `PostToolBatch`, whose payload carries `tool_calls`
  with each call's `tool_response` whatever the outcome, and which fires either way.

- Observation (M2): the synthetic suite could not have caught this. It fed `hook_post_bash`
  the payloads the plan said it would receive, so it was testing the engine against an
  assumption rather than against Claude Code. The lesson is narrow and worth keeping: a test
  that constructs its own inputs verifies the code, and only a real session verifies that
  the inputs are real. `tests/live/acceptance.sh` exists because of this.

- Observation (M2/M3/M4, harness): asserting on what the model *said* measures how talkative
  it felt like being. The cross-worktree ownership note passed on one run and failed on the
  next with identical plugin behaviour, because the note is injected into the model's
  context and nothing obliges the model to repeat it. `--include-hook-events` reports each
  hook's own stdout, which is the plugin's actual output; the live harness asserts on that
  for anything delivered as `additionalContext`, and on the tool result for denials, which
  Claude Code does put in front of the model.

- Observation (live harness): three facts about driving Claude Code that cost time to learn.
  A session cannot be held alive across the orchestrating agent's own turns — the turn
  latency exceeds any sleep worth waiting for, so the whole scenario has to run inside one
  invocation. `claude -p --input-format stream-json` does **not** exit when its stdin is
  closed. SIGTERM is a clean end: the SessionEnd hooks run, the session deregisters, and its
  handoff is written — which is also why a killed session does not leak its ownership.

- Observation (M5): `re.escape` escapes the hyphen, so a detected `redis-cli` pattern came
  out as `\bredis\-cli\b` and `react-scripts` as `react\-scripts`. Correct, unnecessary
  outside a character class, and unreadable in a file whose entire purpose is to be read and
  corrected by a person. Replaced with a `lit()` helper that escapes only what is special.

- Observation (M5): the obvious pattern for a detected framework, `\bnext\b`, would claim
  the dev server for `git commit -m "bump next to 15"` — the token has no whitespace, so
  `command_targets` keeps it and the word boundary at the hyphen matches. The detector now
  pins the subcommand the script actually runs, `\bnext\s+dev\b`, the way a hand-written
  config would. There is a test for the commit message specifically.

- Observation (M6): running the install flow instead of trusting the plan's memory of it
  found that **the plugin installed from a marketplace and then did nothing at all**. Claude
  Code reads the wiring from `hooks/hooks.json`; that file was generated by the installer and
  git-ignored, and nothing in a plugin install generates it. No presence, no guards, no
  messages, and no error to explain any of it — the exact "installs, nothing happens,
  must be broken" failure M5 was written to prevent, one layer further out. The marketplace
  install from a *local path* hid it, because it copied a working directory that had the
  generated file; only a `git clone` as the source showed the truth.

- Observation (M6): the installer told a marketplace install to "move or re-clone it there",
  which would have broken the thing the reader had just installed — Claude Code loads it from
  exactly where it put it. The check had only ever been run from the skills directory.

- Observation (M6): nothing in a plugin install can put a command on anybody's PATH, and
  every block this plugin writes ends in advice to run one. An install where the hooks fire
  and `agentbus` does not exist is worse than one that does nothing: the agent is told
  exactly what to do and then cannot do it. `doctor` now reports it, and a session whose
  command is missing is told once, with the one command that fixes it.

- Observation (M6): `git rev-parse --git-common-dir --show-toplevel --abbrev-ref HEAD` exits
  128 in a repository with no commits, while still printing the two answers that matter.
  `git_facts` gated on the exit status and threw them away, so a freshly `git init`-ed
  repository got a key derived from its path — and that key changed the moment somebody made
  their first commit, orphaning any `--local` config written before it. Noticed in the
  stranger-path acceptance output, where a fixture repository reported `path:948a9d54`.

- Note (M6): the marketplace schema was accepted as first written, so nothing had to be
  corrected. The shape that works, verified against Claude Code 2.1.220: a top-level `name`,
  `owner {name, url}`, optional `metadata`, and `plugins[]` whose entries carry `name`,
  `source` (`"./"` for a single-plugin repository), `description`, `version`, `author`,
  `homepage`, `license` and `keywords`. `claude plugin marketplace add` takes a URL, a path
  or a GitHub repo, which is what made it testable without pushing.

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

- Decision (M1): the hook-output invariant — exit 0, print nothing or valid JSON — is
  asserted inside the `ab_hook` helper rather than in each test, so every hook invocation
  anywhere in the suite checks it and no test can forget to.
  Rationale: it is the one failure mode that breaks other people's sessions rather than this
  repository, and it is the kind of thing a test author only remembers to assert when they
  are already thinking about it.
  Date/Author: 2026-07-27, Claude.

- Decision (M1): assertion counts are kept in append-only files under the test's temporary
  directory, not in shell variables.
  Rationale: `out=$(ab_hook …)` runs the helper in a subshell, so a failure recorded in a
  variable there is discarded when the subshell exits — the suite would have silently
  under-reported exactly the failures that happen inside a captured hook call.
  Date/Author: 2026-07-27, Claude.

- Decision (M1): `tests/test_serving.sh` skips itself, visibly, when neither `lsof` nor
  `netstat` is on the host, rather than failing or quietly passing.
  Rationale: attributing a listening port to a checkout is the one thing in this plugin that
  genuinely needs an external tool. A skip that is printed and counted is honest; a green
  line for a test that did not run is not.
  Date/Author: 2026-07-27, Claude.

- Decision (M1): `tests/test_matcher.py` asserts that `git commit -m "restart uvicorn"`
  matches the `worktree` resource and *not* `server`, rather than matching nothing at all.
  Rationale: the plan's phrase "a commit message naming a tool matches nothing" is about the
  tool named in the message. `git commit` legitimately claims the checkout it commits, which
  is the whole reason the `worktree` resource exists, so asserting "nothing" would have been
  asserting a bug.
  Date/Author: 2026-07-27, Claude.

- Decision (M1): the pre-filter invariant is checked through bash's own `[[ =~ ]]` with
  `nocasematch` set, in addition to Python's `re`.
  Rationale: bash is what actually makes the decision in `bin/ab-hook`. A token that Python
  matches and bash does not would be a guard that never fires — the same class of silent
  failure as `768f183`, arrived at from a different direction.
  Date/Author: 2026-07-27, Claude.

- Decision (M1): the suite writes to stdout only through the CLI verbs and the two functions
  that emit hook JSON, and the syntax gate enforces that with an AST walk over `bin/agentbus`
  (prints to `sys.stderr` are exempt, since stderr never reaches the session's parser).
  Rationale: the invariant the plan states is easy to break by adding one debugging `print`
  to a helper, and the damage is invisible until somebody's session breaks. Checking it
  statically costs nothing and catches it before it ships.
  Date/Author: 2026-07-27, Claude.

- Decision (M2): `interference_note` considers only sessions sharing this session's
  `repo_key`. The plan said "every other live session".
  Rationale: a session working an unrelated repository cannot have broken this build, so
  naming its files is a coincidence presented as a cause — the exact false accusation the
  milestone says is worse than silence. Sessions in a *different worktree of the same*
  repository are still considered, because a shared dev server serving their checkout
  genuinely does put their code in this session's failures. The delivery layer already
  draws the line in the same place (`interesting_to` requires a matching repo).
  Date/Author: 2026-07-27, Claude.

- Decision (M2): a file the current session also wrote inside the window is dropped by
  repository-relative path as well as by absolute path.
  Rationale: two worktrees give the same file two absolute paths, so comparing only the
  absolute one would tell an agent not to fix a file whose broken state may well be its
  own doing — the one outcome that would make this feature actively harmful.
  Date/Author: 2026-07-27, Claude.

- Decision (M2): `hook_post_bash` releases automatic claims before any of the new work and
  regardless of `AGENTBUS_OFF` or the live count, and only the interference half is gated.
  Rationale: the release is the second half of a claim this session already took. Skipping
  it because the other session happened to end mid-command would strand a soft lock for
  its full fifteen-minute TTL. `AGENTBUS_OFF` is a recovery switch for a misbehaving hook,
  not a licence to leak state that is already on disk.
  Date/Author: 2026-07-27, Claude.

- Decision (M2): the timestamp in the note uses `held_for(ts) + " ago"` rather than `ago(ts)`.
  Rationale: `ago` collapses everything under a minute to "just now", and "40s ago" is the
  shape the plan's own example asks for. The difference matters here: the note's whole claim
  is that somebody is mid-edit *right now*, and "just now" is vaguer than the evidence is.
  Date/Author: 2026-07-27, Claude.

- Decision (M3): a declaration containing no wildcard is read as a directory — `agentbus own
  api` covers `api/` and everything under it, not a single file named `api`.
  Rationale: that is what a person typing it means, and the alternative is a guard somebody
  believes they have set which silently protects nothing. The plan already required the
  `*`-crosses-`/` simplification to be stated rather than discovered; this is the same
  argument applied to the other end of the syntax, and it is documented in both files.
  Date/Author: 2026-07-27, Claude.

- Decision (M3): `glob_matches` uses `fnmatch.fnmatchcase` on a `/`-normalised path, not
  `fnmatch.fnmatch`.
  Rationale: `fnmatch` runs both arguments through `os.path.normcase`, which on Windows
  rewrites `/` as `\` — in the glob as well as the path — so a declaration written with
  forward slashes would match nothing at all on the one platform we cannot test.
  Date/Author: 2026-07-27, Claude.

- Decision (M3): `own` and `disown` emit a `note`-kind event, and `own` calls
  `refresh_derived` before returning.
  Rationale: the plan asked for ownership to appear in the roster and in `status`, both of
  which the other sessions only read when they start or when they ask. A declaration that
  the others learn about at their next restart is not a declaration. `note` is already in
  `DELIVERED_KINDS`, so it reaches their context at their next turn; the refresh is what
  makes the fast path see it in the same second rather than at the declarer's next prompt.
  Date/Author: 2026-07-27, Claude.

- Decision (M3): `ownership_verdict` considers only sessions sharing this session's
  `repo_key`, and `guard_file` returns immediately after whichever of the two guards speaks
  first.
  Rationale: a glob is written against a repository root, so one from another project cannot
  describe this file even when the text happens to fit. And two `note_ctx` calls would put
  two JSON documents on stdout, which corrupts the session's view of the hook result — the
  invariant this whole plugin is built on. There is now a test that both guards apply to one
  edit and that exactly one hook result is printed.
  Date/Author: 2026-07-27, Claude.

- Decision (M4): the count of guarded commands is a counter in the session record, bumped in
  `guard_bash` when a command actually takes something, rather than derived from `matched/`.
  Rationale: the plan offered both and only one of them exists. See Surprises. The write is
  one small atomic replace per guarded command, and it re-reads the record first so it does
  not undo a concurrent `doing` or `name`.
  Date/Author: 2026-07-28, Claude.

- Decision (M4): the handoff also names the scopes the session had declared and is now
  releasing, which is not in the plan's list of contents.
  Rationale: a session blocked from `api/**` learning that `api/**` is now free is the most
  immediately actionable line the summary can carry, it costs one line, and it comes from
  state that is about to be deleted a few statements later.
  Date/Author: 2026-07-28, Claude.

- Decision (M4): `deliver` indents multi-line events under their own heading instead of
  folding them into the existing one-line form.
  Rationale: a handoff is inherently several lines. Folded, it runs into the sender and
  timestamp and the one message worth reading becomes the one that gets skimmed.
  Date/Author: 2026-07-28, Claude.

- Decision (M4): `SessionEnd` emits the handoff *and* the existing `leave` event, rather
  than replacing one with the other.
  Rationale: `leave` is not in `DELIVERED_KINDS` — it is the log line `status` and `inbox`
  read — and a handoff is not always written. Keeping both means the log stays complete for
  sessions that leave quietly, and neither reader changes behaviour.
  Date/Author: 2026-07-28, Claude.

- Decision (M2, revised): the interference guard and the release of a failed command's
  automatic claim live on `PostToolBatch`, not `PostToolUse` as the plan specified.
  Rationale: `PostToolUse` does not fire for a tool call that errored, so the guard could
  never see a failing build and a failing guarded command never gave its claim back. See
  Surprises for the evidence. `PostToolBatch` fires either way and its payload carries every
  call's `tool_response`. `PostToolUse` keeps the prompt release for commands that succeed,
  because giving a resource back a few hundred milliseconds sooner is worth having.
  Date/Author: 2026-07-28, Claude.

- Decision (M2, revised): the fast path wakes the engine on `post-batch` only for a batch
  that actually ran a Bash call, falling back to the cursor check otherwise.
  Rationale: a batch of nothing but edits cannot have printed a build failure and cannot
  have claimed anything, and an agent editing files produces a great many of those. It is an
  exact test rather than a heuristic — the payload lists every call — and it is the
  difference between ~22 ms and ~42 ms on every such batch while somebody else is live.
  Date/Author: 2026-07-28, Claude.

- Decision: acceptance against real Claude Code sessions is a checked-in harness,
  `tests/live/acceptance.sh`, rather than something done by hand once.
  Rationale: it found a defect that 79 synthetic assertions could not, because the synthetic
  ones fed the engine the payloads the plan *said* it would get. It has to be re-runnable
  after anything that touches the hooks. It is kept out of `make test` because it needs a
  logged-in CLI, costs real money and takes minutes.
  Date/Author: 2026-07-28, Claude.

- Decision (M5): a detected database is written with no `start`, and the detector will not
  add one.
  Rationale: the plan says so and the reason is worth restating — the guard exists because a
  reseed or a destructive migration invalidates the rows the other sessions are holding, and
  taking the service down to prove ownership would be the same damage by another route. The
  test asserts the absence, and the falsification that adds a `start` is caught.
  Date/Author: 2026-07-28, Claude.

- Decision (M5): `why` and `hint` are written empty on every detected resource, including
  `worktree` and `db`, where a generic sentence would have been easy and true.
  Rationale: the plan's closing message tells the reader they are empty and that filling
  them in is what stops an agent working around a block. Pre-filling them with plausible
  prose would let the reader skip the one step that matters, and the message would be a lie.
  Date/Author: 2026-07-28, Claude.

- Decision (M5): the plan lists a fixed set of `db` patterns; the detector writes the client
  for the images it actually found, plus the migration patterns, rather than all of them.
  Rationale: guarding `psql` in a repository whose only database is Redis is a pattern that
  can never match, which is exactly the silent failure `doctor`'s "NEVER matched" line
  exists to report. Fewer, accurate patterns beat a complete list of guesses.
  Date/Author: 2026-07-28, Claude.

- Decision (M5): each detector names its resource, and `unique_name` resolves collisions, so
  a monorepo with a Node dev server and a FastAPI app gets `server` and `api` rather than one
  of them silently winning.
  Rationale: the plan's list of detectors can plainly fire more than once in one repository,
  and a draft that quietly drops half of what it found is worse than one that names both.
  Date/Author: 2026-07-28, Claude.

- Decision (M6): `hooks/hooks.json` is committed rather than generated, and `.gitignore`
  says why at length.
  Rationale: it is the only file Claude Code reads to know this plugin has hooks at all, and
  no install path other than the shell installer creates it. The committed copy is the shell
  entry point, which has nothing machine-specific in it; the installer still overwrites it
  with the Python one on hosts without a shell, where it does bake in an interpreter path and
  will therefore show up as a local modification. That is a fair trade for an install that
  works.
  Date/Author: 2026-07-28, Claude.

- Decision (M6): the "your command is missing" notice is emitted once per machine, from
  SessionStart, and breaks the rule that a solo session is told nothing.
  Rationale: the rule exists so the plugin costs nothing when nobody else is working. A
  plugin that cannot be driven at all is a different situation, it is worth one sentence, and
  a marker file means it is one sentence ever. There is a test that a solo session with a
  working command is still told nothing.
  Date/Author: 2026-07-28, Claude.

- Decision (M6): the README documents the marketplace path as two commands *plus* the
  installer, rather than claiming two commands are enough.
  Rationale: two commands genuinely wire the hooks, and that is most of the value — but the
  CLI is what every block message tells the agent to use. Saying so is better than a first
  experience where the guard fires and the advice does not work.
  Date/Author: 2026-07-28, Claude.

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

Re-measured after M2 as first written, on the same Mac (Python 3.14.3, best of three batches of twenty, while
four sessions were live and the suite was running — so these are upper bounds):

    alone, post-bash (live-count gate)          5.0 ms    unchanged
    alone, pre-tool on a guarded command        5.1 ms    unchanged
    two sessions, pre-tool, token gate misses   5.2 ms    unchanged
    two sessions, post-bash                    38.8 ms    NEW: was ~5 ms without a claim
    two sessions, pre-tool, engine + claim      42.0 ms    ~30 ms predicted, 42 measured

Re-measured again after M2 was moved onto `PostToolBatch`, with the machine quiet:

    alone, post-batch                           5.0 ms    unchanged
    alone, post-bash                            5.0 ms    unchanged
    two sessions, post-bash, nothing to release 5.2 ms    the auto-claim gate is back
    two sessions, post-batch that ran a command 42.1 ms   NEW: one engine start per batch
    two sessions, post-batch of edits only      ~22 ms    short-circuits; the cost is bash
                                                          slurping a large payload, which is
                                                          unavoidable — the session id is in it

The 42 ms line is what M2 costs now. It is one engine start per tool *batch* rather than per
Bash *call*, so a batch that runs three commands is cheaper than it was under the first
design, and a batch that runs none falls back to the cursor check. The engine's cost is flat
in the size of the command's output, which is why the shell-side pre-filter that would seem
to avoid it does not (see Surprises & Discoveries).

Numbers taken while three other Claude Code sessions were working measure about three times
these. Anything here is a floor, not a typical figure.

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
    tests/live/acceptance.sh     M2/M3/M4 against real Claude Code sessions (not in `make test`)
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
