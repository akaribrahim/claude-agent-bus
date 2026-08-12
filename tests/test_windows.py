#!/usr/bin/env python3
"""The Windows-only code paths, exercised on whatever platform is running this.

Everything in here is a branch guarded by `IS_WIN`, so a POSIX test run never
reaches any of it — which is how all of it shipped broken. Four defects were
measured on one Windows 10 machine on 2026-08-12 and not one of them could have
failed a test on the Mac this is developed on, because the code under them never
ran there. So these load the engine as a module, set `IS_WIN` by hand, and feed
the branches the exact bytes Windows gives them.

What that buys is narrow and worth being honest about: it holds the parsing and
the decisions, not the platform. `netstat` really printing those columns, and
`taskkill` really exiting 1 on a process it did kill, are facts recorded from
that machine and pinned here as fixtures. If Windows changes them, this file
goes on passing and the report comes back.

The engine has no `.py` extension, so it is loaded by path.
"""

import importlib.machinery
import importlib.util
import os
import shutil
import sys
import time

ROOT = os.environ.get("AB_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))
TMP = os.environ.get("TEST_TMP") or "/tmp"

PASSES = os.path.join(TMP, ".passes")
FAILURES = os.path.join(TMP, ".failures")


def record(path, label):
    with open(path, "a", encoding="utf-8") as fh:
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


def load_engine():
    path = os.path.join(ROOT, "bin", "agentbus")
    loader = importlib.machinery.SourceFileLoader("agentbus_engine", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


eng = load_engine()
eng.IS_WIN = True


class FakeRun(object):
    """Stands in for `subprocess.run` and remembers what it was asked to do.

    `port_pid` and `win_kill` both `import subprocess` inside the function, so
    the name they resolve is the one in `sys.modules` — patched here and put
    back at the end of each block."""

    def __init__(self, answers):
        self.answers = answers          # [(match_argv0, returncode, out, err)]
        self.calls = []

    def __call__(self, argv, **kw):
        self.calls.append(list(argv))
        for who, code, out, err in self.answers:
            if argv[0] == who:
                return type("R", (), {"returncode": code, "stdout": out,
                                      "stderr": err})()
        return type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})()


def with_run(fake, fn):
    import subprocess
    was = subprocess.run
    subprocess.run = fake
    try:
        return fn()
    finally:
        subprocess.run = was


# ---------------------------------------------------------------- port_pid ---
#
# Recorded from `netstat -ano -p TCP` on Windows 10. The rows that matter are
# the two on the same port: one listening, one an ordinary connection to it.

NETSTAT_EN = """
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1044
  TCP    0.0.0.0:9000           0.0.0.0:0              LISTENING       31416
  TCP    127.0.0.1:9000         127.0.0.1:54321        ESTABLISHED     8888
  TCP    [::]:9000              [::]:0                 LISTENING       31416
  TCP    0.0.0.0:19000          0.0.0.0:0              LISTENING       2222
"""

# The same machine with a Turkish display language. Only the State column is
# translated — the protocol name and the address shapes are not — and matching
# the English word in it is what made every declared service read as down.
NETSTAT_TR = """
Etkin Bağlantılar

  Proto  Yerel Adres            Yabancı Adres          Durum           PID
  TCP    0.0.0.0:9000           0.0.0.0:0              DİNLENİYOR      31416
  TCP    127.0.0.1:9000         127.0.0.1:54321        KURULDU         8888
"""


def probe(text, port):
    return with_run(FakeRun([("netstat", 0, text, "")]),
                    lambda: eng.port_pid(port))


eq(31416, probe(NETSTAT_EN, 9000), "the listening pid is read out of netstat")
eq(31416, probe(NETSTAT_TR, 9000),
   "and is still read when Windows translates the State column")
eq(2222, probe(NETSTAT_EN, 19000),
   "a longer port that ends in the one asked for is not confused with it")
eq(None, probe(NETSTAT_EN, 9999), "a port nothing is listening on answers None")
eq(None, probe("", 9000), "and so does netstat saying nothing at all")

# The connected row must never be mistaken for the listener: it is on the same
# port, and answering with ITS pid would attribute the service to whichever
# process last called it.
eq(31416, probe("""
  TCP    127.0.0.1:9000         127.0.0.1:54321        ESTABLISHED     8888
  TCP    0.0.0.0:9000           0.0.0.0:0              LISTENING       31416
""", 9000), "a connection to the port is not read as the thing serving it")

eq(None, probe("""
  TCP    127.0.0.1:9000         127.0.0.1:54321        ESTABLISHED     8888
""", 9000), "a port with only a connection on it and no listener is down")

eq(None, probe("  TCP    0.0.0.0:9000    0.0.0.0:0    LISTENING    not-a-pid\n",
               9000), "a row whose pid is not a number is skipped, not raised on")


# ---------------------------------------------------------------- win_kill ---
#
# `taskkill` exits 1 with "ERROR: Not found" on this machine both for a pid it
# did kill and for one it could not touch, so its exit status decides nothing.
# What decides is whether the process is still there afterwards.

TASKKILL_LIES = ("taskkill", 1, "", "ERROR: The process \"31416\" not found.")


def kill_with(lives, extra=()):
    """Run win_kill where each pid answers "alive" the given number of times.

    Per pid and not a single counter: the two pids in play are a service and the
    shell it was spawned from, and the whole question here is what happens to
    the second one after the first is dead."""
    left = dict(lives)

    def fake_alive(pid):
        n = left.get(int(pid), 0)
        if n <= 0:
            return False
        left[int(pid)] = n - 1
        return True

    was_alive, was_sleep = eng.pid_alive, time.sleep
    eng.pid_alive = fake_alive
    time.sleep = lambda _s: None       # the waits are real seconds otherwise
    fake = FakeRun([TASKKILL_LIES])
    try:
        tried = with_run(fake, lambda: eng.win_kill(31416, extra=extra))
    finally:
        eng.pid_alive, time.sleep = was_alive, was_sleep
    return tried, [c[0] for c in fake.calls]


tried, called = kill_with({31416: 1})
eq(["taskkill"], called,
   "taskkill alone is enough when the process is gone after it")
eq(1, len(tried), "and its lie about the exit status is still recorded")
ok("the diagnosis survives a kill that worked") if "not found" in tried[0] \
    else bad("the diagnosis survives a kill that worked", tried)

tried, called = kill_with({31416: 1000})
eq(["taskkill", "powershell"], called,
   "a process taskkill cannot touch escalates to Stop-Process")
ok("and what each of them said is carried back") if len(tried) == 1 \
    else bad("and what each of them said is carried back", tried)

# The escalation is the whole point of the second entry: a service is created
# with DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP, and Stop-Process was the only
# thing that ended one of those on the machine this was measured on.
tried, called = kill_with({31416: 1, 9904: 0}, extra=(9904,))
eq(["taskkill"], called,
   "a shell pid that has already exited is not signalled again")

# Both pids, because on Windows the recorded listener and the `cmd.exe` it was
# spawned from are two different processes, and killing the one the port names
# need not end the other.
_, called = kill_with({31416: 1, 9904: 1}, extra=(9904,))
eq(["taskkill", "taskkill"], called,
   "the shell it was spawned from is killed too when it outlives the service")


# ------------------------------------------------------------ stop_service ---
#
# The Windows branch used to be one taskkill, unwaited, unread and wrapped in
# `except Exception: pass`. The port re-check still caught the failure, so what
# the user was told stayed true — but every word of why was dropped at the one
# point it was known, and on a machine where taskkill lies about its exit status
# that is the only evidence there is.

os.makedirs(eng.SERVES, exist_ok=True)
eng.IS_WIN = True
WEB = {"name": "web", "port": 9000}


def stop_with(netstat, lives):
    eng.write_json(eng.serve_path("repo:1", "web"),
                   {"resource": "web", "repo": "repo:1", "root": "/tree",
                    "pid": 31416, "spawned": 9904, "port": 9000})
    left = dict(lives)

    def fake_alive(pid):
        n = left.get(int(pid), 0)
        if n <= 0:
            return False
        left[int(pid)] = n - 1
        return True

    was_alive, was_sleep = eng.pid_alive, time.sleep
    eng.pid_alive = fake_alive
    time.sleep = lambda _s: None
    fake = FakeRun([TASKKILL_LIES, ("netstat", 0, netstat, "")])
    try:
        return with_run(fake, lambda: eng.stop_service("repo:1", WEB))
    finally:
        eng.pid_alive, time.sleep = was_alive, was_sleep


stopped, why = stop_with(NETSTAT_EN, {31416: 10000, 9904: 10000})
eq(False, stopped, "a service that will not die is reported as not stopped")
ok("and the reason names what still holds the port") \
    if "31416 still holds the port" in why \
    else bad("and the reason names what still holds the port", why)
ok("and carries what taskkill said, which is the only evidence there is") \
    if "taskkill" in why and "not found" in why \
    else bad("and carries what taskkill said, which is the only evidence there "
             "is", why)

# Nothing listening any more: the record goes, and there is nothing to explain.
stopped, why = stop_with("", {31416: 2})
eq(True, stopped, "a service that does stop is reported as stopped")
eq("", why, "with no diagnosis attached, because there is nothing wrong")
eq(False, os.path.exists(eng.serve_path("repo:1", "web")),
   "and its record is gone")


# ------------------------------------------------------- hooks_look_wrong ----
#
# What `status` and `doctor` use to say a copy of this plugin cannot work here.
# The committed hooks.json names the shell fast path, so every fresh marketplace
# cache directory is exactly this case until the installer is re-run.

def wiring(text):
    d = os.path.join(TMP, "copy")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "hooks"))
    if text is not None:
        with open(os.path.join(d, "hooks", "hooks.json"), "w",
                  encoding="utf-8") as fh:
            fh.write(text)
    return eng.hooks_look_wrong(d)


with open(os.path.join(ROOT, "hooks", "hooks.json"), encoding="utf-8") as fh:
    committed = fh.read()

ok("the committed wiring is reported as unusable on Windows") \
    if "bash" in wiring(committed) \
    else bad("the committed wiring is reported as unusable on Windows",
             wiring(committed))
ok("a copy with no hooks.json at all says so") \
    if "no hooks.json" in wiring(None) \
    else bad("a copy with no hooks.json at all says so", wiring(None))
ok("an uninstalled python variant is caught by its placeholder") \
    if "__PYTHON__" in wiring('{"hooks": {"x": "__PYTHON__"}}') \
    else bad("an uninstalled python variant is caught by its placeholder")

eng.IS_WIN = False
eq("", wiring(committed),
   "while on a POSIX host that same wiring is what is supposed to be there")

sys.exit(0)
