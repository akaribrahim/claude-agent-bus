#!/usr/bin/env python3
"""The address a block message hands the reader — is it one SendMessage takes?

This is the join between two registries written by two different programs: ours
under `~/.claude/agent-bus/sessions`, and Claude Code's under
`~/.claude/sessions`. Everything the new block messages say rests on it, and the
failure it exists to prevent is silent in the worst way — a message sent to a
name nobody answers to, by an agent that believes it has asked and is waiting.

The registry is somebody else's undocumented file format, so half of these
assertions are about malformed, stale and surprising input rather than the happy
path. The rule under all of them: no address is a fine answer, a wrong address
is not.
"""

import importlib.machinery
import importlib.util
import json
import os
import sys
import time

ROOT = os.environ.get("AB_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
TMP = os.environ.get("TEST_TMP") or "/tmp"

PASSES = os.path.join(TMP, ".passes")
FAILURES = os.path.join(TMP, ".failures")

REG = os.path.join(TMP, "cc-sessions")


def record(path, label):
    with open(path, "a") as fh:
        fh.write(label + "\n")


def ok(label):
    record(PASSES, label)
    if os.environ.get("VERBOSE"):
        print("    ok   %s" % label)


def bad(label, detail=""):
    record(FAILURES, label)
    print("    FAIL %s" % label)
    if detail:
        for line in str(detail).split("\n"):
            print("         %s" % line)


def eq(expected, actual, label):
    if expected == actual:
        ok(label)
    else:
        bad(label, "expected: %r\nactual:   %r" % (expected, actual))


def contains(haystack, needle, label):
    if needle in haystack:
        ok(label)
    else:
        bad(label, "expected to contain: %r\nactual: %r" % (needle, haystack))


def missing(haystack, needle, label):
    if needle not in haystack:
        ok(label)
    else:
        bad(label, "expected NOT to contain: %r\nactual: %r" % (needle, haystack))


def load_engine():
    loader = importlib.machinery.SourceFileLoader(
        "agentbus_engine", os.path.join(ROOT, "bin", "agentbus"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def write(filename, **fields):
    # Fresh unless a case says otherwise: a status is only evidence about now
    # while it is recent, and every fixture that does not care about that wants
    # to be talking about a session whose state was written a moment ago.
    fields.setdefault("statusUpdatedAt", int(time.time() * 1000))
    with open(os.path.join(REG, filename), "w") as fh:
        json.dump(fields, fh)


def main():
    os.makedirs(REG, exist_ok=True)
    # Set before the engine is imported: the path is read at module level, the
    # same way the live one is.
    os.environ["AGENTBUS_CC_SESSIONS"] = REG
    mod = load_engine()
    mine = os.getpid()          # a pid that is certainly alive
    dead = 4000000              # above every pid_max this runs on

    # ---- the happy path, and the one it exists for -------------------------
    write("100.json", pid=mine, sessionId="sid-match", name="orches",
          status="idle", kind="interactive",
          messagingSocketPath="/tmp/cc-socks/100.sock")
    write("101.json", pid=mine, sessionId="sid-diverge", name="product-86",
          status="busy", kind="interactive",
          messagingSocketPath="/tmp/cc-socks/101.sock")
    mod.cc_sessions(force=True)

    eq(("orches", "idle"), mod.address_of("sid-match"),
       "a session whose two names agree is addressed by that name")
    # The whole reason this module exists. The bus calls this session
    # `checkout-rewrite`; Claude Code calls it `product-86`; a
    # message to the first is a message to nobody.
    eq(("product-86", "busy"), mod.address_of("sid-diverge"),
       "a session whose names diverge is addressed by Claude Code's, not ours")

    # ---- when there is nothing honest to say -------------------------------
    eq((None, ""), mod.address_of("sid-unknown"),
       "a session with no registry entry has no address")
    write("102.json", pid=dead, sessionId="sid-dead", name="ghost",
          status="idle", kind="interactive")
    mod.cc_sessions(force=True)
    eq((None, ""), mod.address_of("sid-dead"),
       "a registry entry whose process has gone is not an address")

    # ---- two sessions, one name --------------------------------------------
    write("103.json", pid=mine, sessionId="sid-twin-a", name="ibrahim1",
          status="idle", kind="interactive",
          messagingSocketPath="/tmp/cc-socks/103.sock")
    write("104.json", pid=mine, sessionId="sid-twin-b", name="ibrahim1",
          status="busy", kind="interactive",
          messagingSocketPath="/tmp/cc-socks/104.sock")
    mod.cc_sessions(force=True)
    eq(("uds:/tmp/cc-socks/103.sock", "idle"), mod.address_of("sid-twin-a"),
       "a duplicated name falls back to the socket, which is unambiguous")
    write("105.json", pid=mine, sessionId="sid-twin-c", name="bare",
          status="idle", kind="interactive")
    write("106.json", pid=mine, sessionId="sid-twin-d", name="bare",
          status="idle", kind="interactive")
    mod.cc_sessions(force=True)
    eq((None, "idle"), mod.address_of("sid-twin-c"),
       "a duplicated name with no socket yields no address rather than a guess")

    # ---- input that is not what we expect ----------------------------------
    with open(os.path.join(REG, "107.json"), "w") as fh:
        fh.write("{this is not json")
    with open(os.path.join(REG, "108.json"), "w") as fh:
        fh.write("[]")
    write("109.json", pid=mine, name="no-session-id", status="idle")
    write("110.json", pid="not-an-int", sessionId="sid-badpid", name="odd")
    write("111.json", pid=mine, sessionId="sid-oddstatus", name="remote",
          status="hibernating", kind="remote-control")
    write("112.json", pid=mine, sessionId="sid-nostatus", name="quiet")
    reg = mod.cc_sessions(force=True)
    ok("a directory of malformed entries is read without raising")
    eq((None, ""), mod.address_of("sid-badpid"),
       "an entry whose pid is not a number is not an address")
    eq(("remote", "hibernating"), mod.address_of("sid-oddstatus"),
       "a status this build has never seen is passed through, not translated")
    eq(("quiet", ""), mod.address_of("sid-nostatus"),
       "an entry with no status is still addressable")

    # ---- joining on pid when the id has moved ------------------------------
    # The two records are written by different processes at different moments; a
    # resumed chat can carry an id we have not caught up with, but its pid is
    # the pid we recorded.
    other = os.getppid()        # alive, and not the pid every other fixture uses
    write("113.json", pid=other, sessionId="sid-renamed", name="resumed",
          status="idle", kind="interactive")
    mod.cc_sessions(force=True)
    eq(("resumed", "idle"), mod.address_of("sid-we-have-stale", other),
       "a session whose id we have stale is still found by its pid")
    # And the other direction, which is the one that could invent an identity:
    # `mine` is on half a dozen fixtures here, so it identifies nobody.
    eq((None, ""), mod.address_of("sid-we-have-stale", mine),
       "a pid several live entries claim identifies none of them")

    # ---- what the reader is actually shown ---------------------------------
    session = {"sid": "sid-match", "pid": mine, "agent": "orches"}
    line = mod.say_to(session)
    contains(line, 'SendMessage', "the line names the tool")
    contains(line, '"orches"', "the line carries the address")
    contains(line, "(idle)", "the line says whether anybody is at the keyboard")

    # 64 of the 87 blocks this plugin has recorded were held by a subagent, and
    # SendMessage cannot address one at all. The line must therefore address the
    # session and name the subagent, or it sends the reader to somebody who does
    # not know what they are being asked about.
    sub = mod.say_to(session, party="orches/2")
    contains(sub, '"orches"', "a subagent's holder is addressed through its session")
    contains(sub, "orches/2", "and the subagent is named in the message")

    none = mod.say_to({"sid": "sid-unknown", "pid": 0, "agent": "nobody"})
    contains(none, "ListAgents",
             "with no address, the reader is sent to the tool that has one")
    missing(none, "SendMessage",
            "and is not given a SendMessage call that cannot work")

    # ---- who is live that we do not know about -----------------------------
    strangers = mod.cc_strangers([{"sid": "sid-match"}, {"sid": "sid-diverge"}])
    names = sorted(r["name"] for r in strangers)
    contains(names, "ibrahim1",
             "a live session with no bus record is still reported as reachable")
    missing(names, "orches", "a session the bus already knows is not a stranger")
    missing(names, "ghost", "a dead session is not reachable")

    # ---- no registry at all -------------------------------------------------
    os.environ["AGENTBUS_CC_SESSIONS"] = os.path.join(TMP, "does-not-exist")
    gone = load_engine()
    eq({}, gone.cc_sessions(force=True),
       "a machine with no registry directory yields no addresses and no error")
    eq((None, ""), gone.address_of("sid-match"),
       "and no address for anybody")

    return 1 if os.path.exists(FAILURES) and os.path.getsize(FAILURES) else 0


if __name__ == "__main__":
    sys.exit(main())
