#!/usr/bin/env python3
"""Persist Codex session lifecycles without storing prompts or tool payloads."""
import fcntl
import json
import os
import sys
import tempfile
import time

event = os.environ.get("CODEX_HOOK_EVENT", "")
payload = {}
try:
    payload = json.load(sys.stdin)
    event = payload.get("hook_event_name") or payload.get("event") or event
except Exception:
    pass

state = {
    "SessionStart": "running",
    "UserPromptSubmit": "running",
    "PreToolUse": "running",
    "PermissionRequest": "waiting",
    "Stop": "completed",
    "PostToolUseFailure": "failed",
}.get(event)
if not state:
    sys.exit(0)

session_id = next(
    (
        value
        for key in ("session_id", "thread_id", "threadId", "conversation_id")
        if isinstance((value := payload.get(key)), str) and value
    ),
    "global",
)
directory = os.path.expanduser("~/.codex-bar")
os.makedirs(directory, exist_ok=True)
target = os.path.join(directory, "session-status.json")
lock_path = os.path.join(directory, "session-status.lock")

with open(lock_path, "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        with open(target) as handle:
            previous = json.load(handle)
    except (OSError, json.JSONDecodeError):
        previous = {}

    now = int(time.time())
    sessions = previous.get("sessions") if isinstance(previous.get("sessions"), dict) else {}
    sessions[session_id] = {"state": state, "updated_at": now}
    sessions = {
        key: value
        for key, value in sessions.items()
        if isinstance(value, dict) and now - value.get("updated_at", 0) <= 3600
    }
    active = [value for value in sessions.values() if value.get("state") == "running"]
    waiting = [value for value in sessions.values() if value.get("state") == "waiting"]
    latest = max(sessions.values(), key=lambda value: value.get("updated_at", 0), default={"state": "completed"})
    aggregate = "running" if active else "waiting" if waiting else latest.get("state", "completed")

    fd, temporary = tempfile.mkstemp(dir=directory)
    with os.fdopen(fd, "w") as handle:
        json.dump({"state": aggregate, "updated_at": now, "sessions": sessions}, handle)
    os.replace(temporary, target)
    fcntl.flock(lock, fcntl.LOCK_UN)
