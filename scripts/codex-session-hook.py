#!/usr/bin/env python3
"""Persist only the latest Codex hook state; never store prompt or output text."""
import json, os, sys, tempfile, time

event = os.environ.get("CODEX_HOOK_EVENT", "")
try:
    payload = json.load(sys.stdin)
    event = payload.get("hook_event_name") or payload.get("event") or event
except Exception:
    pass

state = {
    "SessionStart": "running", "UserPromptSubmit": "running", "PreToolUse": "running",
    "PermissionRequest": "waiting", "Stop": "completed", "PostToolUseFailure": "failed",
}.get(event)
if not state:
    sys.exit(0)

directory = os.path.expanduser("~/.codex-bar")
os.makedirs(directory, exist_ok=True)
target = os.path.join(directory, "session-status.json")
fd, temporary = tempfile.mkstemp(dir=directory)
with os.fdopen(fd, "w") as handle:
    json.dump({"state": state, "updated_at": int(time.time())}, handle)
os.replace(temporary, target)
