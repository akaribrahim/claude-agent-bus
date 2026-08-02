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

You can see it working by running `make test` — 1571 assertions, up from the 932 this
plan started against; the "888" this line carried until M5 was stale when it was written
— and by the two adversarial checks this plan adds: a test that walks every command-line
verb and asserts it locks the identical name the guard would *for the same command*, and
a test that takes each block the plugin can emit, runs the exits it advertises, and
requires that running one lifts the block.

## Progress

- [x] (M0) Land the characterisation harness against today's behaviour, divergences
      included, asserting through the guard rather than the record.
      Done 2026-08-02: `tests/test_identity.sh` (125 assertions) and
      `tests/test_parity.sh` (265). 932 → 1322. Nine falsifications for the first,
      three for the second; two verified independently of the agents that wrote
      them. It found four live defects, recorded below.
- [x] (M1) Close the divergences the harness pins, one commit each, updating the
      harness in the same commit as each fix.
      Done 2026-08-02: one commit per decision, 1322 → 1360. Seven behaviour
      changes; two prose corrections where the code was right and this plan was
      wrong, which is the outcome M2's acceptance names as likeliest; one
      confirmation kept as it stood. Every behaviour change was falsified in a
      copied tree by reverting that change alone, both halves separately for the
      one that has a write half and a read half. It found one further live
      defect, recorded below. Every `DIVERGENCE` label in `test_identity.sh` is
      gone and both precedence orders above now state what the engine does,
      which is what M2 turns into `resolve_party`.
- [x] (M2) One resolver for who-and-where — `resolve_party`, replacing the inference
      functions, with the precedence order written down and tested directly.
      Done 2026-08-02: two commits, 1360 → 1376, no assertion edited or renamed.
      `resolve_party(payload, cmd)` returns `(record, view)` and applies both
      orders as nine named blocks; `follow_cwd`, `caller_view`, `party_view`,
      `follow_agent_cwd` and `command_worktree` are private to it; the hint is
      memoised; `require_record` guards the four write sites. Falsified in a
      copied tree four times: the `git -C` block, the pin short-circuit, and
      both of M2's own new checks. `current_session` is gone and `as_name` was
      never added — reasoning below. The second commit exists because the first
      was green through both mistakes this refactor most invites.
- [x] (M3) One decision core for commands — `plan_for` plus `commit_plan`, with the
      guard and the block message rendered from the result.
      Done 2026-08-02: four commits, 1376 → 1433. `plan_for` is pure and
      `commit_plan` claims inside the mutex; `render_block` places
      `plan["exits"]` and composes no command, which an AST check now
      enforces. `serving_check` and `wrong_port_check` return Plans;
      `guard_bash` is four steps. `test_parity.sh`'s hand-written exit table
      is gone — both the assertions and the lines the file *runs* come from
      `plan.exits[].cmd`. One wording change, paired with `assert_deny` and
      `assert_allow` in the same commit; no decision assertion touched.
      Falsified four times in a copied tree, and one of those found the
      purity snapshot was blind to a write that changes no contents.
      The exit `kind` set is `through | ask | correct | bypass`, not the six
      the plan drafted — reasoning below.
- [x] (M4) Retire the duplicate paths: the five command-line verbs call the core; the
      two fast paths are pinned to each other and to the token pre-filter by tests.
      Done 2026-08-02: eleven commits, 1433 → 1571. `plan_for` takes `names`;
      `resolve_lock` became a shim in the first commit, its four callers moved
      one per commit, and the shim was deleted in the sixth — `git log` shows
      that order. `cli_serve` came off `lock_name` last, since it never called
      `resolve_lock`. The verbs do *not* call `commit_plan`; reasoning below.
      A comma list now works end to end, which is three defects of one shape
      closed at once — `claim`, `release` and `wait` each wrote a single lock
      named after the list. `locks_text`'s instance blindness is fixed and
      pinned. `tests/test_pyhook.sh` puts both fast paths through every branch
      of the gate against a stand-in engine and found one divergence.
      `guard_token_line` is extracted so the superset assertion reads the
      string the fast paths read; extracting it found the test's own copy had
      already drifted. Falsified seven times in a copied tree.
      `tests/live/acceptance.sh all` passes: 39 of 39, no failures, on the
      isolated bus, with the live one untouched. It is 39 checks and not the
      36 this plan says — the count moved when the subagent section was added
      and nobody updated the prose.
- [x] (M5) Re-measure cost, update the documentation that describes the old shape, and
      write the retrospective.
      Done 2026-08-02: three commits, no behaviour changed and no assertion
      touched — 1571 as M4 left it. The Mac was re-measured and the figures sit
      beside the pre-refactor ones in `Artifacts and Notes`; **the gate does not
      resolve**, because the delta's own spread is nearly seven times the width
      of the band it is judged against, which is a fact about the instrument and not
      about the code, and what a paired measurement would have to do instead is
      written down there. Windows was not measured: it needs the author's
      machine, and the 2026-07-31 figures now say so on their face. The engine
      is +916 lines and the floor moved 41.5 → ~45.7 ms, about 26 ms of it a
      recompile no hook can cache — recorded as a cost of this refactor, with
      the tool's own figure for caching the bytecode as possible future work.
      `README.md`, `SKILL.md` and the module docstring were updated only where
      the refactor moved what they describe; the two spines' shape, the comma
      form, the `<resource>@<instance>` form and the cost table. Three more
      observations are in `Surprises & Discoveries`, two of them found by
      reading in M5 and neither fixed here.

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

- Observation (M1, 2026-08-02): **the note about implied resources advertised a command
  that took neither of them.** `agentbus claim rig` says it has not taken the bundler and
  offers `agentbus claim rig,bundler`. `explicit_resources` splits a comma list, so the
  guard understands that form and lets it through; `resolve_lock` does not, so the verb
  wrote a lock named literally `rig,bundler`, printed `claimed 'rig,bundler'` and held
  neither. In an isolated bus:

      $ agentbus claim rig,bundler --why probe
      claimed 'rig,bundler'
      $ ls locks/
      repo_f7a1cd__rig_bundler.json
      $ agentbus claim rig --why check
      claimed 'rig'

  The same shape as the instance block closed earlier in M1 — an exit reporting success
  against a lock nothing was contending for — on a surface nobody had looked at, and
  found only because the next commit was about to extend that note to
  `<resource>@<instance>` and would have advertised `agentbus claim
  simulator@ABC123,bundler`, which `resolve_lock` sanitises into
  `simulator@ABC123_bundler` and reports as claimed. That is the typo lock the instance
  form was taught to refuse, reintroduced one commit later through the note. Closed in
  M1, `aaf5f21`, by printing one `agentbus claim <implied>` per implied resource. Note
  for M4: teaching `cli_claim` the comma form was rejected only because it would be a
  second copy of `explicit_resources`'s split inside a verb M4 makes call `plan_for` —
  when it does, `plan_for(names=…)` should take the comma list and this note can go back
  to naming one command.

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
  All three settled in M1, one commit each. `122980c` moved the code so that `git -C`
  beats a pin, through an `override_pin` argument the `stated` branch alone passes;
  `199a805` and `dc2944b` moved this plan's prose for the other two, because a
  declaration beats an inference and a subagent's record is about the subagent.
  One correction to the sentence above, found while doing it: **`party_view` does copy
  `pinned`.** It builds its view with `dict(me)`, so a pinned session's flag is on every
  one of its subagents' views, and the subagent branch does reach `caller_view` — through
  the `git -C` line in `hook_pre_tool`, which runs for both parties. That was the one
  place any subagent path read the flag, and it is the place `override_pin` now bypasses,
  so today nothing reads `pinned` on a subagent's path at all. `resolve_party` should
  keep it that way: the agent's own pin lives on the agent record, where
  `follow_agent_cwd` reads it off disk, and overlaying it into a view whose shape
  `cli_name`, `cli_doing` and `follow_chat_title` write back to the session file is how a
  subagent's declaration would end up pinning its parent.

- Observation (M0, 2026-08-02): **`cli_here` records a pin for a session and not for a
  subagent.** The session branch writes `pinned: True`; the `--as` branch writes the
  same five location fields to the agent record and no flag. So for a subagent the
  root it *declared* and the root that was *inferred* from a payload cwd are the same
  field, indistinguishable — which is why the question above cannot be answered as the
  code stands. Whatever M1 decides, the flag has to exist at both levels for the
  decision to be expressible.
  Closed in M1, `a8f58de`. Worse than "not expressible" as it turned out:
  `follow_agent_cwd`'s docstring claimed the cwd-equals-parent guard existed so a payload
  could not overwrite what the agent declared, and that guard covers only a cwd equal to
  the parent's. Every other cwd walked over the declaration — which is the common case,
  since a subagent told to work in a worktree reports that worktree.

- Observation (M2, 2026-08-02): **`as_name` cannot be passed to `resolve_party` even
  if it should be.** The plan's signature takes an "already-validated subagent name",
  and validating one means `act_as`, which walks `load_agents(me["sid"])` — so a caller
  has to have resolved before it has anything to hand over. The parameter is circular,
  not merely unused, and `acting` staying at the verb is not the only reason it is
  absent. Dropped, with clause (b) of *who is acting* kept in `resolve_party` as a
  block that carries no code and says where it is honoured instead. That block matters:
  without it the function reads as though `--as` had been forgotten.

- Observation (M2, 2026-08-02): **`current_session` was never a session lookup**, which
  is why the question "does it survive underneath the resolver" had an easy answer. Two
  of its lines found a session id; the other forty were `follow_cwd`, `caller_view`,
  `take_party_hint` and `follow_agent_cwd` — half the spine, under a name that promised
  identity. Splitting the two lines back out would have left a cheap door that answers
  "who is acting" with "nobody knows", which is precisely the unidentified lock
  `same_party` exists to catch; a hook or verb reaching for the cheaper call is exactly
  how the spine grew to thirteen functions. It is gone, and `register` — which computes
  a session id too, and honours `pinned` when refreshing an existing record — is left
  alone as the record's *constructor* rather than folded in. `resolve_party` deliberately
  never registers: it is called from `hook_post_batch` and `hook_post_bash`, and a
  PostToolBatch that registered would resurrect a session that had just been reaped. The
  two hooks that may not take no for an answer call `register` and ask again.

- Observation (M2, 2026-08-02): **`current_session`'s own comment said the CLI's re-rooted
  dict "must not be written back", and two verbs wrote it back.** `agentbus name` and
  `agentbus doing` persist whatever `need_me` hands them, and what it handed them was the
  record re-rooted to the caller's shell — plus, whenever a hint existed, a subagent's
  `agent_id` and `agent`. That last part is unreachable today only because `name` and
  `doing` are not in `CLAIMING_VERBS + PASSTHROUGH_VERBS + PARTY_VERBS`, so no hint is
  ever left under their argv. It was one entry in a tuple away from a subagent renaming
  its parent and filing its own identity in the session record. `need_record` and
  `require_record` close it by construction rather than by that coincidence. The re-root
  itself is kept, deliberately: within one repository it is the same rule `follow_cwd`
  applies to a payload, and it is what makes `agentbus doing` from a worktree say where
  the work is.

- Observation (M2, 2026-08-02): **the milestone was green through both of the mistakes
  it most invites**, which is the fifth time this repository has had a green suite
  measuring the wrong thing — and the first where it was noticed before the defect
  rather than after. Handing one value to every caller passes every case in
  `test_identity.sh`, because each drives one party at a time and a view written into
  the session record still describes a real checkout: it is only wrong for the *other*
  party, on the next call. And putting `_party_view` back into a hook — the exact way
  this spine grew to thirteen functions, a hook wanting a subagent's root and reaching
  for the nearest function that has one — leaves all sixteen behavioural files green.
  Both now fail: the first through a section that drives the writing verbs from a party
  a hint identifies as a subagent and then scans the whole bus for a persisted view, the
  second through an AST check in `tests/check_syntax.py` that also refuses to pass by
  having nothing to look for if a helper is renamed.

- Observation (M2, 2026-08-02): **`hook_pre_tool`'s `caller_view` call on the session
  path was already dead.** `current_session` had just run `follow_cwd` over the same
  payload cwd, so by the time `caller_view(me, payload.get("cwd"))` ran, either the
  record already matched the cwd or the session was pinned and both functions returned
  early. The line looked like the one that rooted a session's call and it could not move
  anything; what actually rooted the call was `follow_cwd`, one function earlier and one
  file section away. Nothing in the order changed when it went.

- Observation (M3, 2026-08-02): **the plan's exit kinds named mechanisms and the
  reader needs effects.** `wait, ask, steal, serve, as, off` says which command an exit
  is. What a blocked agent has to know is what running it does, and M0's exit table had
  already found that distinction and used four words for it: `agentbus status` and
  `agentbus post --to <holder>` do not lift anything and do not claim to; `eval
  "$(agentbus env)"` and `agentbus port api` do not lift the block either — they correct
  the command, and the block is *supposed* to stand for the one that was refused;
  `AGENTBUS_OFF=1` steps over the decision rather than resolving it. So `kind` is
  `through | ask | correct | bypass`, and an `id` — `wait`, `steal`, `adopt`, `release`,
  `serve`, `run`, `status`, `ask`, `env`, `port`, `off` — carries the mechanism, because
  `render_block` has to place two exits of one kind in different sentences and a test has
  to be able to ask for one by name. Both fields are needed and neither substitutes for
  the other.

- Observation (M3, 2026-08-02): **the assertion that a message contains its Plan's exits
  is a tautology, and the one that matters is that the message's exits are the ones the
  test runs.** Deleting M0's table leaves `render_block` pinned to the Plan — good, and
  it is what catches a hand-written line creeping back into a message — but it cannot
  catch the Plan advertising something that does not work, because the same object
  produced both sides. What catches that is running the advertised line and requiring the
  block to lift, and that only holds if the line being run *is* the advertised one. The
  literals were left in the run sites at first and they would have drifted silently; they
  now come from `plan_exit <id>`. Three keep a literal deliberately and say so: the two
  lines ending in `<your command>`, and the `agentbus wait --timeout 0` whose whole point
  is being a wording the guard never saw.

- Observation (M3, 2026-08-02): **a content-hash snapshot cannot see the guard's most
  common write.** The new assertion that `plan_for` changes nothing was falsified by
  moving the `matched/` marker writes back into it — and the suite stayed green. Those
  markers are empty files whose contents are identical before and after; only the mtime
  moves. Fixed by hashing contents and stat, and it is the sixth time in this repository
  that a green assertion was measuring the wrong thing — the second found by the
  falsification step rather than by a defect.

- Observation (M3, 2026-08-02): **the race that `commit_plan` exists for was unreachable
  from the suite, and `test_locks.sh` caught it anyway.** `plan_for`'s optimistic check
  and `do_claim`'s check inside the mutex apply the same rule to the same session list,
  so without a genuine race they cannot disagree, and no scenario could reach the
  lose-the-race branch. Making `commit_plan` ignore `do_claim` outright does fail
  `test_locks.sh`'s "no concurrent pair was allowed through twice" — reliably, three runs
  of three, over forty concurrent pairs. That is the real property and it was already
  pinned. What it is not is legible: the failure names concurrency, not the branch. M3
  adds a staged version that opens the interval at human speed — build the Plan while the
  resource is free, let another session claim it, then commit — so the branch has one
  assertion that fails by its own name.

- Observation (M4, 2026-08-02): **the comma list was three defects of one shape, not
  one.** M1 found that `agentbus claim rig,bundler` wrote a single lock named
  `rig,bundler` and held neither. `release` and `wait` took the same string through the
  same `resolve_lock`, so `agentbus release rig,bundler` answered "not yours" about a
  lock that was never taken, and `agentbus wait rig,bundler` found nothing contending
  for a name nobody uses, took it, and printed `claimed 'rig,bundler'` — a wait
  reporting success against two resources it had not looked at, which is the exact
  shape of the instance defect closed in M1 and of the `scope: "worktree"` one closed
  on 2026-07-29. All three closed together here, because they were one line of code.

- Observation (M4, 2026-08-02): **the test that pins the pre-filter had itself
  drifted.** `test_matcher.py` rebuilt `refresh_derived`'s token line rather than
  asking for it, and the rebuild was four lines short of the original: it omitted the
  `agentbus` token that `refresh_derived` adds. Nothing failed, because the fixture's
  only `agentbus` case expected no resources and was skipped. The moment a case was
  added that `resources_for` DOES match through an `agentbus` line — `agentbus serve
  bundler`, which contains none of the configured literals anywhere — the test failed
  against an engine that is correct. A test that reconstructs the thing it is checking
  is the plan's own opening defect, one level up; `guard_token_line` exists so that it
  reads the string the fast paths read. This is the seventh time in this repository
  that a green assertion was measuring the wrong thing, and the second found by
  extending a fixture rather than by a defect.

- Observation (M4, 2026-08-02): **the two fast paths disagreed about an engine without
  its mode bits.** `bin/ab-hook` tests `[ -x "$ENGINE" ]`; `bin/hook.py` tested
  `os.path.exists`. A checkout that lost the executable bit would therefore stop
  guarding on macOS and go on guarding on Windows — the divergence that is worse than
  either answer, because nobody looks for a guard that fires on one platform only. It
  was invisible to every assertion in the suite, all of which compare decisions, and
  most of the gate never reaches a decision: it exists to answer "nothing to do here"
  without starting the engine. Found by putting both files through every branch
  against a stand-in engine that records being woken, and closed with
  `os.access(ENGINE, os.X_OK)` — which has no effect on Windows, where any existing
  file answers yes, so nothing changes there.

- Observation (M4, 2026-08-02): **`plan_for(names=…)` cannot round-trip through a
  command, and `_lock_block` cannot offer a bypass to a verb.** The first was
  predicted by the review and is why `names` exists. The second was not: `_lock_block`
  builds `AGENTBUS_OFF=1 <your command>` for every lock refusal, and `AGENTBUS_OFF` is
  read by the three hook entry points and by nothing in the command-line tool — so
  `AGENTBUS_OFF=1 agentbus claim db` behaves exactly like `agentbus claim db`. A verb
  rendering the full exit set would have advertised it, which is the rule this
  milestone rests on broken by the milestone itself. The exit is now built only when
  the Plan has a command.

- Observation (M4, 2026-08-02): **the live acceptance suite went red for a reason that
  had nothing to do with the code.** The check that a failure naming nobody else's files
  produces no note read the transcript with `tail -12`. How far back twelve lines reach
  depends on how much the model chose to say that turn, and when it was terse the window
  reached into the PREVIOUS turn — where an interference note was correct and expected —
  so the check reported the plugin had done the exact thing it was verifying it had not.
  Once in three runs of the whole suite while M4 was being checked, never in two runs of
  that section alone. For asserting that something did *not* happen, a window sized by
  guesswork is worse than no assertion: a suite that goes red on its own teaches whoever
  runs it to shrug at the colour. This is the same disease as the green assertions this
  plan kept finding, with the sign flipped, and it is the only red one. Closed in
  `78188fe` by taking a record count before the prompt, which is exact and does not care
  how talkative the model is.

- Observation (M5, 2026-08-02): **the event stream still flattens an instance, and the
  status screen no longer does.** `announce_locks` names a lock through `plain_name`,
  which drops everything after the `@`. That is right for `worktree@3f9c1a`, a digest
  nobody typed and which must not appear in the log; it is no longer right for a device,
  because since M1 `simulator@ABC123` is a name an agent types and a block advertises,
  and since M4's `00c9c6b` `status` prints it that way. On an isolated bus a claim on
  `simulator@ABC123` shows as `simulator@ABC123` under "Shared resources in use" and as
  `took 'simulator'` under "Recent", so two agents holding two different devices write
  identical lines. Display only — no decision reads those strings — and left alone here,
  because M5 changes no behaviour.

- Observation (M5, 2026-08-02): **the tool that took these measurements describes a
  machine that no longer exists.** `tests/perf/hook-cost.py`'s docstring says "on Windows
  there is no fast path, so every hook pays for a full interpreter start and a 5000-line
  recompile". `bin/hook.py` has been that fast path since before this plan and the tool
  measures it in a section of its own, and the file is 6732 lines. Not fixed: M5's
  documentation scope was `README.md`, `SKILL.md` and the engine's own docstring, and a
  fourth file's preamble is worth deciding about deliberately rather than in passing.

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
  no `assert` at all. The review said 36 `ok`/`check` calls and this plan repeated it
  until M4 ran the file and counted 39 — the number moved when the subagent section was
  added and nobody re-counted. Counting call sites in the source gives neither, because
  several checks are an `ok`/`bad` pair around one `if`; the run is the count.

- Observation (M5, 2026-08-02): **one unreproduced failure in five full suite runs.**
  While the 2.1.0 version bump was being checked, `make test` reported `1571 assertions,
  1 failure` once. Every file in that run took roughly twice as long as usual
  (`test_subagents.sh` 32s against 17s, `test_detect.sh` 18s against 4s) — the machine
  was running the live acceptance suite and three other sessions at the time. Four full
  runs before and after it were clean, and the failing assertion's name was not captured.
  Recorded rather than dismissed: an unnamed flake is the beginning of the same story as
  the `tail -12` one this plan closed, and the next person to see it should know it has
  been seen before and is suspected to be load-sensitive rather than new.

## Decision Log

- Decision: refactor the two spines in place rather than rewriting the plugin.
  Rationale: the asset worth protecting is not the code, it is roughly twenty measured
  facts about Claude Code that cost real time to learn — `PostToolUse` does not fire for
  a tool call that errored; `agent_id` appears on every hook a subagent causes and none
  the session causes; a subagent's Bash environment is byte-identical to its parent's;
  the chat title is on no payload but the transcript path is; `hooks.json` is the only
  wiring Claude Code reads. Those live in the test suite and in comments. A rewrite either
  carries them across, in which case it is not a rewrite, or rediscovers them expensively.
  The 932 assertions are also the only safety net that makes a change of this size
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

- Decision (M1): `git -C <path>` beats a pin, and the code moved to say so.
  Rationale: a pin is a statement about where a session is working; `git -C <path>` is a
  statement about one command; the narrower, more specific statement wins, which is what
  this plan's precedence order always said. The mechanism was not where it looked —
  `hook_pre_tool` applies `command_worktree`'s answer by *calling* `caller_view`, whose
  pin short-circuit returned before the path was read, so the function meant to apply
  `git -C` was the function that discarded it. Fixed with an `override_pin` argument
  passed only by the `stated` branch, rather than a restructure, because M2 absorbs all
  of this into `resolve_party` and the shape there is not this one. It reaches subagents
  as well, which is not incidental: `party_view` copies the session's `pinned` into every
  subagent's view, so the short-circuit fired on their path too.
  Date/Author: 2026-08-02, Ibrahim + Claude.

- Decision (M1): `agentbus here --as <name>` writes `pinned` on the agent record, and
  `follow_agent_cwd` leaves a pinned agent alone — the same check `follow_cwd` has.
  Rationale: a session's declaration was protected by a flag and a subagent's by a
  coincidence. `follow_agent_cwd` refuses to move on a cwd equal to the parent's, and its
  docstring claimed that guard was what stopped a payload overwriting a declaration — but
  it covers only that one cwd, and every other one walked straight over it, which is the
  common case. The flag has to exist at both levels for the precedence order to be
  expressible at all, and the decision above about a subagent's root beating its parent's
  pin depends on the subagent having a way to declare. The *view* deliberately does not
  carry it: nothing reads `pinned` on a subagent's path, `follow_agent_cwd` reads the
  agent's own record off disk, and `party_view`'s output has the shape three functions
  write back to the session file — one field with two meanings is how a subagent's
  declaration would end up pinning its parent.
  Date/Author: 2026-08-02, Ibrahim + Claude.

- Decision (M1): the note about implied resources keeps refusing to expand, and both the
  line it prints and the name it looks up were fixed instead.
  Rationale: the reasoning for the divergence holds — a claim is a deliberate act, and
  expanding it silently would hold more than the caller asked for, which is why `run` and
  the guard expand and `claim` says so instead. But a warning is worth what its exit is
  worth. It advertised `agentbus claim <res>,<implied>`, a comma list the guard splits and
  the CLI does not, so the line wrote a junk lock and reported success; and it was
  computed from the typed name, so `agentbus claim simulator@ABC123` — the form the block
  about a device now advertises, and therefore the form an agent types — printed no
  warning at all. Teaching `cli_claim` the comma form was rejected as a second copy of
  `explicit_resources`'s split inside a verb M4 makes call `plan_for`; it belongs there,
  with `plan_for(names=…)`.
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

- Decision (M2): `resolve_party` replaces `current_session` outright, drops the drafted
  `as_name`, and gives the command-line tool two doors — `need_me` for the verbs that
  decide and `need_record` for the two that write.
  Rationale: three shapes were considered for the record/view split. A single value was
  rejected for the reason already in the Decision Log, and M2 found that the suite would
  not have caught it. Keeping `current_session` as a thin session-id lookup was rejected
  because it was never one — two of its lines found a session id and forty were the
  spine — and because a cheap door that answers "who is acting" with "nobody knows" is
  the unidentified lock `same_party` exists to catch. A `record=` parameter, so that the
  two hooks which register could feed the fresh record back in, was rejected once
  `register` turned out to set `party_known` itself: calling `resolve_party` a second
  time after registering is exactly equivalent, and the memoised hint is what makes
  calling twice safe at all. `as_name` is circular rather than merely unused, which is
  in `Surprises & Discoveries`.
  Date/Author: 2026-08-02, Claude.

- Decision (M3): an exit carries both what it is and what it achieves, and the four
  effects are `through`, `ask`, `correct` and `bypass`.
  Rationale: the plan's list was six mechanisms and the sentence it has to support is
  "run this and the block lifts" against "run this and you will know more" against "this
  is not the same command any more". Those are effects. `id` keeps the mechanism because
  the renderer places two exits of one kind in different sentences — the unidentified
  block's `wait` sits in its own paragraph and again in the common list — and because a
  test that has to ask for one exit by name would otherwise ask by matching its text,
  which is the hand-written table coming back through the door it left by.
  Date/Author: 2026-08-02, Claude.

- Decision (M3): `guard_bash` leaves `probe_services` off and calls `serving_check`
  itself, after `commit_plan`.
  Rationale: folding the probe into `plan_for` for the guard would put it before the
  claim, and three things depend on it being after. A command denied by the probe has
  already announced and given back what it took, `bump_guarded` has already counted it,
  and the lock-beats-serve precedence is expressed by the lock verdict returning first.
  The flag is honoured where it is documented — `plan_for(probe_services=True)` folds the
  same function in — and the guard is the one caller with a reason not to use it. Both
  paths run one function, so there is still one answer.
  Date/Author: 2026-08-02, Claude.

- Decision (M3): the unidentified block names the agent it is talking to instead of
  printing `--as <your name>`.
  Rationale: it is the last hole in an exit on the command surface, and the Plan was
  holding the value all along — the block only exists for a caller that arrived with an
  `agent_id`, so there is always a name. The line used to end "(yours is in the message
  that named you)", which is a message admitting it printed a template and asking the
  reader to go and fill it in. A caller that genuinely cannot be named now gets no
  `adopt` exit at all rather than one with a hole in it, which is the rule the whole
  milestone rests on: an exit exists only if it would work. This is the one wording
  change M3 makes, and it is paired in its own commit with `assert_deny` and
  `assert_allow` on the decision field either side of running the line.
  Date/Author: 2026-08-02, Claude.

- Decision (M3): the Plan does not describe file blocks, and the three functions that
  emit them keep their hand-written text.
  Rationale: unchanged from the review's boundary, restated here because M3 is where it
  would have been easy to cross. `guard_file`, `ownership_verdict` and `interference_note`
  decide about paths and declared globs; a Plan whose resources each carry a lock name and
  an instance does not describe a file edit refused by somebody's glob. Generalising it to
  fit would leave every field optional and the type meaningless. The honest scope is the
  command surface now and the file surface later.
  Date/Author: 2026-08-02, Claude.

- Decision (M4): the five verbs take the Plan's lock names and its exits, and do not
  call `commit_plan`.
  Rationale: `commit_plan` is the guard's committer and every one of its side effects
  is wrong for a verb. It claims `mode="soft"`, which is a one-command claim that
  `PostToolUse` gives back, where `agentbus claim` is a deliberate hard lock that
  outlives the command. It calls `remember_autoclaim` under a tool-call id a verb does
  not have, so the record would be filed under `none` and released by somebody else's
  next `post-bash`. It calls `bump_guarded`, which counts "commands this session took
  a shared resource for" and is read by the handoff — `agentbus claim db` is not a
  command that took a resource, it is a person taking one. And it writes the
  `matched/` markers, which record that a resource's *patterns* still match something;
  a verb names its resource outright and matched no pattern, so a marker written here
  would tell `doctor` that a stale pattern is healthy. What the verbs do share is the
  rule `commit_plan` states: the optimistic verdict is checked first so that a refusal
  takes nothing, and `do_claim`'s answer inside the mutex is the one that counts — and
  when it disagrees, the refusal is built by `_lock_block`, the same constructor, not
  written out again. `note_plan_block` stays in `guard_bash`: a verb emits no block
  event today, `announce_locks` already speaks for a deliberate claim, and a `claim`
  that both announced itself and filed a block would be two lines for one act.
  Date/Author: 2026-08-02, Claude.

- Decision (M4): an exit that would not work is not built, which is why a Plan with no
  command offers no `AGENTBUS_OFF`.
  Rationale: the rule the whole milestone rests on, applied to itself. `AGENTBUS_OFF`
  is read by `hook_pre_tool`, `hook_post_batch`, `hook_post_bash` and both fast paths,
  and by nothing in the command-line tool. Putting it in front of `agentbus claim db`
  changes nothing at all — it is not even a bypass, it is a no-op — so a verb that
  rendered the block's full exit set would be advertising a line the tool ignores.
  That is the same defect as `agentbus claim worktree`, which was advertised, allowed,
  and wrote a lock nothing read. `_lock_block` builds the exit only when the Plan has
  a command.
  Date/Author: 2026-08-02, Claude.

- Decision (M4): `render_refusal` is a second renderer, deliberately, and shares the
  exits rather than the prose.
  Rationale: `render_block` is a screen-wide banner about a Bash call the guard
  stopped — "BLOCKED", the holder's branch and worktree, "do not work around this by
  editing the command", the resource's `why`. Almost none of it is true of `agentbus
  claim db` typed by a person, who already knows what they asked for and got one line
  of answer before this. Generalising one renderer to cover both would mean a
  paragraph-by-paragraph flag set, which is the shape that makes a message impossible
  to read the next time somebody edits it. What must not be duplicated is the part
  that kept being wrong, and that is the runnable lines: both take theirs from
  `plan["exits"]` and neither composes a command. `agentbus serve` was the last thing
  on the command surface writing its own advice — an `agentbus post --to <holder>`
  line of its own — and it is gone.
  Date/Author: 2026-08-02, Claude.

- Decision (M4): `guard_token_line` becomes a function so the superset assertion can
  read what the fast paths read.
  Rationale: the pre-filter is the third copy of the gate decision and the one that
  cannot be collapsed into `plan_for`, because its whole purpose is to answer without
  starting the engine `resources_for` lives in. So it is held to an invariant instead.
  A test that rebuilt the token line to check it would be the same defect one level
  up — and was: the rebuild in `test_matcher.py` had already lost the `agentbus`
  token, so the first `_explicit` case added to it failed against a correct engine.
  Date/Author: 2026-08-02, Claude.

## Outcomes & Retrospective

### What the two spines cost

Twenty-two defects, root causes assigned by hand, twelve of them in these two categories:
six from guessing who is acting and where, six from the same decision being made in more
than one place. The other ten spread over six causes — configuration expressiveness 3,
packaging 2, observability 2, platform assumption 1, gate logic 1, input handling 1 — and
no other cause reaches three. That distribution is the argument for this plan rather than
a rewrite: two causes account for more than half, and a rewrite would have addressed the
twelve no better than the ten.

Every one of the twenty-two was found in real use. The suite was green through all of
them, and it was 932 assertions when this plan started.

What the twelve cost in kind rather than in count. `agentbus claim worktree` wrote a lock
under the bare name for weeks while the guard filed the same resource as
`worktree@<digest>`: it printed "claimed", exited 0, and held nothing anybody read. A
block offered `agentbus wait <res>` and `AGENTBUS_OFF=1 <command>` and the guard that
printed them refused both. Another told an agent to run `agentbus claim <res> --as <your
name>` and denied exactly that line. On the identity side, thirteen functions inferred
who and where from a session id, an `agent_id` that only a subagent has, and a cwd that
is often not where the work is happening — each added to close one defect and none
removing another. The most recent was half a fix: `agentbus here` pinned the record
`status` prints while `caller_view`, which the guard decides from, had no pin check, so a
declaration a human made was cosmetic.

There is a cost in that list which the list does not show. Three of the defects were
recorded as closed while they were still live — the `here` pin once, the `--as` advice
twice. A defect believed closed stops being looked for, and each of the three was found
again by somebody reading the code rather than by anything running.

### What it cost to collapse them

Thirty-four commits, `5948ffc` to `78188fe`, 04:58 to 09:16 on 2026-08-02 — four hours
and eighteen minutes of wall clock, a commit every seven and a half minutes, six of which
touch nothing but this plan. M1 was the longest stretch, twelve commits over sixty-nine
minutes; M0 the largest single commit, 1336 lines. A good deal of that time was spent
proving tests could fail: twelve falsifications in a copied tree in M0, four in M2, four
in M3, seven in M4, and one per behaviour change in M1 with the write half and the read
half done separately — on the order of thirty-five copied-tree runs, each a rule
deliberately broken to watch an assertion notice.

Assertions went 932 → 1571, +639 and +69 %, across fourteen behavioural files becoming
sixteen, plus three AST checks in `tests/check_syntax.py`. M0's characterisation harness
is 390 of that growth and 1255 lines of test code written before anything was refactored;
those two files are 1895 lines today, and `test_parity.sh` alone is 401 assertions and
twenty-eight seconds, a quarter of the suite's wall clock.

`bin/agentbus` went 5816 → 6732 lines, +916, with 1770 lines changed. The file got bigger
while the number of places answering each question got smaller, and both halves of that
are real: `resolve_party` and `plan_for` hold, in one place each, reasoning that used to
be spread over thirteen functions and five verbs — together with comments naming the
defect every block exists for, which is longer written down than it was scattered.

Every hook that wakes the engine pays for those lines. The floor moved 41.5 → 45.1–46.1
ms, about 26 ms of which is Python compiling a file it is never allowed to cache, because
a hook is handed a script and not an import. The guard's own work is single-digit
milliseconds; the tax for the file it lives in is five times that, and this refactor
added a fifth of the tax. `Artifacts and Notes` records the figures, why the ±10 % gate
on the delta cannot resolve them, and what caching the bytecode would be worth.

### Did the defect rate in those two categories go to zero?

Not knowable, and this plan is not entitled to the claim. What can be said is what was
closed, what is now structurally unavailable, and what is merely passing today.

Eleven defects of these two shapes were closed between the review and M4, and not one of
them was reported from use. Every one was found by looking:

*By the review, before any code moved.* The `agentbus here` pin that never bound the
guard, and the unidentified-party block advertising an `--as` line the guard denied.

*By M0's harness, against unmodified code.* `VERBOSE=1` making every file's assertions
lie. The `--as` advice being reachable and still useless, because `do_claim` refused what
the guard had just been taught to let past. An instance block with no working exit at
all, whose advice took a lock nothing was contending for and reported success. And a
`wait` the guard never saw reporting a claim it had not made, while upgrading a sibling's
one-command soft lock to hard and leaking it.

*While doing M1.* The implied-resources note advertising `agentbus claim rig,bundler`, a
comma list the guard splits and the verb wrote as a single junk lock.

*While doing M4.* The same comma defect in `release` and in `wait`. `locks_text`
reporting an instance-held resource as free, on the screen an agent reads before deciding
whether it needs to wait for anything. And the two fast paths disagreeing about an engine
without its executable bit, so a checkout that lost the mode bit would stop guarding on
macOS and go on guarding on Windows — the divergence worse than either answer.

A twelfth was avoided rather than closed: `_lock_block` would have offered
`AGENTBUS_OFF=1` to a command-line verb, where it does nothing whatever. That is the rule
this milestone rests on, broken by the milestone itself, and it was caught because the
rule was written down.

Structurally unavailable now, which is the stronger claim:

*Advice is generated by the object that decides.* `render_block` places `plan["exits"]`
and composes no command; `check_exits_are_planned` fails if a string containing
`agentbus ` or `AGENTBUS_OFF` appears anywhere inside it, and refuses to pass by finding
nothing if the function is renamed. A message cannot advertise a line the guard would
refuse, because a message no longer knows how to write one down.

*`lock_name` has two callers*, `plan_for` and the display path `locks_text`, enforced by
`check_one_lock_namer` with the same rename guard. `resolve_lock` is gone and the five
verbs take their names from a Plan; the twelve call sites that used to answer "under what
name is this locked" are two.

*The five who-and-where helpers are private to `resolve_party`*, enforced by
`check_one_resolver` with the same rename guard, and `current_session` is gone — so there
is no cheap door left that answers "who is acting" with "nobody knows", which is the
unidentified lock `same_party` exists to catch and precisely how the spine grew to
thirteen functions the first time.

*The exit check runs the advertised line.* `test_parity.sh` takes it from
`plan.exits[].cmd` rather than retyping it, runs it, and requires the originally denied
command to be allowed afterwards. "The guard allows the exit" is not that property:
`agentbus claim worktree` was allowed, perfectly, for weeks.

Merely passing today, and the list is not short:

*The token pre-filter* is a third copy of the gate decision and cannot be collapsed,
because its purpose is to answer without starting the engine `resources_for` lives in. It
is held to a superset invariant by one fixture exercising `unless`, `implies`, `key` and
`_explicit`. A resource shape nobody thought to put in that fixture is not covered, and
this is the failure mode that is silent in both directions.

*The two fast paths* are two implementations of one gate in two languages, pinned by
`test_pyhook.sh` driving both through every branch against a stand-in engine. That is
agreement demonstrated, not agreement by construction: a branch added to one and not the
other is caught only if somebody also adds the case.

*The file surface still writes its own advice.* `guard_file`, `ownership_verdict` and
`interference_note` were put out of scope deliberately, and the review's census says most
advice sites are there. The class of defect this plan opens with is closed on the command
surface and open on the file surface.

*Windows is unmeasured* for cost, and everything above was demonstrated on this Mac.

The reason to refuse the word "zero" is in this repository's own record. The pin fix
shipped with an assertion that asked the session record, and the record was right for the
whole time the guard was wrong. The `--as` advice was recorded as closed on 2026-08-02
and was still live; M0's harness found it again the same day and it took M1 to close it.
Two half fixes in one plugin in one week is a base rate, not an anecdote. What this plan
is entitled to claim is narrower and worth more: the two categories are structurally
harder to re-enter than they were, three AST checks fail if the collapse regresses, and
the next honest data point is the next month of real use.

### The most reusable thing this produced

Not the two functions. The rule that every assertion is falsified in a copied tree —
break the thing it claims to pin, run it, watch it fail — together with the habit of
asking a green suite what it would still be green *through*.

Six green assertions that measured the wrong thing turned up while this plan ran, counted
from `Surprises & Discoveries`:

- the pin assertion that asked the session record while the guard was wrong — found by
  the independent review, reading;
- `VERBOSE=1`, which put the harness's own `ok` lines on stdout and therefore inside
  `out=$(ab_hook …)`: 22 of 118 assertions in `test_subagents.sh` failed under the flag
  documented for inspecting them, and 11 of 100 in `test_serving.sh` — found by using it;
- `test_identity.sh` staying green when `resolve_party` hands one value to every caller,
  because each case drives one party at a time — found by the falsification step;
- all sixteen behavioural files staying green when a hook reaches for `_party_view`
  directly, the exact mechanism by which the spine grew to thirteen functions — found by
  the falsification step;
- the purity snapshot for `plan_for`, which hashed contents and so could not see the
  `matched/` marker writes, whose contents never change and whose mtime does — found by
  the falsification step;
- `test_matcher.py` rebuilding `refresh_derived`'s token line instead of asking for it,
  four lines short, having silently lost the `agentbus` token: a test reconstructing the
  thing it checks, which is this plan's opening defect one level up — found by extending
  the fixture with a case that matches through an `agentbus` line.

Three of the six were found by the falsification step itself rather than by any defect,
which is the whole argument for the discipline: it pays before anything breaks. One was
found by using the documented tool, one by extending a fixture, one by an outside reader.

And one red-but-wrong, the same disease with the sign flipped: the live acceptance check
that read `transcript | tail -12` and, when the model was terse that turn, reached into
the previous turn and reported the plugin had done the exact thing it was verifying it
had not.

A note on the count, because this plan's own numbering does not add up. The four
pre-existing entries listed in M0 plus these six give eight, but M0's `VERBOSE` entry
calls itself "a fifth entry" and M2's calls itself "the fifth time", so M3 reads "sixth"
and M4 "seventh" where a consistent count says seventh and eighth. The running total is
not the interesting number anyway. The interesting number is six, in four hours, in a
repository whose suite was green throughout.

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
    bin/agentbus                 the engine and the command-line tool, ~6700 lines
                                 (~5800 before this plan; the growth is M5's
                                 problem and is measured in Artifacts and Notes)
    bin/ab-hook                  the bash fast path, ~177 lines
    bin/hook.py                  the Python fast path (Windows), ~264 lines
    hooks/hooks.posix.json       wiring that calls bin/ab-hook
    hooks/hooks.python.json      wiring that calls bin/hook.py; __PYTHON__ substituted
    hooks/hooks.json             the file Claude Code actually reads; committed
    tests/run.sh                 the runner; isolates AGENTBUS_HOME
    tests/lib.sh                 assertions and fixture builders
    tests/test_*.sh|py           sixteen files, 1556 assertions; with the
                                 structural checks `make test` reports
                                 17 files, 1571
    tests/check_syntax.py        15 structural checks, three of them the AST
                                 checks this plan added
    tests/live/acceptance.sh     39 checks against real Claude Code sessions
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

**Superseded by M2 as of 2026-08-02.** What follows is the shape the milestone started
from; the definition lines are stale and the census is history. The two precedence
orders below are *not* history — they are the specification, they are what
`resolve_party` implements block by block, and `tests/test_identity.sh` pins them.

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

**Superseded by M3 and M4 as of 2026-08-02.** What follows is the shape the two
milestones started from. `plan_for` answers the whole of it now, from a command or
from a name; `resolve_lock` is gone; `lock_name` has two callers, `plan_for` and the
display path `locks_text`, and an AST check keeps it that way. The two divergences
below are still the specification and `tests/test_parity.sh` still pins them.

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

M0 pinned both as intended behaviour and M1 decided each in a named commit. The first
stands: `cli_claim` still refuses to expand and still says so. What changed is the note,
which was wrong twice — it advertised a comma list the CLI cannot resolve, and it printed
nothing at all for `<resource>@<instance>`. The second changed: `resolve_lock` learned
the `<resource>@<instance>` form, because the block about one device has to advertise a
line that acts on that device.

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
string with `<res>` in it), `when` (one short line saying when this exit is the right one
or what running it gives you), `kind` (what running it achieves) and `id` (which exit it
is). As built, `kind` is `through | ask | correct | bypass` rather than the six mechanism
names this paragraph first listed, and `id` carries the mechanism; the reasoning is in
the Decision Log. `plan_for` builds exits from the same facts it used to decide, so an
exit exists only if it would work, and `test_parity.sh` reads `plan.exits[].cmd` instead
of parsing English — for the lines it runs as well as the lines it asserts on.

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

Four things M3 leaves for it, found while building the Plan:

- `commit_plan` writes the `matched/` markers, calls `bump_guarded` and announces an
  explicit claim. Those are right for the guard and have to be decided for a verb:
  `agentbus claim db` counting towards "commands this session took a shared resource
  for" is a change to what a handoff reports.
- `note_plan_block` is called by `guard_bash` and not by `commit_plan`, so a verb that
  commits a Plan emits no block event. That matches today's behaviour and is the reason
  it sits where it does; say so rather than move it by accident.
- `plan_for(names=…)` should take the comma list, which is the note in
  `Surprises & Discoveries` about `agentbus claim rig,bundler`.
- `serving_check` takes a Plan now, so `cli_serve` and `cli_run` can ask the same
  question the guard asks instead of their own.

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

Acceptance: `tests/live/acceptance.sh all` passes — 39 checks against real Claude Code
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

After it, 2026-08-02, the same Mac and the same tool, Python 3.14.3 on darwin. Each
figure below is that tool's own median of fifteen; the whole tool was then run five
times over, which is where the spreads come from:

    bare interpreter start                             15.9 ms
    earliest possible return (AGENTBUS_OFF=1)     45.1 – 46.1 ms   (five runs)
    a PreToolUse that takes a lock                47.3 – 50.0 ms   (five runs)
    read + compile 6732 lines                          41.9 ms
    the shell fast path, alone on the bus               5.1 ms
    the Python fast path, nothing to do                17.4 ms

    delta (lock minus floor), six samples: 1.4, 1.9, 2.4, 3.2, 3.4, 4.4 ms
      median 2.8, min 1.4, max 4.4

**The gate does not resolve, and this is a fact about the instrument.** The gate was
moved off the two absolutes because they are five per cent apart and a ten per cent band
on either cannot see a regression against that background. But the delta is the
difference of two nearly-equal noisy numbers and it inherits both noises: the band it is
judged against is ±10 % of 2.2 ms, which is 1.98 to 2.42 and 0.44 ms wide, and the six
samples span 1.4 to 4.4 — three milliseconds, nearly seven times the width of the band
that is supposed to contain them. The median moved from 2.2 to 2.8, which is inside that
noise; so would a move the same distance the other way. The correct statement is neither that the gate
passed nor that it failed — it is that **this measurement cannot answer the question the
gate asks**, and no amount of reading it more carefully will change that.

What a gate that could answer it would need. The delta has to be measured as a *paired*
difference — the same process, one run with `AGENTBUS_OFF=1` and one without, alternating
so that whatever the machine is doing is common to both halves of each pair — and
reported as a distribution over pairs rather than as the difference of two independently
taken medians. At two milliseconds against a forty-five millisecond floor the thing being
measured is a four per cent effect, so pairing is not a refinement; it is the only way
the measurement exists at all. n on the order of a few hundred pairs, an interval quoted
rather than a median, and the run pinned to one interpreter. Until `hook-cost.py` does
that, the honest form of this gate is the weaker claim the numbers do support: the
guard's own work — resolve, plan, claim, release — is single-digit milliseconds against a
floor that is an order of magnitude larger.

**The engine got bigger and every hook that wakes it pays for that.** `bin/agentbus` went
from 5816 lines to 6732, +916, and the floor a hook cannot go below moved with it: 41.5 →
45.1–46.1 ms. The same tool attributes it — "read + compile 6732 lines, 41.9 ms", of
which 15.9 is the interpreter, so roughly 26 ms of every woken hook is this file being
compiled from source. A hook script is never bytecode-cached: Python writes a `.pyc` for
a module it imports and not for a file it is handed as a script, so that recompile
happens on every single invocation. That is a real, measured cost of this refactor. It is
an order of magnitude larger than the guard's own work, and larger than the change the
gate above was built to detect and cannot.

The same run says what the remedy would be worth: "saved by caching the bytecode: 24.7
ms, 56 % of a hook". **Out of scope here and not a promise.** Collecting it means making
the engine an importable module with a thin script in front of it, on three platforms,
with `hooks.json`, `bin/ab-hook` and `bin/hook.py` all pointed at the new entry point and
the `._pth` trap on the Windows embeddable Python handled. It is recorded because the
number is large and because the measurement that would justify the work has now been
taken twice, before and after.

On the Windows 10 host, 2026-07-31, before `bin/hook.py` existed:

    bare interpreter start                            103.5 ms
    earliest possible return (AGENTBUS_OFF=1)         281.0 ms
    a PreToolUse that takes a lock                    420.3 ms

**Those are pre-refactor figures and they have not been re-taken.** M5's acceptance asks
for both platforms; the Windows measurement needs the author's machine and nobody has run
the tool there since. Nothing in this section should be read as a Windows result. What
can be said without one: `bin/hook.py` now answers the common case there without waking
the engine at all, so the +916 lines land only on the calls that do wake it — and they
land harder, because on 2026-07-31 the gap between a bare interpreter start and the floor
was already 178 ms, most of it the same read-and-compile this Mac measures at 26.

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
    def render_refusal(plan, note="") -> str      # M4; a verb, not the guard
    def guard_token_line(configs) -> str          # M4; the pre-filter, extracted

Removed: `resolve_lock`, last. Made private to `resolve_party`: `follow_cwd`,
`caller_view`, `party_view`, `follow_agent_cwd`, `command_worktree`. Made private to
`plan_for`: `_named_resources`, `_named`. Changed in M4: `contending_locks` takes the
lock name rather than a command, which is what let `locks_text` use it; `lock_name`
honours an instance already on the resource, which is how a caller says which device
when there is no command to read one off. Unchanged: `take_party_hint`,
`leave_party_hint`, `act_as`, `acting`, `party_key`, `same_party`, `may_release`,
`find_resource`, `expand_implied`, `locks_text`.

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
give definition lines consistently; `tests/live/acceptance.sh` has no `assert` at all
(and 39 checks, not the 36 the review counted — see above).

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
