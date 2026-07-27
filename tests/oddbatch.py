#!/usr/bin/env python3
"""A PostToolBatch payload whose tool_response is not the usual string.

    oddbatch.py <session id> <cwd> <dict|list|null|number>

Hosts and tools do not all put the same thing there, and the first constraint on
this plugin is that a hook must never be the reason a session breaks. These are
the shapes that would raise if the code assumed one of them.
"""
import json
import sys

SHAPES = {"dict": {"stdout": "error: boom", "stderr": ""},
          "list": [{"type": "text", "text": "error: boom"}],
          "null": None,
          "number": 12}

sid, cwd, shape = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "session_id": sid, "cwd": cwd, "hook_event_name": "PostToolBatch",
    "tool_calls": [{"tool_name": "Bash",
                    "tool_input": {"command": "make build"},
                    "tool_response": SHAPES[shape]}]}))
