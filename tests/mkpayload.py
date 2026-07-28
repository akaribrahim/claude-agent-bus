#!/usr/bin/env python3
"""Build a Claude Code hook payload on stdout.

    mkpayload.py <kind> key=value [key=value …]

Shell quoting cannot be trusted to produce valid JSON around a command that
itself contains quotes, backslashes and newlines — which is precisely the kind
of command these tests need to feed the guard. So the payload is built by the
same JSON encoder that will read it back.

Kinds mirror the events in hooks/hooks.posix.json:

    session     SessionStart      sid, cwd, title
    batch       PostToolBatch     sid, cwd
    bash        PreToolUse/Bash   sid, cwd, cmd, id
    file        PreToolUse/Edit   sid, cwd, path, tool
    post-bash   PostToolUse/Bash  sid, cwd, id, stdout, stderr
    write       PostToolUse/Write sid, cwd, path
"""

import json
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: mkpayload.py <kind> [key=value …]", file=sys.stderr)
        return 1
    kind = sys.argv[1]
    kv = {}
    for arg in sys.argv[2:]:
        key, _, val = arg.partition("=")
        kv[key] = val

    d = {"session_id": kv.get("sid", ""), "cwd": kv.get("cwd", "")}

    if kind == "session":
        d["hook_event_name"] = "SessionStart"
        if kv.get("title"):
            d["session_title"] = kv["title"]
    elif kind == "session-end":
        d["hook_event_name"] = "SessionEnd"
        d["reason"] = kv.get("reason", "exit")
    elif kind == "subagent-start":
        d["hook_event_name"] = "SubagentStart"
    elif kind == "subagent-stop":
        d["hook_event_name"] = "SubagentStop"
    elif kind == "batch":
        d["hook_event_name"] = "PostToolBatch"
        # The real shape, taken from Claude Code 2.1.220: one entry per tool
        # call in the batch, each carrying the response whatever the outcome.
        # This is the only event that reports a command that failed.
        if kv.get("cmd") or kv.get("id") or kv.get("out"):
            call = {"tool_name": kv.get("tool", "Bash"),
                    "tool_input": {"command": kv.get("cmd", "")},
                    "tool_response": kv.get("out", "")}
            if kv.get("id"):
                call["tool_use_id"] = kv["id"]
            d["tool_calls"] = [call]
        # `pad` inflates the payload to a realistic size. What the shell fast
        # path costs depends almost entirely on how much of stdin it has to
        # slurp — `read -r -d ''` is a byte-at-a-time builtin loop — so a
        # measurement taken against a 200-byte payload cannot see the difference
        # between a gate that short-circuits and one that does not.
        if kv.get("pad"):
            d["padding"] = "x" * int(kv["pad"])
    elif kind == "bash":
        d["hook_event_name"] = "PreToolUse"
        d["tool_name"] = "Bash"
        d["tool_input"] = {"command": kv.get("cmd", "")}
        if kv.get("id"):
            d["tool_use_id"] = kv["id"]
    elif kind == "file":
        d["hook_event_name"] = "PreToolUse"
        d["tool_name"] = kv.get("tool", "Edit")
        d["tool_input"] = {"file_path": kv.get("path", "")}
    elif kind == "post-bash":
        d["hook_event_name"] = "PostToolUse"
        d["tool_name"] = "Bash"
        if kv.get("id"):
            d["tool_use_id"] = kv["id"]
        # `shape` covers what other hosts and other tools put here. A hook that
        # assumes the dict form and raises on the rest would take the session
        # down with it, so the odd shapes have to be exercised.
        shape = kv.get("shape", "dict")
        if shape == "dict":
            d["tool_response"] = {"stdout": kv.get("stdout", ""),
                                  "stderr": kv.get("stderr", ""),
                                  "interrupted": False, "isImage": False}
        elif shape == "string":
            d["tool_response"] = kv.get("stdout", "") + kv.get("stderr", "")
        elif shape == "list":
            d["tool_response"] = [{"type": "text",
                                   "text": kv.get("stdout", "")}]
        elif shape == "null":
            d["tool_response"] = None
        elif shape == "missing":
            pass
    elif kind == "write":
        d["hook_event_name"] = "PostToolUse"
        d["tool_name"] = kv.get("tool", "Write")
        d["tool_input"] = {"file_path": kv.get("path", "")}
    else:
        print("unknown payload kind: %s" % kind, file=sys.stderr)
        return 1

    # A subagent's hook payload carries these two and the parent's does not,
    # which is the only thing that tells them apart.
    if kv.get("agent_id"):
        d["agent_id"] = kv["agent_id"]
        d["agent_type"] = kv.get("agent_type", "general-purpose")

    print(json.dumps(d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
