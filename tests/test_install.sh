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

run_installer() {   # <args…> → its output
  env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
    python3 "$AB_ROOT/bin/agentbus" install "$@" 2>&1
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
assert_equal "" "$(diff "$AB_ROOT/hooks/hooks.json" "$AB_ROOT/hooks/hooks.posix.json")" \
  "and it is the shell entry point, which needs nothing baked into it"

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
mkdir -p "$PLUGIN_COPY"
cp -R "$AB_ROOT/bin" "$AB_ROOT/hooks" "$PLUGIN_COPY/"
out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$PLUGIN_COPY/bin/agentbus" install 2>&1)
assert_contains "$out" "installed from a marketplace" \
  "an install under .claude/plugins is recognised"
assert_not_contains "$out" "move or re-clone" \
  "and is not told to move itself somewhere it would stop being loaded"

OTHER="$TEST_TMP/somewhere-else"
mkdir -p "$OTHER"
cp -R "$AB_ROOT/bin" "$AB_ROOT/hooks" "$OTHER/"
out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$OTHER/bin/agentbus" install 2>&1)
assert_contains "$out" "move or re-clone" \
  "while a clone in the wrong place still is"

# ---- doctor says whether the command can be run at all ----------------------

out=$(env HOME="$FAKE_HOME" PATH="$BARE_PATH" AGENTBUS_HOME="$AGENTBUS_HOME" \
  python3 "$AB_ROOT/bin/agentbus" doctor 2>&1)
assert_contains "$out" "command      : NOT on PATH" \
  "doctor reports a command that cannot be found"
out=$(env HOME="$FAKE_HOME" PATH="$FAKE_HOME/.local/bin:$BARE_PATH" \
  AGENTBUS_HOME="$AGENTBUS_HOME" python3 "$AB_ROOT/bin/agentbus" doctor 2>&1)
assert_contains "$out" "command      : $FAKE_HOME/.local/bin/agentbus" \
  "and reports where it is when it can"

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
