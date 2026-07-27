#!/usr/bin/env bash
# agent-bus installer for macOS / Linux (and Windows under Git Bash).
# Finds a Python and hands over to `agentbus install`, which does the real work
# so that both platforms make the same decisions in the same code. Safe to re-run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 &&
     "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
    exec "$cand" "$HERE/bin/agentbus" install "$@"
  fi
done

echo "agent-bus: no Python 3.8+ on PATH. Install Python, then re-run this." >&2
exit 1
