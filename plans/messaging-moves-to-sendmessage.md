# Messaging moves to SendMessage; the bus keeps the locks

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`,
`Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

Maintained in accordance with the exec-plan skill. This repository is a standalone Claude
Code plugin written in Python and bash: no database, no web framework, no mobile app.

Written 2026-09-05. **Revision r2, the same day**: an independent agent reviewed r1 against
the source before any code was written and returned 16 defects, 5 design problems, 10
pieces of missing scope, 5 sequencing risks and a verification gap in nearly every
milestone. Three of its findings changed the design rather than the wording, and one killed
a milestone outright. What it found is in `Surprises & Discoveries`; what changed because
of it is in the `Decision Log`. r1 is kept only as a diff in git history.

## Purpose / Big Picture

Claude Code now ships session-to-session messaging of its own: `ListAgents` names every
live session on the machine, `SendMessage` delivers text to one of them, and the reply
arrives in the sender's own conversation. That is the half of agent-bus that agents used
most, and it is now duplicated by something better placed to do it — it runs inside the
session, it **wakes** an idle recipient, and it needs no cursor, no event log and no
context injection.

The other half is not duplicated at all. Nothing in Claude Code knows that `:8082` is
answering for a different checkout than the one asking, that a reseed is about to
invalidate every id another session cached, or that a `git add -A` in a shared checkout
sweeps up somebody else's half-written work. That is what this plugin exists for.

So: **messaging leaves, wholesale, and the bus becomes locks, service ownership and
presence.** Not a deprecation that lingers — the two channels running side by side is
itself the defect, because an agent that posts to the bus believes it has told somebody
and the recipient's conversation never mentions it.

### The thing that changes the guard, not just the plumbing

The bus's messaging had one weakness that no amount of polish would have fixed: **it could
not trigger anybody.** A posted message waited in the log until the recipient's next turn,
and for an idle session that is whenever its human comes back. So every block message that
ended "ask them" was offering advice that could not be taken. This machine's log has the
consequence: 2026-09-04, `nightly` was blocked on `db` at 14:38:31 and stepped past the
guard with `AGENTBUS_OFF` at 14:38:42. **Eleven seconds** is how long "ask the holder" was
considered.

`SendMessage` wakes the recipient and it answers without its human — measured, not assumed:
of 127 cross-session arrivals in the transcripts, fifteen landed on a session that had been
silent for more than 45 minutes and **every one was answered within 36 seconds**; the
extreme is a session idle for 20.7 hours that acted 21 seconds after the message arrived.

That turns a lock from a verdict into the opening of a negotiation. M5 is that negotiation,
and — this is r2's correction — it is built out of the queue, the waiter and the release
that already exist, not out of a new lending verb. See D6.

### What was measured, 2026-09-05

Method, because r1 got this wrong and the wrong number is quotable: bus figures are
`kind == "note"` events in `~/.claude/agent-bus/events.jsonl`, split into machine notes
(renames, ownership declarations, service churn) and sentences an agent actually wrote;
`SendMessage` figures are tool calls in `~/.claude/projects/*/*.jsonl`, split by whether the
target is a peer session or one of the sender's own in-process subagents. 09-05 is a partial
day.

| day | agent-written bus posts | machine notes | peer SendMessage | subagent SendMessage |
|---|---|---|---|---|
| 09-01 | 404 | — | 30 | 42 |
| 09-02 | 72 | — | 48 | 5 |
| 09-03 | 67 | — | 28 | 17 |
| 09-04 | 26 | — | 32 | 9 |
| 09-05 | 11 | 6 | 17 | 0 |

Two things the r1 table claimed and this one does not. **The 09-01 peak is one orchestration
run, not a baseline**: 403 of its 404 notes came from a single session and its ten subagents
(`audit`, `audit/1`–`/10`), and it has not recurred. And of the 426 `SendMessage`
calls in the whole sample, **269 target in-process subagents**, not peers; the peer series
above is the honest one.

What survives the correction is still the reason for this plan: agent-written bus traffic
fell from 404 to 11 while peer-to-peer messaging held steady around 30 a day, and the lock
half did not move at all — 103, 11, 91, 29 and 19 lock/block/serve events on the same five
days.

## Context and Orientation

### The discovery this plan rests on

Claude Code keeps a session registry at `~/.claude/sessions/<pid>.json`. Observed shape on
2.1.261:

```json
{"pid":92245,"sessionId":"18f7c78b-...","cwd":"/Users/.../product",
 "startedAt":1788626791704,"version":"2.1.261","kind":"interactive",
 "messagingSocketPath":"/tmp/cc-socks/92245.sock","name":"product-86",
 "nameSource":"derived","status":"busy","updatedAt":1788627149860}
```

`sessionId` is byte-identical to the bus's own `sid` and `pid` to the bus's `pid` — two
independent join keys onto records the bus already writes. So the bus can print, for any
peer, an address that actually works.

**Two addresses, and the plan prefers the second.** `name` is what `ListAgents` shows and
what a human reads. `messagingSocketPath` is also accepted by `SendMessage` in the form
`to: "uds:/tmp/cc-socks/75336.sock"` — six such sends in the transcripts, all successful.
The socket path is collision-free, survives a rename mid-session, and joins on `pid` with no
ambiguity, so `address_of` prefers it and prints the human name beside it. That single
choice dissolves three separate problems r1 had planned around: duplicate names (common —
one listing on 2026-08-22 shows `ibrahim1` twice, another on 08-26 shows four duplicated
names), renames mid-session, and a `[ref]` disambiguator the bus cannot compute.

**The naming systems do disagree.** Joined on this machine today: `orches`, `pair1`,
`hotfix` and `nightly` match; `checkout-rewrite` on the bus is `product-86`
to Claude Code, because that chat has no title and the two fall back differently. Printing
the bus name would have sent that session's peers to an address `SendMessage` rejects.

Three more facts, all of which change the design:

- **The registry is a subset of what `SendMessage` can reach.** It holds only
  `kind: "interactive"` sessions — six files today — while `ListAgents` also lists Remote
  Control peers that have no file there at all. Observed `status` values are `busy`, `idle`,
  `shell`, `running` and `offline`. The bus's roster must therefore say "these are the local
  sessions I can see; `ListAgents` may know more" rather than presenting itself as complete.
- **Two live sessions had no bus record** (`pair2`, `hotfix2`), reaped by the heartbeat
  while their processes were alive and messageable. `load_sessions(reap=True)` drops a
  session that has merely been quiet.
- **The bus cannot send.** There is no `claude message` CLI (`claude --help`, 2026-09-05).
  Whatever the bus still needs to tell another session, it tells through context injection
  or not at all. Writing to `messagingSocketPath` by hand is out of scope: that path is an
  address to hand to the tool, not a protocol to implement.

### What is being removed, and what stays

Stays, untouched in intent: presence, resource locks, the interference guard, the
wrong-port guard, per-worktree ports, `serve`/`serves`/`run`, declared file ownership,
`status`, `watch`, `board`, `here`, `doctor`, `install`, `init-repo`.

Goes: `post`, `note` (the alias), `inbox`, `take`, `done`, `doing`, `handoff`, the task
ledger, and the delivery of anything an agent wrote by hand.

## Surprises & Discoveries

From the independent review of r1, 2026-09-05. Kept because each one is a fact about this
codebase that outlives the plan.

1. **The holder is a subagent three quarters of the time.** 87 block events in the log name
   a holder; **64 (74%) name a subagent** — `orches/2`, `seeder/1`. `SendMessage` cannot
   address another session's subagent. r1's whole negotiation design pointed at an
   unreachable address, including in the incident it used as motivation: `nightly` was
   blocked by `seeder/1`, not by `seeder`.
2. **`note` is not "a sentence an agent wrote".** It is emitted from seven sites and only
   one is `cli_post` (`bin/agentbus:6597`). The other six are machine facts carrying no
   `to`: resource churn (`:3078`), the rename notice (`:4539`), `agentbus name` (`:9684`),
   ownership declared (`:10011`) and withdrawn (`:10041`), and an integration worker joining
   (`:8899`). r1 would have silenced all six — including the rename notice, which is the
   plugin's only defence against exactly the address divergence M0 exists for, and the
   ownership declaration, whose whole point is that a peer learns before the block.
3. **An automatic release would have destroyed a lease in one command.** `commit_plan`
   appends an already-held lock to `taken` and calls `remember_autoclaim` (`:5665-5673`);
   `release_autoclaim` then unlinks any `mode: "soft"` lock whose `sid` matches the caller
   (`:4924-4928`). A lease transferred to the borrower carries the borrower's `sid`, so the
   borrower's first guarded command would have freed it — and r1's acceptance test would
   have passed anyway.
4. **There are already two expiry clocks and both are shorter than r1's.** `SOFT_TTL` 15
   min, `IDLE_SECS` 5 min, `HARD_TTL` 45 min (`:118-120`); `lock_state` marks a soft lock
   stealable after 5 minutes of holder quiet and `sweep_locks` then unlinks it (`:922-947`).
   r1's 10-minute default and 60-minute ceiling both sat inside a clock that would have
   deleted the lease first, and in the window before the sweep a third session's `do_claim`
   takes it with no block and no notice.
5. **`may_release` does not answer "who may lend".** It returns true for any subagent of the
   holding session (`:1694-1710`); its docstring frames the question as giving something
   *back*. Reusing it would have let any subagent lend away its parent's database.
6. **A test executes the block message's advice as a shell command.**
   `tests/test_parity.sh:640` runs `$(plan_exit ask)` and then asserts the block is still a
   deny. After M4 the `ask` exit is a tool instruction, bash fails, and **the assertion still
   passes** — in the file whose own header says this repository has four times shipped a
   green assertion that measured the wrong thing.
7. **r1's acceptance metric could not be measured.** "`AGENTBUS_OFF` bypasses of a held
   resource go to zero" — the opt-out event records `overrode`, which `plan_for` fills with
   the resources the command touches (`:5569-5570`), never with who held them. The count
   would read zero on day one and every day after, whether or not the change worked.
8. **`queued_for` is rendered on the waiter's row, never the holder's.** It is built inside
   `ledger_view` (`:2539-2545`), filtered to the waiter's own `sid`, and printed by
   `task_line` and the board's task pane — all of which M6 deletes. `locks_text`, which is
   what `status` actually prints, never mentions a queue at all.
9. **`cli_wait`'s "waiting for 'X'" note survives M3 regardless**, because `interesting_to`
   tests `to` *before* it tests the kind (`:2086-2093`). M5 depends on that ordering.
10. **`[ref]` is stable even though it cannot be computed.** `nightly` has been
    `[93ccbf]` from 2026-08-11 to 2026-09-05, across a rename. Not a hash of `sessionId`,
    `pid`, the socket path or `bridgeSessionId` (md5/sha1/sha256/sha512/blake2 all checked).
    Observable and cacheable; never derivable.

### Measured while building it, 2026-09-05

11. **A genuinely idle session wakes and runs a peer's command without its
    human — and that is not the same as replying.** M5's gate zero, run twice on
    the live machine. The first subject looked ideal in the registry (`idle`,
    eight hours and forty minutes old) and answered in seconds — then said so
    itself: it had been mid-task the whole time and the run measured the easy
    case. That correction is finding 12. The second subject had been quiet for
    fifty minutes. The message arrived at 18:55:32; it was running `agentbus
    status` at 18:55:52, twenty seconds later, with no human involved; at
    18:56:26 it wrote a summary **addressed to its human** rather than a reply to
    the sender, and stopped.
    So the half M5 depends on is confirmed: a woken session executes a peer's
    `agentbus` line by itself, which is what "release it when your command is
    done" requires. The half that is not guaranteed is the answer coming back.
    The design already survives that — the waiter's `wait` takes the lock the
    moment it frees, whether or not anybody says so — but no wording anywhere
    should promise a reply.
12. **The registry's `status` is not a heartbeat.** It is written when a session
    changes state, so `idle` with a timestamp eight hours old told us nothing
    about a session that was working continuously. Every roster line and every
    block that says "(idle)" was therefore about to state something it could not
    know. Fixed in the same pass: a status older than `IDLE_SECS` is not reported
    at all, and the bus's own heartbeat — derived from hooks actually firing —
    is what the roster falls back to.

## Decision Log

D1–D5 were taken by İbrahim on 2026-09-05 before work began. D6 was taken the same day and
rewritten after the review; D7 and D8 are the review's.

**D1 — `post`/`inbox` become redirects, not removals.** They keep working as commands and
stop working as messaging: they resolve the recipient, print the exact
`SendMessage` call to use, and exit non-zero. The habit is baked into RULES, README, other
repositories' `.claude/agent-bus.json` hints and several agents' memory files; a bare
"unknown command" would strand a session that had learned the old way. One release of
redirect, then deletion. `note` is an alias of `post` (`:10779`) and inherits this.

**D2 — The injection channel narrows to machine facts.** No sentence an agent wrote is ever
delivered again. What still is: the wrong-port bypass, a service moved to another checkout
under you, a lock of yours stolen, a peer declaring ownership, a peer renaming itself, and
resource churn — the six machine emitters of finding 2, which get kinds of their own rather
than being swept away with `note`. The header stops saying "new messages" and says what it
is: what changed under you while you were working.

**D3 — The bus records SendMessage traffic, with the text.** `PreToolUse` gains a
`SendMessage` matcher; the call is logged as a `msg` event and never delivered. `watch` and
`board` keep working as the one place a human sees the whole machine talking.

**D4 — `take`, `done`, `doing` and `handoff` all go.** The bus becomes locks + serve +
presence. `doing` is already derived without being asked (`acted/`, since 2.9.0), and
`handoff` is written at SessionEnd, the one moment the session can no longer call
`SendMessage`.

**D5 (open) — `merges`/`integrate` are re-based on branches, not tasks.** `merge_view` reads
`ledger_view` rows whose state is `done`; D4 deletes its only input, which would leave two
commands that run, print nothing and look healthy. The recommendation is to rebuild the
candidate set from git — branches in a worktree of this repo, or on a session record, that
are ahead of trunk — keeping `merge_tree` untouched. The honest alternative is deleting both
commands. **İbrahim to confirm before M6 lands**; an unresolved decision inside a milestone's
gate is a milestone that cannot be verified.

**D6 (rewritten after review) — the negotiation is queue-first; there is no lending verb.**
r1 proposed `agentbus grant`, a timed transfer of a lock. Findings 1, 3, 4 and 5 say that
verb collides with the automatic claim/release path, with both existing expiry clocks and
with the party model, and — decisively — that it cannot address the holder in 74% of real
blocks. The mechanism it wanted already exists: `enqueue` records the waiter on the lock
(`:6511`), `cli_wait` announces it *addressed to the holder* so it is delivered
(`:6494-6499`), and `cli_wait` takes the lock the moment it frees (`:6488-6492`). The one
missing piece is that **nobody renders the queue where the holder reads it**. So M5 adds the
queue to `locks_text`, composes the message that wakes the holder, and ends in `release` —
one change, no new state, and it works when a subagent holds the lock, because the parent
can release its own party's lock. İbrahim chose this over fixing the lease, 2026-09-05.

**D7 — the lease is not cancelled, it is deferred.** Automatic return matters for a long
hold (a reseed), and D6 does not give it: after a plain release the former holder must
re-queue like anybody else. `grant` moves to Phase 2, to be reconsidered once the queue
change has been live for a week and finding 3's `mode: "hard"` requirement, finding 4's
single-clock rule and finding 5's `may_grant` are specified rather than assumed.

**D8 — permission mode is part of the design, not an environmental detail.** A composed
message that asks a peer to *run a command* only works if that peer can run it without
stopping for its human. In this repository it can: `.claude/agent-bus.json` allowlists
`Bash(agentbus:*)`. Elsewhere it may not, and `SendMessage`'s own guidance warns against
asking a peer to do what was blocked in your own session. So the composed message asks the
holder to release **its own** resource — a decision about its own work, not a permission
laundered around a denial — and M5's gate zero measures whether a recipient in each
permission mode actually runs it.

## Plan of Work

### M0 — The address book: read Claude Code's session registry

- `cc_sessions()` — every readable `<CLAUDE_CONFIG_DIR|~/.claude>/sessions/*.json`, parsed
  defensively: a missing or unexpected field yields a record without it, never an exception.
  Entries whose `pid` is dead are marked stale and never offered as an address. Cached per
  process.
- `address_of(rec)` — joined on `sessionId`, falling back to `pid`. Returns the
  `uds:<messagingSocketPath>` form as the address and the `name` as the label (see Context).
  Returns `None` when there is no registry entry, and every caller renders that as "run
  `ListAgents` for its address" rather than guessing.
- `cc_status(rec)` — the registry's own string, whatever it is. The five observed values are
  `busy`, `idle`, `shell`, `running`, `offline`; an unrecognised one is printed verbatim
  rather than mapped, because a value this plugin has not seen is not a value it should
  translate.
- **Subagents (finding 1).** A bus party like `seeder/1` is in-process to `seeder`.
  `address_of` on it returns the parent's address together with the subagent's name, and
  every caller must print both: *"held by `seeder/1`, a subagent of `seeder` — message
  `seeder` and say it is about `seeder/1`"*. A caller that prints only the parent is a
  defect, and `tests/test_address.sh` asserts the subagent name appears.
- The roster says it may be incomplete: Remote Control peers are reachable and absent here.

Verification: `tests/test_address.sh` against a fixture registry — matching name, divergent
name, missing entry, dead pid, duplicate names, subagent, unreadable file, malformed JSON,
non-interactive `kind`. Live on this machine: for every peer, the address the bus prints is
one `ListAgents` also lists.

Falsifier (r1's was too weak — it only caught over-reporting): **the divergent session's
address must be the Claude-side one.** If `status` prints `checkout-rewrite` where
`ListAgents` says `product-86`, M0 is not done. Second falsifier: a subagent-held lock
must print the parent's address and the subagent's name.

### M1 — The roster and the banner speak SendMessage

`roster_text()` gains address, label and status:

```
Other sessions on this repo (2):
  - orches   ~/.../worktrees/worktree-a   feat/worktree-a   (last seen 1m ago)
      message it:  SendMessage → to "orches"   (idle)
  - hotfix   ~/.../worktrees/worktree-b   worktree-b   (2m ago)
      message it:  SendMessage → to "hotfix"   (busy)   · subagent hotfix/1 also live
Live on this machine but not on the bus: 2 (addressable; `ListAgents` for the full list).
```

`RULES` is rewritten: what the guard does, that talking to another session is the
`SendMessage` tool with the addresses above, and the one unenforced rule (do not fix files
you did not edit — ask the owner). The `doing:` line goes with M6.

Verification, strengthened after review: it is not enough that the banner mentions
`SendMessage` — r1's check was satisfiable by editing `RULES` alone and never touching
`roster_text`. The banner must name an address for **every** peer, and the divergent
session's must be the Claude-side one.

### M2 — `post` and `inbox` become redirects

`cli_post` resolves `--to` against both name spaces and prints the exact call, then exits 2.
`--all` prints the same with a pointer to `ListAgents` — and see D6 in Missing Scope below:
the broadcast case has no one-to-one replacement and the redirect must say so rather than
pretend. `cli_inbox` says the same about the other direction and lists what the bus does
still record. `USAGE` keeps both under a "moved" heading for this release.

Verification: exits non-zero, `events.seq` unchanged, and the printed address is accepted by
a real `SendMessage`.

### M3 — The delivery channel narrows to machine facts

- **Split `note` before removing it (finding 2).** `cli_post`'s emit goes away with M2. The
  six machine emitters get kinds of their own — `churn`, `rename`, `own`, `disown`,
  `worker` — and all of them go into `DELIVERED_KINDS` alongside `wrong-port` and `serve`.
  Silencing them was r1's largest unintended removal: the rename notice is what keeps a
  peer's address current, and the ownership declaration is the whole reason `guard_file` can
  say the block did not wait for somebody to write the file first.
- `DELIVERED_KINDS` becomes `{"wrong-port", "serve", "steal", "churn", "rename", "own",
  "disown", "worker"}`. `note` leaves it because nothing emits `note` any more.
- `deliver()`'s header becomes `agent-bus — what changed under you while you were working:`.
- **A stolen lock becomes a delivered event, and the address must be the lock's.** The
  takeover branch of `do_claim` (`:2265`) emits `kind: "steal"` instead of `lock`, addressed
  with `to=lock.get("agent") or holder.get("agent")` — the lock's own agent, because a lock
  taken by a subagent is held by that subagent and `_lock_block` already gets this right for
  the same reason (`:5391-5394`). r1 said `holder["agent"]`, which would have told the
  parent and left the subagent that actually lost the lock uninformed.
- `interesting_to()` is unchanged, including that it tests `to` before kind (finding 9).
- `bin/ab-hook`'s `unread()` gate and its `post-batch` special case are unchanged.

Verification, rewritten after review: r1's check exercised `wrong-port`, which this
milestone does not touch — it measured nothing. Instead: with two live sessions, a rename,
an `own` declaration and a lock steal each arrive at the peer's next turn, and a `post`
attempt arrives nowhere.

### M4 — Every block message points at the tool, not at the CLI

Add an exit kind `tell`, rendered as a tool instruction rather than a command line, and use
it everywhere the code composes `agentbus post --to`. The real sites, corrected after review
(two of r1's six were comments, not code):

| site | what it composes |
|---|---|
| `_lock_block` exits (`:5430`) | ask the holder |
| `ownership_text` (`:2833`) | ask before taking a declared file |
| `ownership_verdict` note (`:2875`) | cross-worktree "I am also editing" |
| `interference_note` (`:4907`) | "your edit to X breaks my build" |
| `guard_file` (`:6135`, `:6183`) | ask before taking the file |
| `name_hint_once` (`:1875`) | **the subagent hint** — tells every subagent on this machine to sign with `agentbus post --as <name>`; after M2 that is a command that exits 2 |

`cli_serve` (`:9540`) and `render_refusal` (`:6039`) are comments describing history; they
are corrected, not re-pointed, and there is no detector to drop.

Every `tell` exit must carry the subagent form from M0 when the holder is one.

Verification, corrected: r1's gate (`grep "agentbus post" bin/agentbus` returns only the
redirect) is unsatisfiable — there are 18 hits, six of them prose and two of them `take`
advice that M6 removes later. The gate becomes: no **executable string literal** composes
`agentbus post`, checked by a small script rather than a bare grep, and it runs at the end
of M6. Plus a live block read by eye, because a wrong address here is the failure this plan
is most likely to ship.

### M5 — The block becomes a negotiation: queue, ask, release

D6's milestone. No new verb, no lease, no new state — the parts exist and one of them is
invisible.

**Gate zero, before anything is built.** Message an idle session, in each permission mode
this machine uses, with a bare `agentbus release db` line, and see whether the lock file
changes owner with no keystroke. The review confirmed sessions *wake* (127 arrivals, fifteen
after 45+ minutes of silence, all answered within 36 seconds) but found one recipient that
woke, worked, and then raised `AskUserQuestion` and waited three minutes for its human. What
is unproven is not the wake; it is whether a woken session **runs a peer-supplied command**.
In this repository `.claude/agent-bus.json` allowlists `Bash(agentbus:*)`, so it should. Ten
minutes of measurement decides whether the rest of this milestone is worth building.

**The change.** `locks_text` — what `status` and the banner print — gains the queue:

```
  db          orches (3m)  "reseeding personas"   queued: hotfix (2m)
```

Finding 8: this is rendered nowhere today, and the only place it was ever rendered is
deleted by M6. It is the whole milestone: a holder that can see somebody waiting can act
without being asked, and until now nothing woke a holder to look.

**The composed block.** The blocked agent gets an order of actions in which nothing waits on
a reply:

```
db is held by seeder/1 — a subagent of seeder. Took it 3m ago, "consuming fixtures".

  agentbus wait db --timeout 600     queue for it; takes it the moment it frees

Then tell them it is queued:  SendMessage → to "seeder"   (idle)
  "My session is queued for db — `agentbus status` shows me waiting. It is held by
   your subagent seeder/1. Please `agentbus release db` when its command is done;
   I need about ten minutes for one migration test."

If nothing comes back:  agentbus claim db --steal --why "..."   (their session is gone)
```

Asking is never blocking: the `wait` is what takes the lock, the message only shortens how
long it takes, and the agent is told to do other work meanwhile.

**The exits are reordered.** `wait` first, `tell` under it, `status` next, `steal` below
them all, `AGENTBUS_OFF` last. Today's order is `wait, status, ask, off, steal`
(`:5423-5545`) — r1 described it wrongly as having `off` last. `steal`'s blurb changes from
"only when you know they have finished" to "when their session is gone — otherwise ask;
they answer in seconds now".

**What is delivered.** Nothing new: `cli_wait` already emits its "waiting for 'db'" note
addressed to the holder, and finding 9 says an addressed event is delivered whatever its
kind. It gains the waiter's address so the holder can answer in one step.

Verification — two live sessions, none of it in the suite alone:

1. Gate zero above, first and alone. If a woken session will not run the line, M5 stops and
   Phase 2 gets the problem instead.
2. A is blocked on `db`; A queues, messages B, B releases; **A's `wait` takes the lock and
   the original command runs.** No human keystroke on either side.
3. The same when the holder is a **subagent**: the block names `seeder/1`, addresses
   `seeder`, and `seeder`'s release frees its subagent's lock.
4. `status` on B's side shows `queued: hotfix (2m)` before B is told anything — the holder
   can see the waiter without a message at all.
5. A holder that never answers: A's `wait` times out at the deadline, A is told, and the
   `steal` exit is what it is offered — the negotiation degrades to what exists today rather
   than hanging.

### M6 — Remove the ledger, `doing` and `handoff`

Delete: the whole task ledger (`TASKS`, `tasks_path`, `tasks_mutex`, `load_ledger`,
`save_ledger`, `next_task_id`, `find_task`, `task_files`, `ledger_view`, `sweep_tasks`,
`task_line`, `tasks_text`, `task_record`, `take_over`, `cli_take`, `cli_done`, `cli_doing`);
`handoff_text`, `did_something`, `bump_guarded`, `cli_handoff`, and the `handoff` emit in
`hook_session_end` (the `leave` event stays — presence is not messaging); `"doing"` from
`DECLARED_KEYS`, `roster_text`, `_lock_block`'s holder block, `board_state` and the board's
HTML/JS; kinds `task` and `handoff`.

Tests to delete or update, corrected after review: `tests/test_tasks.sh` and
`tests/test_handoff.sh` (delete); **`tests/test_messages.sh`** (deleted or rewritten around
the machine kinds — it tests the three delivery scopes end to end and r1 never mentioned
it); **`tests/test_parity.sh:640`** (finding 6 — it executes the `ask` exit as a shell
command and passes either way; it must assert the `tell` form is *not* executable);
`tests/board-render.js` (its task-rendering half becomes dead and its header names
`test_tasks.sh`); `tests/test_board.sh`, `test_ports.sh`, `test_landing.sh` (loaders).

**Sequencing (review, risk 1): M5 lands before M6.** M6 deletes the only existing renderer
of a lock queue; if M5 has not already added it to `locks_text`, the release that claims
"wait becomes worth using" is the same release that removes the last way to see a waiter.

D5 must be resolved before this milestone's gate can mean anything.

Verification: `make test` green **with the run time and skip count compared against the
previous run** — this repository's signature failure is a suite that goes green in two
minutes having measured nothing; `status` has no task section; the board renders with no
task pane; `merges` lists branches genuinely ahead of `main`, or both commands are gone.

### M7 — The bus records SendMessage traffic

- `hooks/hooks.posix.json` and `hooks/hooks.python.json` — **the sources; `hooks/hooks.json`
  is generated by `cli_install` (`:10554-10561`) and `tests/check_syntax.py` compares all
  three** — gain `SendMessage` in the `PreToolUse` matcher.
- `hook_pre_tool` emits a `msg` event for it and returns no decision. It never denies: a
  guard that can refuse a message is a guard that can wedge a conversation.
- `msg` is not in `DELIVERED_KINDS`, so it reaches `watch`, `board` and the `Recent:` block
  of `status` and nobody's context.
- `bin/ab-hook` and `bin/hook.py` both wake the engine for this tool, and
  `tests/test_pyhook.sh` plus `tests/test_matcher.py:310` assert the two fast paths agree.
  `acted()` gains a `SendMessage` case in both.
- **The solo gate is a real limit** (review, missing scope 7): `ab-hook` exits immediately
  when `live-count < 2`, and `hook_pre_tool` repeats the check (`:4766-4767`). A session
  messaging its own subagents while alone on the machine records nothing — which is most
  subagent traffic. Either the gate learns an exception for this tool or the plan states
  that `watch` shows peer traffic only. Decide in the milestone; do not discover it after.

Verification: with two live sessions, a `SendMessage` appears in `watch` within a second and
in no recipient's context; **and the same test with `live-count == 1`**, whose expected
result is whatever the gate decision above says it is.

### M8 — Documentation, version, doctor

- `README.md` and `SKILL.md`: the messaging sections become "talking to another session".
- `USAGE` loses `post`, `note`, `inbox`, `take`, `done`, `doing`, `handoff`;
  `.claude-plugin/plugin.json` and the marketplace manifest go to `3.0.0`, breaking, and the
  description stops claiming "messaging between agents".
- `CHANGELOG.md`: a 3.0.0 entry in this file's voice, with the corrected measurements.
- `agentbus doctor` gains four checks, not two: the registry is readable; this session has
  an address in it; the bus name and the Claude name agree (naming both when they do not);
  and the registry contains no `kind` or `status` value this build does not recognise, plus
  the count of entries whose `pid` is dead — because the stated risk is the registry's shape
  changing between versions and nothing else would detect that.
- `positional()` skips the value after `--why --to --timeout --as --note --needs`
  (`:6338-6346`); any new flag must be added there or its value is parsed as a positional.
- Downstream configs, both of them: `.claude/agent-bus.json` in the private product repository
  and in its sibling repository carry the `db` hint that
  says `agentbus post` before a reseed. That hint is a **broadcast** and has no one-to-one
  replacement (see Phase 2, item 6); until it does, it becomes "tell every session on this
  repo — `ListAgents`, then one `SendMessage` each".
- The memory files that teach the old behaviour are rewritten.

### M9 — Migration on the live machine

Hooks are read at session start, so a running session keeps the old RULES until it restarts.
Order, corrected after review (r1 had the announcement floating above the install):

1. Land M0–M8 on a branch; `make test` green with run time and skip count read.
2. **From a session on the old build, post the last legitimate bus message** — what is
   changing and that `post` will start refusing. This is the final use of the channel being
   removed, and it must happen before the install, because after it the verb refuses.
3. `agentbus install` (which regenerates `hooks/hooks.json` from the two sources).
4. Restart the sessions that matter; the rest roll over naturally, harmlessly, because M2's
   redirect fails loudly and says what to do instead.
5. Watch for a week, three counts: `msg` events against `post` redirect attempts; releases
   that followed a queue entry against steals; and `AGENTBUS_OFF` past a **held** resource —
   which requires the fix in Validation 10 before it can be counted at all.

Rollback: revert the range and re-run `agentbus install`. State under `~/.claude/agent-bus`
is forward-compatible — removed kinds simply stop being written.

## Phase 2 — the team protocol

Not scheduled. Every item is worth doing only if M5's gate zero holds. Written down because
it is the direction M5 opens, and a milestone list that hides its next step invites somebody
to build the wrong M5.

The through-line: **the guard stops being the thing that says no and becomes the thing that
introduces two sessions before they collide.**

1. **Speak before the collision.** The bus already knows from `acted/` and the queue that
   the reseed you are about to run belongs to a database another session is mid-Maestro
   against. A notice, not a block. A block avoided beats a block explained well.
2. **The interference guard gains a second half.** "This failure names files you did not
   edit" becomes that plus the owner, the address and the composed sentence.
3. **Leaving hands over to a person, not a log.** D4 removed the broadcast handoff. Its
   replacement is not machinery: a session finishing while another waits on what it holds
   should say so *while it can still speak*. RULES, not a hook — only the model knows what
   the work was.
4. **Escalate to the human only when the sessions cannot settle it.** The prize. Today every
   contended resource interrupts İbrahim; a team that negotiates surfaces one line and
   reserves the interruption for the answer that never came.
5. **The lease, reconsidered (D7).** `agentbus grant` with `mode: "hard"` (finding 3), one
   clock that `lock_state` and `sweep_locks` both honour (finding 4), a `may_grant` that
   requires being the holding party rather than in it (finding 5), the subagent addressing
   of finding 1, a refusal while an autoclaim names the resource, a `repo_key` check (a lock
   granted across repositories is invisible to the grantee), and a defined answer for each of
   the five paths that reach `release_all` — SessionEnd, the reaper, `forget`, `release
   --all`, and `release_all_for` on a stopped subagent.
6. **The broadcast that has no replacement.** `agentbus post` with no `--to` reached the
   repository and `--all` reached the machine; `SendMessage` addresses one session.
   "Reseeding — every id changes" is exactly the case the Purpose section names as *not*
   duplicated by Claude Code. Either D2's channel gains a `heads-up` kind the CLI can emit
   to everyone in the repo, or the answer is a documented loop over `ListAgents`. Decide
   before the private repository's hint is rewritten a second time.

Guard rails for all of it:

- **Asking is never blocking.** Queue first, message second, work meanwhile.
- **A wake costs model calls.** Never compose a message for something the reader cannot act
  on, and never twice for the same resource in one hold. `astray_again` is the pattern.
- **No agent may be woken into a loop.** `wait` and `steal` stay; a holder that does not
  answer inside the waiter's timeout is a holder you may take from.
- **Nothing is built on inference about another session's intent.** The bus reports what it
  recorded — a lock, a queue entry, a write log.

## Validation and Acceptance

Done means all of these hold on the live machine, not in the suite alone:

1. No executable string literal in `bin/` composes `agentbus post`, `take`, `done`,
   `handoff` or `doing`; the prose that mentions them is accurate history.
2. A real block prints an address a real `SendMessage` accepts, verified by sending one.
3. The divergent session (no chat title) is addressed correctly by its peers' blocks.
4. A **subagent-held** lock names the subagent and addresses the parent.
5. A rename, an ownership declaration and a lock steal each reach a peer's next turn.
6. `agentbus post --to X "..."` writes nothing and exits non-zero.
7. `agentbus watch` shows peer SendMessage traffic; the solo case behaves as M7 decided.
8. `make test` green, with run time and skip count compared against the previous run, and
   `test_messages.sh` and `test_parity.sh` explicitly accounted for rather than quietly
   passing.
9. One negotiation completes with no human keystroke on either side: blocked → queue →
   message → release → the blocked command runs.
10. In the week after, `AGENTBUS_OFF` past a **held** resource trends down. **This requires
    a code change to be measurable at all** (finding 7): the opt-out emit must carry the
    holder when there was one. Without it the number reads zero forever and the acceptance
    criterion is this repository's own signature false green.

## Risks

- **The registry is an internal file.** Not a documented interface; its shape can change
  between versions. Every read defensive, every field optional, failure mode "run
  `ListAgents`". `doctor` reports the observed version (2.1.261) and flags values it does
  not recognise.
- **The registry is not the whole world.** Remote Control peers are reachable and absent
  from it; the roster must not present itself as complete.
- **Permission mode (D8).** The negotiation asks a peer to run a command. Where
  `Bash(agentbus:*)` is not allowlisted the peer stops for its human and the premise fails
  quietly. Gate zero measures it; the roster cannot see it.
- **Cross-repository reachability** is assumed, not proven. `reply_across_default_dirs`
  appears on some sessions and not others; both messaged successfully in the sample. M0
  states what was observed rather than promising delivery.
- **The one-way door.** Once `post` stops delivering, an agent ignoring the redirect talks
  to itself. Hence the non-zero exit and M9's watch.
- **Politeness deadlock.** Two agents deferring, neither working. `wait` and `steal` stay,
  and the block never says asking is mandatory.
- **The queue is only as good as who reads it.** M5 puts the waiter on the holder's screen,
  but a holder deep in a long command sees it at its next turn. The `wait` timeout is what
  bounds that, and it is the waiter's to set.
