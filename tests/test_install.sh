#!/usr/bin/env bash
# What a stranger gets, and what they are told when it is not enough.
#
# There are two ways in. Cloning into the skills directory and running the
# installer wires the hooks, puts `agentbus` on PATH and allowlists it.
# Installing from a marketplace wires the hooks and can do neither of the other
# two — nothing in a plugin install can put a command on somebody's PATH.
#
# That gap is the whole subject here, because every block this plugin writes
# ends in advice to run `agentbus something`. An install where the hooks fire
# and the command does not exist is worse than one that does nothing: the agent
# is told exactly what to do and then cannot do it.
#
# Everything below runs against a temporary HOME. The engine reads HOME at
# import, so a subprocess with HOME set writes its shim, its settings and its
# bus somewhere disposable, never into the real one.

. "$AB_ROOT/tests/lib.sh"

FAKE_HOME="$TEST_TMP/home"
mkdir -p "$FAKE_HOME"

# A PATH with no agentbus on it, which is what a marketplace install leaves.
BARE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# A copy of the plugin to install FROM, never the checkout this suite is running
# out of. `cli_install` derives its target from its own `__file__`, so pointing
# it at $AB_ROOT rewrites the developer's own hooks/hooks.json and deletes their
# bytecode cache — invisible on a host where the wiring it writes back is the
# committed one, and on Windows a checkout left holding the Python variant with
# `git status` reporting a modification nobody made. Reported from Windows 10 on
# 2026-08-12, where the suite then failed the assertion below against a file it
# had changed itself.
#
# At the blessed path, because that is where a reader is told to put it and the
# happy branch deserves exercising; the wrong-place branch has its own case
# further down.
SELF="$FAKE_HOME/.claude/skills/agent-bus"
mkdir -p "$SELF/.claude-plugin"
cp -R "$AB_ROOT/bin" "$AB_ROOT/hooks" "$SELF/"
cp "$AB_ROOT/.claude-plugin/plugin.json" "$SELF/.claude-plugin/"

run_installer() {   # <args…> → its output
  env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
    python3 "$SELF/bin/agentbus" install "$@" 2>&1
}

# ---- the hook wiring has to be in the repository, not generated -------------
#
# Claude Code reads the wiring from hooks/hooks.json and nothing in a plugin
# install generates it. When that file was git-ignored, installing from a
# marketplace produced a plugin that ran no hooks at all and said nothing about
# it — which is indistinguishable, from the outside, from a plugin that does not
# work.

assert_file "$AB_ROOT/hooks/hooks.json" "the hook wiring is present in the tree"
tracked=$(git -C "$AB_ROOT" ls-files --error-unmatch hooks/hooks.json 2>/dev/null)
assert_equal "hooks/hooks.json" "$tracked" "and it is committed, not ignored"
# Asked of what is committed, not of the working tree. A local install is
# entitled to rewrite the tree's copy — that is what it is for — and on a
# Windows checkout it does, to the Python variant. What must not drift is the
# file a stranger clones.
assert_equal "" "$(diff <(git -C "$AB_ROOT" show HEAD:hooks/hooks.json) \
                        <(git -C "$AB_ROOT" show HEAD:hooks/hooks.posix.json))" \
  "and what is committed is the shell entry point, which needs nothing baked in"

# ---- the installer does the two things a plugin install cannot --------------

out=$(run_installer)
assert_contains "$out" "permission: Bash(agentbus:*) allowlisted" \
  "the installer allowlists the command"
assert_file "$FAKE_HOME/.local/bin/agentbus" "and creates the command itself"
assert_contains "$(cat "$FAKE_HOME/.claude/settings.json")" "Bash(agentbus:*)" \
  "in the settings file it says it did"

out=$(run_installer)
assert_contains "$out" "already allowlisted" "and is safe to run twice"

# ---- it no longer tells a marketplace install to move itself ----------------
#
# Claude Code loads a marketplace install from exactly where it put it. The
# installer used to say "move or re-clone it there", which would have broken the
# thing the reader had just installed.

PLUGIN_COPY="$FAKE_HOME/.claude/plugins/cache/agent-bus/agent-bus/1.0.0"
mkdir -p "$PLUGIN_COPY/.claude-plugin"
cp -R "$AB_ROOT/bin" "$AB_ROOT/hooks" "$PLUGIN_COPY/"
cp "$AB_ROOT/.claude-plugin/plugin.json" "$PLUGIN_COPY/.claude-plugin/"
out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$PLUGIN_COPY/bin/agentbus" install 2>&1)
assert_contains "$out" "the copy Claude Code loads" \
  "an install under plugins/cache knows it is the one that is loaded"
assert_not_contains "$out" "move or re-clone" \
  "and is not told to move itself somewhere it would stop being loaded"

# ---- and the clone it was fetched from patches the copy that is loaded -------
#
# A marketplace install leaves two directories: the clone it fetched, under
# plugins/marketplaces, and the copy under plugins/cache that Claude Code
# actually reads. The installer derived its target from its own __file__, so
# run from the clone it patched the clone and said "Claude Code loads it from
# here" — confidently, and wrongly. On Windows the cache copy was then left
# holding the committed POSIX wiring, which means `bash -> ab-hook -> python3`
# against a stub that is not Python: every hook died, no session registered,
# and both the installer and `doctor` reported success because each was
# describing the copy it had just touched. Reported from Windows 10 on
# 2026-07-30, and again on the next version bump, because the cache path
# carries the version.

CLONE="$FAKE_HOME/.claude/plugins/marketplaces/agent-bus"
mkdir -p "$CLONE/.claude-plugin"
cp -R "$AB_ROOT/bin" "$AB_ROOT/hooks" "$CLONE/"
cp "$AB_ROOT/.claude-plugin/plugin.json" "$CLONE/.claude-plugin/"
# Put the cache copy back the way a fresh install leaves it: the committed
# POSIX wiring, which is what has to be replaced.
cp "$AB_ROOT/hooks/hooks.posix.json" "$PLUGIN_COPY/hooks/hooks.json"

out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$CLONE/bin/agentbus" install --python-hooks 2>&1)
assert_contains "$out" "the marketplace clone" \
  "the clone knows it is not the copy that gets loaded"
assert_not_contains "$out" "loads it from here" \
  "and no longer claims otherwise"
assert_contains "$out" "also wired" "it says it reached the other copy"
assert_not_contains "$(cat "$PLUGIN_COPY/hooks/hooks.json")" "ab-hook" \
  "and the copy Claude Code loads really was rewired"
assert_not_contains "$(cat "$PLUGIN_COPY/hooks/hooks.json")" "__PYTHON__" \
  "with a real interpreter path, not the placeholder"

# And the command it leaves on PATH must not call the clone either. That
# directory is the one `claude plugin update` resets, so a shim into it is a
# command that stops working because of an update it had no part in — while the
# cache copy beside it is both loaded and versioned.
assert_equal "$PLUGIN_COPY/bin/agentbus" \
  "$(readlink "$FAKE_HOME/.local/bin/agentbus")" \
  "and the command on PATH calls the loaded copy, not the clone it ran from"

# doctor has to be able to see this too: reporting only the copy it is running
# from is what made a dead install look healthy.
cp "$AB_ROOT/hooks/hooks.python.json" "$PLUGIN_COPY/hooks/hooks.json"
out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$CLONE/bin/agentbus" doctor 2>&1)
assert_contains "$out" "never installed" \
  "doctor names a loaded copy still holding the __PYTHON__ placeholder"
assert_contains "$out" "Claude Code loads this one" "and says why it matters"

OTHER="$TEST_TMP/somewhere-else"
mkdir -p "$OTHER"
cp -R "$AB_ROOT/bin" "$AB_ROOT/hooks" "$OTHER/"
out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$OTHER/bin/agentbus" install 2>&1)
assert_contains "$out" "move or re-clone" \
  "while a clone in the wrong place still is"

# ---- doctor says whether the command can be run at all ----------------------

out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$SELF/bin/agentbus" doctor 2>&1)
assert_contains "$out" "command      : NOT on PATH" \
  "doctor reports a command that cannot be found"
out=$(env HOME="$FAKE_HOME" PATH="$FAKE_HOME/.local/bin:$BARE_PATH" \
  AGENTBUS_HOME="$AGENTBUS_HOME" python3 "$SELF/bin/agentbus" doctor 2>&1)
assert_contains "$out" "command      : $FAKE_HOME/.local/bin/agentbus" \
  "and reports where it is when it can"

# ---- and whether the engine's bytecode is cached ----------------------------
#
# Both fast paths reach the engine by importing it so that Python caches the
# compiled form: it is 26 ms of a 54 ms wake here and 115 ms of 313 ms on the
# Windows work machine this was measured on. A plugin directory that cannot be
# written to gets no cache — Python swallows the failed write, the engine runs
# exactly as it would otherwise, and the saving is gone for the life of the
# install with nothing anywhere saying so. Hence a line, and hence these two.
rm -rf "$SELF/bin/__pycache__"
out=$(env HOME="$FAKE_HOME" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$SELF/bin/agentbus" doctor 2>&1)
assert_contains "$out" "bytecode     : NOT cached" \
  "doctor says so when no wake has cached the engine's bytecode"
# Woken through the entry point both fast paths use, on the one event that is
# certain to touch nothing: a finished command whose id nothing claimed. It has to
# leave the bus exactly as it found it — the assertions below this need one live
# session and no more.
printf '%s' "$(payload post-bash sid=inst-cache cwd=/tmp id=nothing)" \
  | env AGENTBUS_HOME="$AGENTBUS_HOME" python3 "$SELF/bin/hook.py" \
      wake post-bash > /dev/null 2>&1
out=$(env HOME="$FAKE_HOME" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$SELF/bin/agentbus" doctor 2>&1)
assert_not_contains "$out" "NOT cached" \
  "and stops saying it once a wake has written one"

# And the case nobody would otherwise find: a plugin directory that cannot be
# written to. Python swallows the failed cache write, so the engine loads and runs
# exactly as it would otherwise and the only symptom is the recompile — on every
# woken hook, for the life of the install. `doctor` is the one place it shows.
LOCKED="$TEST_TMP/locked-plugin"
mkdir -p "$LOCKED/bin"
cp "$AB_ROOT/bin/agentbus" "$AB_ROOT/bin/hook.py" "$LOCKED/bin/"
chmod +x "$LOCKED/bin/agentbus" "$LOCKED/bin/hook.py"
chmod a-w "$LOCKED/bin"
# The precondition, asserted rather than assumed: root can write to a directory
# with no write bits, and the assertion below would then be passing against a
# directory that was writable all along.
if [ -w "$LOCKED/bin" ]; then
  _bad "the fixture really did take the write bit off a plugin directory" \
    "still writable as $(id -un)"
else
  _ok "the fixture really did take the write bit off a plugin directory"
  printf '%s' "$(payload post-bash sid=inst-locked cwd=/tmp id=nothing)" \
    | env AGENTBUS_HOME="$AGENTBUS_HOME" python3 "$LOCKED/bin/hook.py" \
        wake post-bash > /dev/null 2>&1
  out=$(env HOME="$FAKE_HOME" AGENTBUS_HOME="$AGENTBUS_HOME" \
    python3 "$LOCKED/bin/agentbus" doctor 2>&1)
  assert_contains "$out" "NOT cached (this directory is not writable)" \
    "and names an unwritable directory as the reason, rather than leaving it invisible"
fi
chmod u+w "$LOCKED/bin"

# ---- the session is told, once, and only when it matters -------------------

REPO=$(make_repo instrepo)
commit_all "$REPO"

start_with_path() {   # <session id> <PATH> → the hook's stdout
  local sid="$1" p="$2"
  printf '%s' "$(payload session "sid=$sid" "cwd=$REPO")" \
    | env PATH="$p" AGENTBUS_HOME="$AGENTBUS_HOME" HOME="$FAKE_HOME" \
        bash "$AB_ROOT/bin/ab-hook" session-start
}

# Each of these has to be the only session on the bus: what is being asserted is
# the silence of a solo session, and a second live one would put a roster in
# front of it and hide the thing under test.
out=$(start_with_path sess-nocli "$BARE_PATH")
ctx=$(json_field "$out" hookSpecificOutput additionalContext)
assert_contains "$ctx" "not on PATH" \
  "a session whose CLI is missing is told so, even when it is alone"
assert_contains "$ctx" "install" "and given the one command that fixes it"
end_session sess-nocli

out=$(start_with_path sess-nocli2 "$BARE_PATH")
assert_empty "$out" "and never told twice — the notice is once per machine"
end_session sess-nocli2

# The silence of a solo session is a property worth keeping: it is the whole
# reason the plugin costs nothing when nobody else is working.
rm -f "$AGENTBUS_HOME/.cli-notice"
out=$(start_with_path sess-withcli "$FAKE_HOME/.local/bin:$BARE_PATH")
assert_empty "$out" "a solo session with a working command is told nothing at all"
assert_file "$AGENTBUS_HOME/.cli-notice" "and the question is not asked again"
end_session sess-withcli

finish
