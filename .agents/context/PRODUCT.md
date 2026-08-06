# Product

<!-- impeccable:product-schema 1 -->

<!--
Written from a written brief, not from an interview. This session had no
structured-question tool and no decision page, so the init ask round could not
be run; every fact below is either quoted from the brief, read off the live
`GET /data` payload and `bin/agentbus`, or marked INFERRED. Nothing here is a
guess dressed as a confirmation.

This file is ours — written here, about this project. The vendored design skill
under `.agents/skills/` is gitignored; `.agents/context/` deliberately is not.
-->

## Platform

web

## Users

One developer, on one Mac, running five to nine Claude Code sessions at the same
time — across several git repositories and several worktrees of a single
repository. At the time this was written: nine sessions in five projects.

Their job while the board is open is not the coding. It is **routing**: knowing
which session is stuck, which two have edited the same file, and which branch is
ready to merge. In their words:

> "I can't follow the agents like this. I want the agents to talk among
> themselves while I watch, and step in from above to merge their work when
> needed. I lose track of what an agent last did."

They are currently the router between chats and they carry messages by hand.

## Product Purpose

`agentbus` is a coordination bus for concurrent coding agents on one machine:
presence, held resources, messages, declared work, and merge readiness. The
board (`agentbus board`) is its **one human surface**. Everything the board shows
is also available to the agents themselves through `agentbus status`; the board
exists because a person reading nine sessions needs a different shape than an
agent reading its own.

Success is the developer answering, at a glance, without opening a terminal:

1. Which agent is asking for me right now?
2. Who is about to collide with whom?
3. What is ready to land, and what would conflict if it did?
4. What did that agent last actually do?

## Positioning

The facts on this board are not reported by the agents. They are **observed**:
writes come from tool hooks, held resources from real locks, commits ahead of
trunk from git, collisions from comparing what two sessions actually wrote.
Declared intent (`tasks`) sits beside the observed work rather than standing in
for it, so an agent that says nothing still shows its branch, its files and its
clashes. A dashboard an agent could lie to would be worth less than none.

## Operating Context

- Glanced at, **often on a second monitor**, while the real work happens in
  terminal windows. It is a window that is left open for hours, not a page
  someone visits.
- Self-refreshing every two seconds. There is no interaction the reader must
  perform to keep it current.
- **Read-only, by contract.** A tab left open must not change the bus: no
  reaping, no cursor advance, no writes, `POST` refused.
- **Loopback-only, by contract.** The payload is every branch name, worktree
  path and message on the machine.
- **Self-contained, by contract.** No CDN, no external font, no remote anything;
  CSS, JS and SVG are inline. A dashboard that fetches a stylesheet tells that
  host when this person is working and from which repository, and stops
  rendering on a plane.
- The poll costs about 11 ms server-side. Anything added has to be paid for on
  the client, over the payload the server already sends.

## Capabilities and Constraints

What `GET /data` already carries, all of it real and none of it needing
invention.

Per session: `agent` (name), `branch`, `worktree` root, `repo_label`, `doing`,
`idle`, `guarded`, `owns`, `beat` (last heartbeat), subagents, `ahead` /
`ahead_of` (commits past the trunk), `wrote` / `wrote_n` (files written),
`clash` (files another live session also wrote, and whose), `unread`, and
`waiting` — idle **and** unread, the one state that is asking for the human
rather than to be watched.

Plus: `locks`, `serves` (declared shared services, held or free), `events`,
`repos`, `tasks` (declared work, its state, what it is blocked on, who is
waiting on it) and `landing` (branches ready to merge, and what would conflict).

Constraints on the page itself:

- Keyed, incremental DOM updates. The page used to rebuild its markup from
  strings every two seconds, which killed text selection and made animation
  impossible. No value may reach the page as markup — a branch name or a message
  must never arrive as HTML.
- Reduced motion is not optional. Open for hours; anything that pulses
  constantly is something a person turns off, or stops looking at.
- Python 3.8, bash 3.2. The page is a raw string inside `bin/agentbus`.

Terminology, as the product already uses it: *session* (one Claude Code chat),
*agent* (its name), *subagent*, *worktree*, *repo*, *task* (declared work),
*lock* / *held*, *serve* (a shared service), *clash*, *landing*, *waiting*.

## Brand Commitments

- The name is `agent-bus` / `agentbus`, lower case.
- Voice throughout this project — CLI output, comments, commit messages — is
  imperative, plain, unhyped sentences. No feature-marketing register.
- INFERRED, from the incumbent page and CLI: warm near-neutral ground rather
  than pure grey, a system sans, and monospace reserved for things that are
  literally paths, branches, ports and code. This is read off the code, not
  confirmed by the user.

## Evidence on Hand

- A live bus on the author's machine with nine sessions in five projects, held
  locks, an open task, and one landing candidate — enough to exercise every
  state the page has.
- `tests/board-render.js` executes the served script against served data in a
  minimal DOM and prints what a reader would see.
- The author's real projects must never be named in this repository, which is
  public. Any example, test fixture or screenshot caption uses invented neutral
  names. Do not fabricate the real ones back in.

## Product Principles

1. **Every mark encodes a fact.** Decoration that carries no information makes a
   dashboard worse. If a shape cannot name the field it is drawn from, it does
   not ship.
2. **Observed beats declared.** Show what the bus watched happen; let intent sit
   beside it, never replace it.
3. **Watching must not change what is watched.** Read-only is a design
   constraint, not only a server one — there is nothing on this page to press
   that spends anything.
4. **The exact fact stays one move away.** A worktree path is something a person
   copies. However the overview is drawn, the literal string must remain
   reachable and selectable.
5. **It has to survive being left open.** No constant motion, no state the
   reader loses on a poll, no cost that grows with how long the tab has been
   there.

## Accessibility & Inclusion

- `prefers-reduced-motion` must have a real alternative for everything that
  moves, not a disabled animation that leaves the state unreadable.
- `prefers-color-scheme` light and dark are both first-class; the page is on a
  second monitor in whatever light the room has.
- No fact may be encoded by colour alone.
