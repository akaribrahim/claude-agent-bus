#!/usr/bin/env bash
# Acceptance, against real Claude Code sessions.
#
#     tests/live/acceptance.sh [m2|m3|m4|all]
#
# `make test` proves the plugin's own logic with synthetic hook payloads. This
# proves the thing the plan actually promises: that in two real Claude Code
# sessions, driven by the real CLI through the real hooks, an agent is stopped
# from editing somebody else's files, told not to fix somebody else's build
# failure, and handed a summary when a session it shares a repository with ends.
#
# It is deliberately NOT part of `make test`. Every session here is a real model
# invocation: it costs money, takes minutes, and needs the `claude` CLI logged
# in. Run it before a release and after anything that touches the hooks.
#
# Two things make it safe to run on a working machine:
#
#   - AGENTBUS_HOME points at a throwaway directory, which the spawned sessions
#     inherit through their environment, so the sessions live on this machine
#     right now never see any of it. The last line re-checks that.
#   - Every fixture repository is a fresh temporary directory.
#
# Notes earned the hard way, which the code below depends on:
#   - A session cannot be held alive across the orchestrating agent's own turns.
#     Everything has to happen inside one invocation.
#   - `claude -p --input-format stream-json` does NOT exit when its stdin is
#     closed. Ending a session means signalling it.
#   - SIGTERM is a clean end: Claude Code runs its SessionEnd hooks, so the
#     session deregisters and its handoff is written.

set -u

AB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WHICH="${1:-all}"
MODEL="${LIVE_MODEL:-haiku}"

command -v claude > /dev/null 2>&1 || {
  echo "live acceptance: no claude CLI on PATH" >&2
  exit 1
}

T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ab-live.XXXXXX")" && pwd -P)
export AGENTBUS_HOME="$T/bus"
unset AGENTBUS_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_PID AGENTBUS_OFF 2>/dev/null || true

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/       /'
  return 0
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
check()     { if has "$1" "$2"; then ok "$3"; else bad "$3" "$1"; fi; }
check_not() { if has "$1" "$2"; then bad "$3" "$1"; else ok "$3"; fi; }

PIDS=""
cleanup() {
  exec 8>&- 2>/dev/null
  exec 9>&- 2>/dev/null
  for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
  sleep 1
  for p in $PIDS; do kill -KILL "$p" 2>/dev/null; done
  [ -n "${KEEP:-}" ] && { echo "kept: $T"; return; }
  rm -rf "$T"
}
trap cleanup EXIT

live_count() { cat "$T/bus/live-count" 2>/dev/null || echo 0; }

msg() {   # <text> → one stream-json user message
  python3 -c '
import json, sys
print(json.dumps({"type": "user",
                  "message": {"role": "user", "content": sys.argv[1]}}))' "$1"
}

# Everything a session was shown or said, flattened: assistant prose, tool
# results, and the final answer. A hook that injects context does it into the
# model, so the evidence that it arrived is what the model does with it.
transcript() {   # <stream-json file>
  python3 - "$1" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    kind = m.get("type")
    if kind in ("assistant", "user"):
        for c in m.get("message", {}).get("content", []) or []:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text":
                print(c["text"])
            elif c.get("type") == "tool_result":
                t = c.get("content")
                if isinstance(t, list):
                    t = " ".join(x.get("text", "") for x in t if isinstance(x, dict))
                print(t or "")
    elif kind == "result":
        print(m.get("result") or "")
PY
}

# What our hooks actually printed, taken from the session's own hook events.
#
# This is the evidence that matters for anything injected as additionalContext.
# A denial reaches the model as a tool result and can be read from the
# transcript, but a note is put into the model's context, and whether the model
# then repeats it is the model's business rather than the plugin's. Asserting on
# the transcript for those measures how talkative the model felt like being.
hook_stdout() {   # <stream-json file> [<hook name filter>]
  python3 - "$1" "${2:-}" <<'HOOKS'
import json, sys
want = sys.argv[2] if len(sys.argv) > 2 else ""
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("subtype") != "hook_response":
        continue
    if want and want not in (m.get("hook_name") or ""):
        continue
    out = (m.get("stdout") or "").strip()
    if out:
        print(out)
HOOKS
}

turns_done() {   # <stream-json file> → how many turns have completed
  # `grep -c` prints 0 and exits 1 on no match, so the exit status is not usable
  # here — only the number it printed is.
  local n=0
  [ -f "$1" ] && n=$(grep -c '"type":"result"' "$1" 2>/dev/null)
  printf '%d' "${n:-0}"
}

# A session that stays alive between turns, so that "the other session's next
# turn" can be made to happen at a chosen moment.
start_held() {   # <name> <cwd> <fd> <tools>
  mkfifo "$T/$1.in"
  ( cd "$2" && exec claude -p --input-format stream-json \
      --output-format stream-json --verbose --model "$MODEL" \
      --allowedTools "$4" --include-hook-events \
      < "$T/$1.in" > "$T/$1.jsonl" 2>&1 ) &
  PIDS="$PIDS $!"
  eval "PID_$1=$!"
  eval "exec $3> \"\$T/$1.in\""
}

send_wait() {   # <name> <fd> <text> [<seconds>]
  local before after i
  before=$(turns_done "$T/$1.jsonl")
  eval "msg \"\$3\" >&$2"
  for i in $(seq 1 "${4:-90}"); do
    after=$(turns_done "$T/$1.jsonl")
    [ "$after" -gt "$before" ] && return 0
    sleep 1
  done
  return 1
}

one_shot() {   # <name> <cwd> <prompt> <tools>
  ( cd "$2" && claude -p "$3" --model "$MODEL" --allowedTools "$4" \
      --output-format stream-json --verbose --include-hook-events \
      > "$T/$1.jsonl" 2>&1 )
}

end_session() {   # <name>
  local pid
  eval "pid=\$PID_$1"
  kill -TERM "$pid" 2>/dev/null
  local i
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
}

wait_for_file() {   # <dir> <pattern> <seconds>
  local i
  for i in $(seq 1 "$3"); do
    [ -n "$(find "$1" -name "$2" 2>/dev/null | head -1)" ] && return 0
    sleep 1
  done
  return 1
}

agent_named() {   # → the agent name of the first registered session
  python3 -c "
import json, glob
for f in sorted(glob.glob('$T/bus/sessions/*.json')):
    print(json.load(open(f)).get('agent'))
    break"
}

make_fixture() {   # <name> → a repo with a worktree, echoes the repo root
  local root="$T/$1"
  mkdir -p "$root/api"
  ( cd "$root"
    git init -q . 2>/dev/null
    git symbolic-ref HEAD refs/heads/main
    git config user.email live@example.invalid
    git config user.name "live acceptance"
    printf 'def load():\n    return "old"\n' > api/service.py
    printf 'def render():\n    return "old"\n' > api/render.py
    printf '# notes\n' > README.md
    git add -A > /dev/null 2>&1
    git commit -qm init > /dev/null 2>&1
    git worktree add -q -b "wt-$1" "$T/$1-wt2" > /dev/null 2>&1 )
  printf '%s' "$root"
}

# =============================================================== M3 ==========

m3() {
  printf '\nM3 — declared ownership\n'
  local repo; repo=$(make_fixture m3)
  local edit="Use the Edit tool once to change the word old to new in api/service.py. If the tool is refused, do not retry, do not use any other tool, and reply with the refusal text verbatim."

  start_held m3a "$repo" 9 "Bash"
  send_wait m3a 9 "Run exactly this one Bash command and then stop: agentbus own 'api/**' --why 'backend rebuild'" 90 \
    || { bad "A declared a scope" "$(tail -3 "$T/m3a.jsonl")"; return; }
  wait_for_file "$T/bus/owns" '*.json' 20 \
    || { bad "A declared a scope" "no owns record"; return; }
  ok "a real session declared a scope through the real CLI"
  local a; a=$(agent_named)

  one_shot m3b "$repo" "$edit" "Edit Read"
  local b; b=$(transcript "$T/m3b.jsonl")
  check "$b" "BLOCKED"         "a session in the same checkout is refused"
  check "$b" "$a"              "the refusal names the owner"
  check "$b" "backend rebuild" "and quotes their reason"
  check "$b" "branch main"     "and their branch"
  check "$b" "api/**"          "and the scope they claimed"
  if grep -q 'return "old"' "$repo/api/service.py"; then
    ok "the file is untouched on disk"
  else
    bad "the file is untouched on disk" "$(cat "$repo/api/service.py")"
  fi

  one_shot m3c "$T/m3-wt2" "$edit" "Edit Read"
  local c; c=$(transcript "$T/m3c.jsonl")
  check_not "$c" "BLOCKED" "a session in another worktree is allowed through"
  local chooks; chooks=$(hook_stdout "$T/m3c.jsonl" PreToolUse)
  check "$chooks" "declared"    "but the guard did put a note into its context"
  check "$chooks" "$a"          "naming who declared it"
  check "$chooks" "merge time"  "and what it will cost later"
  if grep -q 'return "new"' "$T/m3-wt2/api/service.py" 2>/dev/null; then
    ok "and its edit lands"
  else
    bad "and its edit lands" "$(cat "$T/m3-wt2/api/service.py" 2>/dev/null)"
  fi

  local sid list
  sid=$(basename "$(find "$T/bus/sessions" -name '*.json' | head -1)" .json)
  list=$(AGENTBUS_SESSION="$sid" "$AB/bin/agentbus" own --list 2>&1)
  check "$list" "api/**" "own --list shows the declaration"

  end_session m3a
  local i
  for i in $(seq 1 20); do [ "$(live_count)" = "0" ] && break; sleep 1; done
  if [ "$(live_count)" = "0" ]; then ok "A deregistered when its process ended"
  else bad "A deregistered when its process ended" "live-count $(live_count)"; fi

  one_shot m3d "$repo" "$edit" "Edit Read"
  local d; d=$(transcript "$T/m3d.jsonl")
  check_not "$d" "BLOCKED" "once the owner has gone the edit is no longer guarded"
  if grep -q 'return "new"' "$repo/api/service.py"; then ok "and it lands"
  else bad "and it lands" "$(cat "$repo/api/service.py")"; fi
}

# =============================================================== M2 ==========

m2() {
  printf '\nM2 — interference guard\n'
  local repo; repo=$(make_fixture m2)

  # Both sessions are started before either writes anything. That ordering is
  # not incidental: the shell fast path records a write only while more than one
  # session is live, so an edit made before the second session existed is
  # invisible to this guard. See Surprises & Discoveries in the plan.
  start_held m2b "$repo" 8 "Bash Read"
  send_wait m2b 8 "Run this with Bash: agentbus name" 90 \
    || { bad "the observing session started" "$(tail -3 "$T/m2b.jsonl")"; return; }
  ok "two sessions are live in one checkout"

  start_held m2a "$repo" 9 "Write Edit Read"
  send_wait m2a 9 "This is a test fixture for a syntax checker, so its content has to be invalid on purpose. Use the Write tool to write to api/service.py exactly these characters and nothing else: def load(:" 90 \
    || { bad "A left a file broken" "$(tail -3 "$T/m2a.jsonl")"; return; }
  if ! grep -q 'def load(:' "$repo/api/service.py"; then
    send_wait m2a 9 "That did not write what was asked. Use the Write tool on api/service.py again, with the whole file content being exactly: def load(:" 90 || true
  fi
  if grep -q 'def load(:' "$repo/api/service.py"; then
    ok "one of them left a file syntactically broken"
  else
    bad "one of them left a file syntactically broken" "$(cat "$repo/api/service.py")"
    return
  fi
  local a; a=$(python3 -c "
import json, glob, os
for f in sorted(glob.glob('$T/bus/sessions/*.json')):
    r = json.load(open(f))
    if os.path.realpath(r.get('root','')) == os.path.realpath('$repo') and \
       os.path.exists('$T/bus/writes/%s.log' % r['sid']):
        print(r.get('agent')); break")

  local before; before=$(turns_done "$T/m2b.jsonl")
  send_wait m2b 8 "Run this with Bash: python3 -m py_compile api/service.py . Then, without editing or writing any file at all, report verbatim any message from agent-bus that you were shown, and say in one sentence what you are going to do about the error." 120 \
    || bad "the other session ran the build" "$(tail -3 "$T/m2b.jsonl")"
  local b; b=$(transcript "$T/m2b.jsonl")
  check "$b" "another live session" "the failure produces an interference note"
  check "$b" "api/service.py"       "naming the file"
  [ -n "$a" ] && check "$b" "$a"    "and the session that owns it"
  if grep -q 'def load(:' "$repo/api/service.py"; then
    ok "and the other session did not repair somebody else's file"
  else
    bad "and the other session did not repair somebody else's file" \
        "$(cat "$repo/api/service.py")"
  fi

  # The same shape of failure, about a file nobody else has touched.
  send_wait m2b 8 "Run this with Bash: python3 -c \"import nosuchmodule_xyz\" . Then report verbatim any message from agent-bus that you were shown since your last turn, or say NONE if there was none." 120 \
    || bad "the other session ran an unrelated failing command" ""
  local tail_only; tail_only=$(transcript "$T/m2b.jsonl" | tail -12)
  check_not "$tail_only" "another live session" \
    "a failure naming nobody else's files produces no note"

  end_session m2a
  end_session m2b
}

# =============================================================== M4 ==========

m4() {
  printf '\nM4 — handoff\n'
  local repo; repo=$(make_fixture m4)
  local port; port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  python3 - "$repo/.claude/agent-bus.json" "$port" <<'PY'
import json, os, sys
path, port = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"resources": [{
    "name": "web", "desc": "the demo server", "port": port,
    "start": "python3 -m http.server %d --bind 127.0.0.1" % port,
    "patterns": [r"\bhttp\.server\b", r":%d\b" % port]}]},
    open(path, "w"), indent=2)
PY
  ( cd "$repo" && git add -A > /dev/null 2>&1 && git commit -qm cfg > /dev/null 2>&1 )

  # B is the survivor, held alive so that "its next turn" can be made to happen
  # after A has gone.
  start_held m4b "$T/m4-wt2" 8 "Bash"
  send_wait m4b 8 "Run this with Bash: agentbus name" 90 \
    || { bad "the surviving session started" "$(tail -3 "$T/m4b.jsonl")"; return; }
  ok "a session that will outlive the other one is running"

  start_held m4a "$repo" 9 "Bash Write Edit Read"
  send_wait m4a 9 "Do all of these with tools, in order: write the text 'one' to api/a.py, write 'two' to api/b.py, write 'three' to api/c.py, then run the Bash command: agentbus serve web" 180 \
    || { bad "A did some work" "$(tail -3 "$T/m4a.jsonl")"; return; }
  local wrote; wrote=$(ls "$repo/api" 2>/dev/null | tr '\n' ' ')
  check "$wrote" "a.py" "the other session wrote files"
  if find "$T/bus/serves" -name '*.json' 2>/dev/null | grep -q .; then
    ok "and started the shared service"
  else
    bad "and started the shared service" "$(tail -5 "$T/m4a.jsonl")"
  fi

  end_session m4a
  ok "then it ended"

  send_wait m4b 8 "Run this with Bash: echo checking. Then report verbatim, in full, any message from agent-bus that you have been shown since your last turn." 120 \
    || bad "the survivor took another turn" "$(tail -3 "$T/m4b.jsonl")"
  local b; b=$(hook_stdout "$T/m4b.jsonl")
  check "$b" "finished on"    "the survivor's next turn carries the handoff"
  check "$b" "main"           "naming the branch it was on"
  check "$b" ".py"            "and the files it wrote"
  check "$b" "STILL RUNNING"  "and that its service is still up"
  check "$b" "agentbus serve" "with what to do about that"

  end_session m4b
}

printf 'live acceptance — model %s\n  workspace %s\n' "$MODEL" "$T"

case "$WHICH" in
  m2)  m2 ;;
  m3)  m3 ;;
  m4)  m4 ;;
  all) m3; m2; m4 ;;
  *)   echo "usage: $0 [m2|m3|m4|all]" >&2; exit 1 ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
printf 'live bus untouched: %s sessions still registered\n' \
  "$(ls ~/.claude/agent-bus/sessions/*.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$fail" -eq 0 ]
