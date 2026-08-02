# Collapse the two spines that keep producing defects: who-and-where, and one decision

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`,
`Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

Maintained in accordance with the exec-plan skill. Note that the skill file contains a
section of conventions for a mobile/FastAPI product repository; **none of that applies
here**. This repository is a standalone Claude Code plugin written in Python and bash,
with no database, no web framework, no mobile app, and no Linear.

Revision note: this plan was reviewed by an independent agent on 2026-08-02 before any
work began, and rewritten from that review. The review found two live defects, four
factual errors, nine design problems, seven pieces of missing scope, seven verification
gaps and four sequencing risks. The two live defects were fixed the same day, before this
revision, and are recorded in `Surprises & Discoveries`. What the review changed about the
design is recorded in the `Decision Log`. The section at the end, "What the review
changed", lists every finding and its disposition.

## Purpose / Big Picture

Nothing a user can see changes. That is the point, and it is why this plan needs an
unusually strict definition of done.

`claude-agent-bus` stops parallel Claude Code sessions on one machine from quietly
ruining each other's work. In the eleven days to 2026-08-01 it blocked 102 commands that
would have run against another checkout's code and reported the result as the caller's.
It also produced twenty-two defects of its own, every one found in real use rather than
by its test suite. Sorted by root cause, half fall into two buckets.

*Six came from the same decision being made in more than one place.* "Which resources
does this command touch, and under what name are they locked" is answered independently
by the guard that runs in the hook, by five command-line verbs, and — this is the one
that hurts — by the English text of the block message, which hard-codes its advice as
format strings. When two answers disagree, the tool contradicts itself. `agentbus claim
worktree` wrote a lock the guard never read. The block message offered `agentbus wait
<res>` and `AGENTBUS_OFF=1 <command>` and the guard refused both. On the day this plan
was written the review found a third instance still live: the message tells an agent to
run `agentbus claim <res> --as <your name>` and the guard denied exactly that.

*Six came from guessing who is acting and where they are working.* A hook payload carries
a session id, sometimes an `agent_id`, and a working directory that is often not where
the work is happening. Thirteen functions infer identity and location from those three
facts, each added to close one defect and none removing another. The review found that
the most recent of those fixes was half a fix: `agentbus here` pinned the session record,
which is what `status` prints, but `caller_view` — which is what the guard actually
decides from — had no pin check, so the guard went on locking and comparing services
against the tree the payload named. The declaration was cosmetic.

After this plan there is one function that answers "who is acting and where", with a
precedence order written down and tested rule by rule, and one function that answers
"what does this command touch and what will happen to it", whose result is rendered into
a denial, into a command-line action, and into the advice printed at the bottom of a
block. Advice the guard would refuse becomes structurally impossible for the command
surface, because the advice is generated from the same object that decides.

You can see it working by running `make test` — 888 assertions today, more after — and by
the two adversarial checks this plan adds: a test that walks every command-line verb and
asserts it locks the identical name the guard would *for the same command*, and a test
that takes each block the plugin can emit, runs the exits it advertises, and requires
that running one lifts the block.

## Progress

- [x] (M0) Land the characterisation harness against today's behaviour, divergences
      included, asserting through the guard rather than the record.
      Done 2026-08-02: `tests/test_identity.sh` (125 assertions) and
      `tests/test_parity.sh` (265). 932 → 1322. Nine falsifications for the first,
      three for the second; two verified independently of the agents that wrote
      them. It found four live defects, recorded below.
- [ ] (M1) Close the divergences the harness pins, one commit each, updating the
      harness in the same commit as each fix.
      Half done 2026-08-02: three of the four pinned defects closed, one commit
      each, 1322 → 1338. Still open: the two deliberate divergences to confirm
      (`cli_claim` and `implies`), and the three `DIVERGENCE` precedence
      questions, which belong with the identity spine.
- [ ] (M2) One resolver for who-and-where — `resolve_party`, replacing the inference
      functions, with the precedence order written down and tested directly.
- [ ] (M3) One decision core for commands — `plan_for` plus `commit_plan`, with the
      guard and the block message rendered from the result.
- [ ] (M4) Retire the duplicate paths: the five command-line verbs call the core; the
      two fast paths are pinned to each other and to the token pre-filter by tests.
- [ ] (M5) Re-measure cost, update the documentation that describes the old shape, and
      write the retrospective.

## Surprises & Discoveries

- Observation (from the review, 2026-08-02): **`agentbus here` never bound the guard.**
  Only `follow_cwd` checked the `pinned` flag. `caller_view`, which `hook_pre_tool` calls
  on every session tool call and which every command-line verb goes through, had no
  such check — so a pinned session was locked and judged in the tree its payload named.
  Evidence, in an isolated bus, for a session pinned to a worktree while the payload said
  the main checkout:

      pinned record : worktree@fefd30
      caller_view   : worktree@c4f9c3
      lock the guard actually wrote: repo_8d18a7__worktree_c4f9c3.json

  Fixed 2026-08-02 by giving `caller_view` the same pin check, with an assertion in
  `tests/test_serving.sh` that goes through `pre-tool` and asserts on the denial text
  rather than on the record — the record-only assertion that shipped with the pin passed
  the whole time the guard was wrong.

- Observation (from the review, 2026-08-02): **the block message advertised a command the
  guard denied, again.** The unidentified-party block ends with `agentbus claim <res>
  --as <your name>`. `explicit_resources` treats `--steal` as a way past a lock but not
  `--as`, so the guard tried to claim the resource in the caller's name, found a sibling's
  unidentified lock, and denied the command it had just printed.
  Evidence: with a script-borne claim held and two subagents live, feeding the guard the
  exact advertised line returned `permissionDecision: deny`. Fixed the same day; `--as`
  now passes through with `--steal`.

- Observation (M0, 2026-08-02): **`VERBOSE=1` made the assertions lie, in every file.**
  `_ok` in `tests/lib.sh` printed to stdout while `_bad` printed to stderr, and almost
  every assertion in this suite is made inside `out=$(ab_hook …)` — so under `VERBOSE=1`
  the harness's own `ok` lines landed inside the captured hook output and `json_field`
  parsed them as the hook's JSON. On the unmodified tree, `VERBOSE=1 tests/run.sh
  test_subagents.sh` failed 22 of 118 where the same file passed 118 of 118 without it;
  `test_serving.sh` failed 11 of 100. The documented way to inspect assertions was the
  way to break them, which is a fifth entry in this repository's list of green
  assertions that measured the wrong thing — and the one that would have made every
  later milestone's debugging session lie to it. One character; fixed in the M0 commit.

- Observation (M0, 2026-08-02): **the `--as` fix of 2026-08-02 was half a fix, in
  exactly the way the pin fix was.** The unidentified-party block's *first* piece of
  advice is `agentbus claim <res> --as <your name>`. The guard no longer refuses that
  line — that half was fixed. But `do_claim` is then asked for a lock whose holder is an
  unidentified party of the same session; `same_party` falls through to `siblings < 2`
  and answers no, for precisely the reason the block exists; and the CLI exits 1. The
  advice is now reachable and still useless. Naming yourself does not make an anonymous
  lock yours, and nothing in the message says to add `--steal`. Pinned in
  `test_parity.sh` as `DEFECT (pinned)`; M1 must decide whether `--as` should be
  believed here or the advice should change. This is the third instance of this plan's
  opening defect class and the second time it has been recorded as closed while live.
  Closed in M1, `f378703`, by changing the advice rather than the rule.

- Observation (M0, 2026-08-02): **an instance block has no working exit at all.** The
  block is about `simulator@ABC123`; its advice names the resource the way a person
  types it, and `resolve_lock`, given a name and no command, cannot get back to the
  instance. So `agentbus wait simulator` and `agentbus claim simulator --steal` both act
  on a bare `simulator` lock that nothing was contending for: they take a lock that was
  free, print `claimed`, exit 0, and the device is still somebody else's — the wait
  leaving a second, unrelated lock behind it. Only `AGENTBUS_OFF=1` gets the reader
  past. This is the same shape as the `scope: "worktree"` defect closed on 2026-07-29,
  and it is why the plan's rule is "the block must lift" rather than "the exit must be
  allowed" — every one of these exits is allowed by the guard, perfectly.
  Closed in M1, `8e07602`. Note for M3 and M4: `resolve_lock` already returned
  `simulator@ABC123` unchanged, through the pass-through that exists for
  `file:/abs/path`, so the CLI half worked by accident and `agentbus claim simulatr@ABC`
  wrote a lock under the typo just as cheerfully. Whatever replaces this function has to
  keep refusing an `@` name whose base is not declared, or the defect comes back one
  keystroke away from where it was.

- Observation (M0, 2026-08-02): **a wait the guard did not see reports a claim it did
  not make, and leaks a lock doing it.** `agentbus wait <res>` from a shell with no
  hint carries no `agent_id`, so `same_party` reads it as the session itself; a session
  never contends with its own subagent, so `do_claim` answers "already yours", prints
  `claimed`, and exits 0 while the sibling that read the advice stays blocked. Worse,
  the wait asks for `mode="hard"`, which upgrades the sibling's one-command soft claim
  in place — and `release_autoclaim` gives back only soft locks, so `PostToolUse` no
  longer frees it. Any wording but the advertised one reaches this path, as does an
  `agentbus wait` inside a script.
  Closed in M1, `659902d`. The leak went with it rather than being fixed separately:
  with the caller no longer read as the session, `already yours` is unreachable for a
  party that cannot show the lock is its own, so there is nothing left to upgrade.

- Observation (M0, 2026-08-02): **three places where this plan's prose and the code
  disagree about precedence**, all pinned as `DIVERGENCE` and all for M1:
  `--as` beats the party hint, though the order above puts the hint first — the code
  looks right here and the prose wrong, since a declaration should beat an inference.
  A pinned session ignores `git -C`, though the order puts `git -C` first — the code
  looks wrong here, since `git -C` is a statement about one command and the pin about a
  session, and the narrower should win. A subagent's own root beats its parent's pin,
  which the order does not settle at all.
  The mechanism is not where it looks: `command_worktree` is called in `hook_pre_tool`
  and its answer is applied by *calling `caller_view`*, whose pin short-circuit is what
  swallows it; and `party_view` does not copy `pinned` — the subagent branch bypasses
  `caller_view` entirely, so the pin never gets a chance. `resolve_party` must apply
  `git -C` outside the pin check rather than through it.

- Observation (M0, 2026-08-02): **`cli_here` records a pin for a session and not for a
  subagent.** The session branch writes `pinned: True`; the `--as` branch writes the
  same five location fields to the agent record and no flag. So for a subagent the
  root it *declared* and the root that was *inferred* from a payload cwd are the same
  field, indistinguishable — which is why the question above cannot be answered as the
  code stands. Whatever M1 decides, the flag has to exist at both levels for the
  decision to be expressible.

- Observation: the two spines were identified by classifying defects, not by reading
  code, and that is what makes this plan worth doing rather than a rewrite. Twenty-two
  defects, root causes assigned by hand: identity/location 6, one-decision-twice 6,
  configuration expressiveness 3, packaging 2, observability 2, platform assumption 1,
  gate logic 1, input handling 1. A rewrite would address the twelve as readily as the
  ten, which is the argument against one.

- Observation (from the review): the plan's first draft overstated the duplication in
  `resources_for` by three times. Verified: `resources_for` and `expand_implied` have
  three call sites, not nine. `lock_name`, `resolve_lock` and `file_lock_name` have
  twelve, which is correct and is where spine two's duplication actually lives. The
  first draft also credited `tests/live/acceptance.sh` with "32 assertions"; it contains
  no `assert` at all and 36 `ok`/`check` calls.

## Decision Log

- Decision: refactor the two spines in place rather than rewriting the plugin.
  Rationale: the asset worth protecting is not the code, it is roughly twenty measured
  facts about Claude Code that cost real time to learn — `PostToolUse` does not fire for
  a tool call that errored; `agent_id` appears on every hook a subagent causes and none
  the session causes; a subagent's Bash environment is byte-identical to its parent's;
  the chat title is on no payload but the transcript path is; `hooks.json` is the only
  wiring Claude Code reads. Those live in the test suite and in comments. A rewrite either
  carries them across, in which case it is not a rewrite, or rediscovers them expensively.
  The 888 assertions are also the only safety net that makes a change of this size
  survivable, and a rewrite discards it exactly when it is needed.
  Date/Author: 2026-08-02, Ibrahim + Claude.

- Decision: characterisation lands as M0 and asserts today's behaviour *including the
  divergences*, which are then closed one at a time in M1.
  Rationale: the first draft required the parity harness to pass against unrefactored
  code, and the review showed it cannot: `cli_claim` deliberately does not take implied
  resources and `resolve_lock` deliberately cannot resolve an instance key. Requiring a
  green harness against today's code therefore smuggled an unbounded behaviour change
  into a milestone described as "nothing is refactored". Pinning the divergences first
  and closing them in named commits keeps every behaviour change attributable.
  Date/Author: 2026-08-02, Claude, after review.

- Decision: `plan_for` is pure and does not take locks; a separate `commit_plan` takes
  them inside the mutex and returns the authoritative verdict.
  Rationale: the deny decision is deliberately made twice — once optimistically outside
  the mutex and once inside `do_claim`, whose answer must be honoured because ignoring it
  is how two sessions both proceeded before commit `c95399c`. A single pure `plan_for`
  cannot produce the verdict for the losing-race path, so the guard would have to build a
  second Plan by hand and there would be two Plan constructors — the defect class this
  plan exists to close.
  Date/Author: 2026-08-02, Claude, after review.

- Decision: the service probe stays out of `plan_for`, behind an explicit argument.
  Rationale: `serving_check` shells out to `lsof` or `netstat` and runs *after* the claim,
  undoing it on deny. Putting it in a `plan_for` that the guard calls before claiming
  would probe twice per guarded command, and M4 routes `agentbus claim`/`release`/`wait`
  through the same function — adding an `lsof` to three verbs that are pure file
  operations today. The lock-beats-serve precedence is also load-bearing and undocumented:
  a command touching both a held resource and a mis-served one reports the lock.
  Date/Author: 2026-08-02, Claude, after review.

- Decision: M3 covers the command surface only. `guard_file`, `ownership_verdict` and
  `interference_note` keep hand-written text, and the plan says so rather than implying
  otherwise.
  Rationale: a Plan whose resources each carry a lock name and an instance does not
  describe a file edit blocked by a glob somebody declared. The review's corrected census
  shows most advice sites are on the file surface, so the honest scope is "the command
  surface now, the file surface later", not a promise the design cannot keep.
  Date/Author: 2026-08-02, Claude, after review.

- Decision: `resolve_party` returns the record and the view distinguishably, and the four
  places that write `me` back to disk assert they were given a record.
  Rationale: `caller_view`'s docstring records that persisting a view was tried and was
  worse — two subagents dragged the session's root between them on every tool call.
  `hook_prompt_submit` hands what it gets to `follow_chat_title`, which writes; a uniform
  view would persist a payload cwd over a pin, which is the defect this plan opens with.
  Date/Author: 2026-08-02, Claude, after review.

- Decision: `acting` stays at the verb rather than moving into `resolve_party`.
  Rationale: `--as` means different things to different verbs. `agentbus post --as X`
  signs a message without adopting X's identity, cursor or lock ownership; `agentbus
  claim --as X` adopts it. `acting` also calls `sys.exit(1)` on an unknown name, which in
  a universal resolver would make `agentbus status --as <stale>` exit non-zero.
  Date/Author: 2026-08-02, Claude, after review.

- Decision: the hint key keeps coming from `sys.argv`, and `resolve_party`'s `args`
  parameter is only ever used for `--as`.
  Rationale: `leave_party_hint` computes its key over the full token list of the command
  the guard saw. `cli_run` passes only the head of its arguments to `acting`. If the
  resolver computed the hint key from that head, `agentbus run web -- npm test` would
  miss its own hint, `party_known` would go false, and the resulting lock would block the
  caller's own siblings.
  Date/Author: 2026-08-02, Claude, after review.

- Decision (M1): a block about one instance advertises that instance, and
  `resolve_lock` learns the `<resource>@<instance>` form deliberately.
  Rationale: the runnable lines have to name the lock that is in the way, or they act on
  a lock nothing was contending for and report success. The plain name stays in the
  prose — nobody types a digest, and `worktree@3f9c1a` is not what a person calls their
  checkout. The base of an `@` name must be a declared resource: the form resolved by
  accident before this, which is also why a typo became a junk lock reported as a claim.
  `agentbus claim simulator --udid ABC`, the other candidate from the plan's M1 notes,
  was not taken — the block prints one string, and one string that both halves
  understand is the whole point.
  Date/Author: 2026-08-02, Ibrahim + Claude.

- Decision (M1): the unidentified-party block advertises `--as <your name> --steal`,
  and says why, rather than `--as` being believed.
  Rationale: three options. Teaching `same_party` that naming yourself adopts an
  unattributed lock of your own session was rejected — subagent B would take subagent
  A's lock in silence, which is the three-agents-one-simulator failure `same_party`
  exists to prevent. An `--adopt` verb was rejected as new surface for a case `--steal`
  already models. What is left is the truth: nobody can prove the lock is yours, so
  taking it is a takeover, and `--steal` already puts `took 'X' from Y (forced)` on the
  bus. Visible beats silent where the tool cannot know.
  Date/Author: 2026-08-02, Ibrahim + Claude.

- Decision (M1): `--as <name>` beats the party hint — again the code was right and this
  plan's prose was wrong, so the prose changed and no code did.
  Rationale: a hint is an inference. The guard saw a command line, worked out which
  subagent was about to run it, and left the answer under a digest of the argv; two
  subagents running the identical line can already swap hints, which `take_party_hint`
  records as an acceptable error. `--as <name>` is a declaration by the caller, checked
  against that session's own subagents, and a declaration beats an inference for the same
  reason it does everywhere else in this order. It is also the only thing that makes the
  block advice work: the unidentified-party block tells a blocked agent to name itself,
  and naming yourself is useless if a hint left under the same argv outranks it.
  Date/Author: 2026-08-02, Ibrahim + Claude.

- Decision (M1): a subagent's own recorded root beats its parent's pin — the code was
  right and this plan's prose was wrong, so the prose changed and no code did.
  Rationale: a subagent's record tracks where that subagent demonstrably is.
  `follow_agent_cwd` moves it only on positive evidence — a cwd that differs from both
  the record and the parent's — and `party_view` already gives the subagent its own root
  for every other purpose, so making the pin win here would have contradicted the rest of
  the function to satisfy a sentence. The session's pin is a statement about the session;
  read strictly, the old order had a session pinned to one tree dragging its subagents
  into it, which is exactly the two-parties-two-checkouts case the subagent record exists
  to express. And after the commit above, a subagent that wants to declare its own
  location has a way to say so — `agentbus here --as <name>`, with a flag of its own —
  and that declaration is the thing that should beat an inference, not the parent's.
  Date/Author: 2026-08-02, Ibrahim + Claude.

- Decision (M1): a caller that cannot name its party is treated exactly as a lock that
  cannot — permissive with at most one subagent, blocking with two.
  Rationale: `same_party` already reasoned this way about an unattributed holder and
  answered "already yours" unconditionally about an unattributed caller, which is the
  same ambiguity asked from the other end. The asymmetry let a shell's `agentbus wait`
  report a claim it never made against a sibling's lock, and upgrade that sibling's
  soft one-command claim to hard on the way past. Both docstring cases survive by
  construction: a delegating parent's lock carries no `agent_id`, so the new branch is
  not entered, and a session asking about its own subagent comes through a hook, where
  the party is known.
  Date/Author: 2026-08-02, Ibrahim + Claude.

## Outcomes & Retrospective

To be written at the end of M5.

## Context and Orientation

### What this repository is

`claude-agent-bus` is a Claude Code plugin. Its working copy is `~/.claude/skills/agent-bus`
and it is published at `https://github.com/akaribrahim/claude-agent-bus` under MIT. A
folder under a Claude Code *skills directory* containing `.claude-plugin/plugin.json` is
loaded as a plugin in every project on that machine, **in place** — so editing a file here
changes behaviour immediately, in every session running on the machine, including the one
doing the editing. That is the single most important operational fact in this plan.

### The files

    .claude-plugin/plugin.json   name, version, description
    bin/agentbus                 the engine and the command-line tool, ~5500 lines
    bin/ab-hook                  the bash fast path, ~177 lines
    bin/hook.py                  the Python fast path (Windows), ~259 lines
    hooks/hooks.posix.json       wiring that calls bin/ab-hook
    hooks/hooks.python.json      wiring that calls bin/hook.py; __PYTHON__ substituted
    hooks/hooks.json             the file Claude Code actually reads; committed
    tests/run.sh                 the runner; isolates AGENTBUS_HOME
    tests/lib.sh                 assertions and fixture builders
    tests/test_*.sh|py           fourteen files, 888 assertions
    tests/live/acceptance.sh     36 checks against real Claude Code sessions
    tests/perf/hook-cost.py      where a hook's time goes, per platform
    SKILL.md / README.md         the agent-facing and human-facing documentation
    plans/publish-agent-bus-1.0.md  the plan this one continues from; read it

### How it runs, in one paragraph

Claude Code fires *hooks* — external commands — at points in a session: `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolBatch`, `SessionEnd`,
`SubagentStart`, `SubagentStop`. Each receives a JSON object on standard input and may
print JSON on standard output to influence the session. Two invariants govern everything:
**a hook must always exit 0**, because a non-zero exit blocks the user's tool call, and
**a hook must print nothing or valid JSON**, because a stray print corrupts the session's
view of the result. A fast path (`bin/ab-hook` in bash, `bin/hook.py` in Python) runs
first and decides in a few milliseconds whether the engine is worth starting. All state
lives under `~/.claude/agent-bus/`, never in this directory.

### Terms used in this plan

**Party.** Who is acting: a session, or one subagent within it. A subagent runs inside its
parent's process and its hooks carry the parent's `session_id`, so the only thing that
tells them apart is `agent_id`, which Claude Code puts on every hook a subagent causes
and on none the session itself causes.

**Root / worktree / checkout.** Used interchangeably for a git working directory.

**Guard.** A `PreToolUse` decision that stops a tool call and explains why.

**Resource.** Something the repository declares as shared in
`<root>/.claude/agent-bus.json`, with `patterns` (regexes matched against a command's
argv) and optionally `port`, `start`, `implies`, `scope`, `key`, `unless`.

**Instance.** One of several of a resource, named by a `key` regex over the command:
`"key": "--udid\\s+(\\S+)"` makes one simulator lock per device.

**Token pre-filter.** A single line of literal substrings in `~/.claude/agent-bus/guard-tokens`,
derived from every configured `patterns` by `resource_tokens`. Both fast paths grep the
raw payload against it and start the engine only on a hit. It is a second, lossy answer
to "could this command touch a resource" and it must remain a strict **superset** of what
`resources_for` matches: a token that stops being generated makes the guard never fire,
and no test that calls the engine directly would notice.

### Spine one as it stands: who is acting, and where

Thirteen functions participate. Definition lines as of 2026-08-02, after the two fixes
above:

    current_session      733   the entry point: session id → record
    follow_cwd           662   moves a session's recorded root to a payload cwd
    caller_view          712   a per-call view rooted elsewhere, not written back
    party_view          1118   the record seen as a subagent
    follow_agent_cwd    1079   moves a subagent's recorded root
    take_party_hint      962   the CLI learns which subagent is calling; destructive
    leave_party_hint     928   the guard records it, keyed over the command's argv
    command_worktree    2419   reads `git -C <path>` as the tree a command is about
    act_as              3878   adopt one of your own subagents' identities
    acting              3902   honour `--as` on a command line; exits 1 on a bad name
    party_key            838   "sid" or "sid__agentid"
    same_party           861   would these two contend
    may_release          895   may this caller hand that lock back

Stated as a precedence order — which is what M2 makes literal — the intended behaviour,
now that the pin binds both paths, is:

*Who is acting.* The `agent_id` on the payload, if there is one. Otherwise an explicit
`--as <name>` naming one of this session's own subagents, honoured by the verb rather
than by the resolver. Otherwise the party hint the guard left for this exact command
line, if the caller is the command-line tool and a hint exists. Otherwise the session.
This order used to put the hint above `--as`, which is the opposite of what the code
does; the prose was the half that was wrong, and the reasoning is in the Decision Log.

*Where they are working.* A path the command itself names (`git -C <path>`), for that
command only, without moving any record — and above every declaration below it, because
it is a statement about one command where they are statements about a party. Otherwise,
if the acting party is a subagent, that subagent's own recorded root: the tree it
declared with `agentbus here --as <name>`, which is pinned and which no inference moves,
or else the tree inferred for it — updated when a payload's cwd differs both from the
record and from the parent's cwd, because a cwd equal to the parent's is what a subagent
reports when it has never changed directory and therefore carries no information. Either
way that record outranks the session's pin, which is where this order used to say the
opposite; the reasoning is in the Decision Log. Otherwise the root pinned by `agentbus
here`, until `here` is run elsewhere. Otherwise the payload's cwd, which for an unpinned
session is authoritative and moves the record. Otherwise the record as it stands.

Four places write `me` back to the session file and must therefore never be handed a
view: `rename_session` (2818), `follow_chat_title` (2850), `cli_name` (4593), `cli_doing`
(4602). `hook_prompt_submit` passes what it receives to `follow_chat_title`.

### Spine two as it stands: what does this command touch

`resources_for(cmd, cfg)` answers "which declared resources does this command touch",
combining `explicit_resources` (a resource named outright on an `agentbus
run|claim|serve|wait|release` command line), pattern matching over `command_targets`,
`unless` exclusions, and `implies` expansion. `lock_name(me, res, cmd)` answers "under
what name is it locked", combining an instance `key`, a `scope: "worktree"` digest, and
the plain name. `guard_bash` uses both, plus `contending_locks`, `do_claim`,
`serving_check`, and roughly a hundred lines of message construction.

Twelve call sites reach `lock_name`, `resolve_lock` or `file_lock_name`. Five of them are
the command-line verbs deciding for themselves; one is `locks_text`, a display path with
no command in hand, reached from `status` and from the session-start banner.

Two divergences are deliberate today and must be treated as behaviour, not as bugs to be
silently normalised:

- `cli_claim` does not take implied resources. It prints a note naming them instead,
  because a claim is a deliberate act and expanding it silently would hold more than the
  caller asked for.
- `resolve_lock` cannot resolve an instance key, because it is given a resource name and
  no command, and the `key` regex matches against a command.

M0 pins both as intended behaviour. M1 decides, in a named commit each, whether either
should change.

## Plan of Work

### M0 — Characterise both spines, divergences included

Nothing is refactored. This milestone exists because a refactor that claims to preserve
behaviour is worthless without tests that fail when behaviour moves, and this repository
has four times shipped a green assertion that measured the wrong thing: a hook that
exited at the fast path before the engine was consulted; a fixture that invented a
payload field Claude Code never sends; an assertion that passed because nothing in its
fixture was reapable; and — found by the review that produced this revision — a pin
assertion that only ever asked the record while the guard was wrong.

Create `tests/test_identity.sh`, one case per rule in the precedence order above. Every
case must assert through a decision the guard makes — the lock name written, the
`permissionDecision`, or the `you are in:` line of a denial — and not merely on the
session record. At least one case must contradict the record deliberately: pin a session,
then feed `pre-tool` a payload whose cwd names a different tree, and assert on the lock
name that appears on disk.

Create `tests/test_parity.sh` with two checks:

*Every verb locks what the guard locks, for the same command.* The invariant is stated
that way, not as "the CLI and the guard agree about a resource name", because for an
instance-keyed resource the guard has a command and the CLI has not. For a fixture with a
plain resource, a `scope: "worktree"` resource, a `key`-bearing resource and an `implies`
chain, assert that `agentbus claim X` writes `lock_name(me, res, "")` and that a guarded
command touching X writes `lock_name(me, res, cmd)`, and assert *explicitly* that these
differ for the instance case and that `cli_claim` does not take implied resources. Those
two assertions pin the deliberate divergences.

*Every advertised exit lifts the block.* Provoke each kind of block, capture the message,
and for each exit run it and then re-run the originally denied call, requiring that it is
now allowed. "The guard allows the exit" is not the property that matters — `agentbus
claim worktree` was allowed by the guard perfectly while doing nothing — and for the file
blocks it is vacuous, because `resources_for` returns nothing for `file:` paths.

Extracting exits from rendered English is not attempted. M3 makes exits machine-readable
in the Plan; until then this test carries a hand-written table of (block scenario →
expected exit commands), and asserts the rendered message contains each one verbatim.
That table is deliberately duplicated work: it is the thing M3 deletes.

Acceptance: `make test` passes with both files. Then, in a copy of the tree under
`$TMPDIR`, remove the pin check from `caller_view` and confirm `test_identity.sh` fails;
remove the instance branch from `lock_name` and confirm `test_parity.sh` fails.

### M1 — Close the divergences, one commit each

For each of the two deliberate divergences and any the harness turns up, decide and
record whether it should change. The expected outcomes, to be confirmed rather than
assumed: `cli_claim` should keep refusing to expand `implies` and should keep saying so;
`resolve_lock` should be able to resolve an instance when the caller supplies one, which
means `agentbus claim simulator --udid ABC` or `agentbus claim simulator@ABC` needs a
decision. Each change is its own commit, with the harness updated in the same commit, so
that every behaviour change is attributable to a line of reasoning.

Acceptance: `make test` green after each commit; the harness asserts the new behaviour,
and `git log` shows one commit per decision.

### M2 — One resolver for who and where

Add:

    def resolve_party(payload=None, cmd="", as_name=None):
        """Who is acting and where they are working.

        Returns (record, view). `record` is the session's own dict, safe to
        write back; `view` is that dict rooted where this particular call is
        running, and must never be persisted. Callers that write use the
        record; callers that decide use the view. `payload` is a hook payload
        or None for the command-line tool; `cmd` is the Bash command being
        guarded, for `git -C`; `as_name` is an already-validated subagent name
        from a verb that honours `--as`."""

The function applies the precedence orders above, in order, each step a named block with
a comment naming the defect it exists for. It is the only place any of them appear. It
memoises the party hint for the life of the process, because `take_party_hint` consumes
the entry and unlinks the file, and a resolver called more than once would silently
degrade to "party unknown" — which produces an unidentified lock, the failure mode
`same_party` exists to catch.

`follow_cwd`, `caller_view`, `party_view`, `follow_agent_cwd` and `command_worktree`
become private helpers called only from `resolve_party`. `take_party_hint`,
`leave_party_hint`, `act_as` and `acting` keep their present shape and their present call
sites; they are mechanisms, and `acting` stays at the verb for the reasons in the
Decision Log. `party_key`, `same_party` and `may_release` are unchanged: they compare
parties, they do not resolve them.

Call sites to change, by definition line: `hook_pre_tool` 3038, `hook_post_batch` 2982,
`hook_post_bash` 3221, `hook_prompt_submit` 2912, `hook_record_write` 3653,
`register`/`hook_session_start` 2674/2856, and the read-only callers `cli_status` 3686,
`cli_watch` 3964, `cli_doctor` 5336. `cli_here` 4368 is the *writer* of the pin and must
be specified alongside the resolver that reads it; its subagent branch currently
duplicates `follow_agent_cwd` by hand.

Acceptance: `make test` passes. Any assertion that must change is a behaviour change and
belongs in M1, not here — if one appears, stop, move the change to its own commit with
its own reasoning, and note in `Surprises & Discoveries` which of three things happened:
the change is wrong, M0 mischaracterised the behaviour, or this plan's prose
mischaracterised it. The third is the most likely and the first draft of this plan
demonstrated it.

### M3 — One decision core for commands

Add three functions:

    def plan_for(me, cmd, sessions=None, probe_services=False):
        """What this command touches. Pure: reads state, takes nothing.

        Returns a Plan dict: `resources` (each with its resolved lock name and
        instance), `verdict` ("allow" | "deny" | "warn"), `reason`, `blocker`,
        and `exits`. With probe_services False — the default, and what the
        command-line verbs use — the service-ownership check is not run and no
        subprocess is started."""

    def commit_plan(plan, me, sessions, tool_use_id=None):
        """Take what the Plan says to take, inside the mutex, and return the
        authoritative Plan. The optimistic verdict from plan_for can lose a
        race; do_claim's answer inside the mutex is the one that counts, and
        ignoring it is how two sessions both proceeded before c95399c."""

    def render_block(plan):
        """A Plan whose verdict is 'deny' as the text a session reads."""

An exit is a dict with `cmd` (a runnable command line, fully substituted — not a format
string with `<res>` in it), `when` (one sentence saying when this exit is the right one)
and `kind` (`wait`, `ask`, `steal`, `serve`, `as`, `off`). `plan_for` builds exits from
the same facts it used to decide, so an exit exists only if it would work, and
`test_parity.sh` reads `plan.exits[].cmd` instead of parsing English.

`guard_bash` becomes: `plan_for`, then `commit_plan`, then `serving_check` as today
(after the claim, undoing it on deny, preserving the lock-beats-serve precedence), then
`render_block` if the verdict is deny. The message a reader sees is unchanged in
substance.

Out of scope, stated so it is not mistaken for an oversight: `guard_file`,
`ownership_verdict` and `interference_note` keep hand-written text. They decide about
file paths and declared globs, which a Plan built around resources and lock names does
not describe. A later plan may generalise the Plan to `{verdict, reason, blocker, exits}`
with resources optional; this one does not.

Acceptance: `make test` passes. Any assertion on the *wording* of a command block may be
updated; every such edit must be accompanied, in the same commit, by an assertion on the
`permissionDecision` field, which `assert_deny` and `assert_allow` already provide. That
is the mechanical form of "wording may change, decisions may not".

### M4 — Retire the duplicate paths

The five command-line verbs stop deciding for themselves. `cli_claim`, `cli_release`,
`cli_wait`, `cli_run` and `cli_serve` call `plan_for` with `probe_services=False`, take
the lock names from the Plan, and render the Plan's exits when they refuse. `plan_for`
gains a `names` parameter for this: the verbs have a resource name, not a command, and
synthesising `"agentbus claim simulator"` so that `explicit_resources` can parse it back
is lossy — it loses the instance, because `agentbus claim simulator` contains no `--udid`.

    def plan_for(me, cmd=None, names=None, sessions=None, probe_services=False)

`resolve_lock` is converted to a one-line shim over `plan_for` first, its callers moved
one at a time, and the shim deleted last. `find_resource` keeps its two other callers
(`cli_serve`, `cli_run`) and is not removed. `locks_text` keeps calling `lock_name`
directly: it is a display path over every configured resource with no command in hand,
and it cannot move into `plan_for`. While there, fix its latent bug — with no command it
never sees instance locks, so `status` reports an instance-held resource as free.

The `AGENTBUS_DEBUG=1` environment variable is set for every command run in this
milestone. `main`'s catch-all swallows exceptions and exits 0, so a half-migrated
`cli_claim` would print nothing, exit 0, and let the calling agent believe it holds a
lock it does not.

The two fast paths are not merged — one is bash and one is Python, and the bash one
exists precisely to avoid starting Python. What is pinned instead is their agreement:
extend `tests/test_pyhook.sh` to cover every branch in `bin/ab-hook`. And the real third
copy of the gate decision is the token pre-filter: add an assertion that for a
configuration exercising `unless`, `implies`, `key` and `_explicit`, every command that
`resources_for` matches also matches `guard-tokens`. That is the superset invariant, it
is the one that fails silently, and it broke once before in commit `768f183`.

Acceptance: `tests/live/acceptance.sh all` passes — 36 checks against real Claude Code
sessions on an isolated bus, costing real model calls, and the only check that verifies
the payloads are real rather than what this plan assumes. Plus an AST check, added to
`tests/check_syntax.py`, that `lock_name` is called only from `plan_for`, `locks_text`
and its own definition; a grep count is gameable by renaming a parameter.

### M5 — Re-measure, document, retrospect

Run `tests/perf/hook-cost.py` on macOS and, with the author's help, on the Windows host,
and record both. The gate is on the *delta* between a guarded `PreToolUse` and the
`AGENTBUS_OFF` floor — the two absolute figures are 5 % apart, so a ten per cent band on
the absolute cannot resolve a regression against that background. Record the spread, not
just the median.

Update `README.md`, `SKILL.md` and the module docstring wherever they describe the old
shape. Write the retrospective: what the two spines cost, what they cost to collapse, and
whether the defect rate in those two categories went to zero.

## Concrete Steps

Work from the repository root:

    cd ~/.claude/skills/agent-bus

Before starting any milestone:

    git status --short
    ./bin/agentbus doctor

After every change to any of the three executables:

    python3 -m py_compile bin/agentbus && bash -n bin/ab-hook && \
      python3 -m py_compile bin/hook.py && echo OK

The loop for every milestone:

    make test                      # green before you start
    …make the change…
    make test                      # green after, including the new tests

During M4, run the command-line verbs with exceptions visible:

    AGENTBUS_DEBUG=1 ./bin/agentbus claim db --why "checking"

To exercise anything by hand, isolate the state first:

    export AGENTBUS_HOME=$(mktemp -d)/bus

To falsify a test — mandatory in this repository — copy the tree, break one rule in the
copy, and run the suite there:

    SB=$(mktemp -d); cp -R ~/.claude/skills/agent-bus "$SB/ab"; cd "$SB/ab"
    …edit bin/agentbus to remove one rule…
    ./tests/run.sh test_identity.sh

Never make that edit in the working copy: other Claude Code sessions on this machine
execute `bin/agentbus` from disk on every tool call. A copied tree exercises its own
engine, because `bin/ab-hook` resolves `ENGINE="$(dirname "$0")/agentbus"`.

## Validation and Acceptance

**M0.** `make test` passes with the two new files. In a copy under `$TMPDIR`: remove the
pin check from `caller_view` and `test_identity.sh` fails; remove the instance branch from
`lock_name` and `test_parity.sh` fails. A test that cannot fail proves nothing.

**M1.** One commit per divergence closed, each with `make test` green and the harness
updated in the same commit.

**M2.** `make test` passes with no assertion edited. In a copy, delete the `git -C` branch
from `resolve_party` and a named assertion in `test_identity.sh` fails; delete the pin
branch and another does.

**M3.** In two real Claude Code sessions in two worktrees of one repository: session A
runs a command that takes a declared resource; session B runs a command needing the same
resource and is refused. Take the last line of B's message that begins with `agentbus`,
run it verbatim in B, then re-run the original command. It must now be allowed. Before
this plan, for a `scope: "worktree"` resource, the exit ran and the block stayed.

**M4.** `tests/live/acceptance.sh all` passes. The superset assertion holds for a
configuration using `unless`, `implies` and `key`.

**M5.** The delta between a guarded `PreToolUse` and the `AGENTBUS_OFF` floor is within
ten per cent of the figure in `Artifacts and Notes`, on both platforms.

## Idempotence and Recovery

Every step is safe to repeat. `make test` creates and destroys its own state directory.
`./install.sh` is idempotent. No milestone writes to `~/.claude/agent-bus/` by hand.

The one risky class of change is anything in `bin/agentbus`, `bin/ab-hook` or
`bin/hook.py`, because those take effect immediately in every session on this machine.
Two recoveries, in order of preference: set `AGENTBUS_OFF=1` in the environment of the
affected session, which makes both the fast path and the engine no-op; or
`git checkout -- bin/agentbus`, a single-file rewrite back to the last committed state,
which is always green because nothing is committed until `make test` passes.

Do not use `git stash` for this. It removes and rewrites the file for every session on the
machine simultaneously, mid-tool-call, and `git stash pop` does it again.

## Artifacts and Notes

The cost of a hook before this refactor, measured 2026-08-02 on this Mac with
`python3 tests/perf/hook-cost.py`, median of fifteen:

    bare interpreter start                             15.4 ms
    earliest possible return (AGENTBUS_OFF=1)          41.5 ms
    a PreToolUse that takes a lock                     43.7 ms
    the shell fast path, alone on the bus               4.4 ms

The gate for M5 is the delta: 43.7 − 41.5 = 2.2 ms.

On the Windows 10 host, 2026-07-31, before `bin/hook.py` existed:

    bare interpreter start                            103.5 ms
    earliest possible return (AGENTBUS_OFF=1)         281.0 ms
    a PreToolUse that takes a lock                    420.3 ms

The two live defects the review found, reproduced before they were fixed:

    pinned record : worktree@fefd30
    caller_view   : worktree@c4f9c3        <- what the guard actually used

    advertised    : agentbus claim simulator --as <your name>
    guard verdict : deny

## Interfaces and Dependencies

No new third-party dependencies. The engine uses only the Python standard library and
must keep working on Python 3.8. `hashlib`, `shlex`, `shutil`, `stat`, `socket`,
`fnmatch` and `subprocess` are imported inside the functions that need them, not at module
level, because every hook on every tool call pays for the module's import list; on the
Windows entry point that list was measured at sixty milliseconds. Keep it that way.

New in `bin/agentbus`:

    def resolve_party(payload=None, cmd="", as_name=None) -> (record, view)
    def plan_for(me, cmd=None, names=None, sessions=None, probe_services=False) -> Plan
    def commit_plan(plan, me, sessions, tool_use_id=None) -> Plan
    def render_block(plan) -> str

Removed: `resolve_lock`, last. Made private to `resolve_party`: `follow_cwd`,
`caller_view`, `party_view`, `follow_agent_cwd`, `command_worktree`. Unchanged:
`take_party_hint`, `leave_party_hint`, `act_as`, `acting`, `party_key`, `same_party`,
`may_release`, `find_resource`, `locks_text`.

New files:

    tests/test_identity.sh   the precedence orders, one assertion per rule,
                             asserted through the guard rather than the record
    tests/test_parity.sh     every verb locks what the guard locks for the same
                             command; every advertised exit lifts the block

Files that will be edited: `bin/agentbus`, `tests/lib.sh`, `tests/check_syntax.py`,
`tests/test_pyhook.sh`, `README.md`, `SKILL.md`, `CHANGELOG.md`,
`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.

Files that must not be edited by hand: `hooks/hooks.json`, generated by the installer and
committed because it is the only wiring Claude Code reads.

## What the review changed

An independent agent reviewed the first draft against the code on 2026-08-02. Its
findings and their disposition:

Two findings were live defects rather than plan errors, and were fixed the same day
before this revision: the `agentbus here` pin never bound the guard, and the block message
advertised `agentbus claim <res> --as <name>` while the guard denied it. Both are in
`Surprises & Discoveries` with evidence, and both now have falsified tests.

Four factual errors were corrected: `resources_for` and `expand_implied` have three call
sites, not nine (verified); the eleven cited "block message" lines included four that are
not block messages and omitted at least thirteen that are, and the corrected census is
what forced the scope decision about `guard_file`; the spine-two and milestone tables now
give definition lines consistently; `tests/live/acceptance.sh` has 36 checks and no
`assert`.

Nine design problems changed the design: `plan_for` is now pure with a separate
`commit_plan`, because the deny decision is deliberately made twice; the service probe is
behind a flag, because it shells out and the verbs are pure file operations; `plan_for`
takes `names` as well as `cmd`, because the round-trip through `explicit_resources` loses
the instance key; `resolve_party` returns a record and a view distinguishably, because
four call sites persist what they are given; `acting` stays at the verb, because `--as`
means different things to `post` and to `claim` and because it exits 1; the hint key
keeps coming from `sys.argv`, because `cli_run` passes only the head of its arguments;
the resolver memoises the hint, because taking it is destructive; and `guard_file` is
declared out of scope rather than silently omitted.

Seven pieces of missing scope were added: `locks_text` and its latent instance bug,
`find_resource`'s other callers, `cli_here` as the writer of the pin, `cli_name` and
`cli_doing` as write-back sites, the token pre-filter as the real third copy of the gate
decision, and the remaining callers of `current_session`.

Seven verification gaps were closed: the identity test now asserts through the guard
rather than the record, which is exactly how the shipped pin assertion passed while the
guard was wrong; the parity invariant is restated per-command and the two deliberate
divergences are asserted as intended behaviour; exits become machine-readable in M3
rather than extracted from English; the exit check requires the block to lift, not merely
the exit to be allowed; the grep criterion became an AST check; "wording may change,
decisions may not" became a mechanical rule about accompanying assertions; and the
performance gate moved to the delta.

Four sequencing risks were addressed: the harness became M0 and pins the divergences
rather than requiring them to be absent, so no behaviour changes before the safety net
exists; M2's acceptance now names "the plan's prose was wrong" as the likeliest of three
explanations; `git stash` was removed from the recovery advice; and M4 migrates
`resolve_lock`'s callers behind a shim with `AGENTBUS_DEBUG=1` set, because `main`'s
catch-all would otherwise turn a half-migrated verb into a silent success.
