#!/usr/bin/env python3
"""
Megadesk hook script for Claude Code.
Reads hook event from stdin, writes session state to ~/.claude/megadesk/sessions/<session_id>.json
"""
import json
import os
import sys
import time
from pathlib import Path

SESSIONS_DIR = Path.home() / ".claude" / "megadesk" / "sessions"

# Mapping of hook events to states
EVENT_STATE_MAP = {
    "PreToolUse": "working",
    "PostToolUse": "working",
    "UserPromptSubmit": "working",
    "Stop": "waiting",
    "StopInterrupted": "waiting",
    "SessionStart": "working",
}


def main():
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return

        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return

    session_id = data.get("session_id", "")
    if not session_id:
        return

    hook_event = data.get("hook_event_name", "")
    # Notification events: don't change state
    if hook_event == "Notification":
        return

    new_state = EVENT_STATE_MAP.get(hook_event)
    if new_state is None:
        return

    # On Stop: if last_assistant_message starts with "interrupted", tag as StopInterrupted
    # so the widget can detect cancellations instantly without waiting for a timeout.
    if hook_event == "Stop":
        last_msg = data.get("last_assistant_message", "") or ""
        if last_msg.lstrip().lower().startswith("interrupted"):
            hook_event = "StopInterrupted"

    cwd = data.get("cwd", os.getcwd())
    tool_name = data.get("tool_name") or data.get("tool", "") or ""
    # ITERM_SESSION_ID is "w0t0p0:UUID" — iTerm2 AppleScript unique id is only the UUID part
    iterm_raw = os.environ.get("ITERM_SESSION_ID", "")
    iterm_session_id = iterm_raw.split(":", 1)[-1] if ":" in iterm_raw else iterm_raw
    # Inside tmux, all panes of the same iTerm2 tab share $ITERM_SESSION_ID.
    # Append the tmux pane ID so each pane gets its own card.
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if tmux_pane and iterm_session_id:
        iterm_session_id = f"{iterm_session_id}:{tmux_pane}"
    # If not running inside iTerm2, fall back to session_id so deduplication
    # doesn't collapse all sessions onto the same empty-string key.
    if not iterm_session_id:
        iterm_session_id = session_id

    session_file = SESSIONS_DIR / f"{session_id}.json"
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    now = time.time()

    # Read existing data to preserve state_since when state hasn't changed
    state_since = now
    if session_file.exists():
        try:
            existing = json.loads(session_file.read_text())
            if existing.get("state") == new_state:
                state_since = existing.get("state_since", now)
        except (json.JSONDecodeError, OSError):
            pass

    session_data = {
        "session_id": session_id,
        "cwd": cwd,
        "state": new_state,
        "state_since": state_since,
        "last_updated": now,
        "tool_name": tool_name,
        "last_event": hook_event,
        "iterm_session_id": iterm_session_id,
    }

    # On SessionStart, remove stale files from the same iTerm tab
    if hook_event == "SessionStart" and iterm_session_id:
        for old_file in SESSIONS_DIR.glob("*.json"):
            if old_file == session_file:
                continue
            try:
                old_data = json.loads(old_file.read_text())
                if old_data.get("iterm_session_id") == iterm_session_id:
                    old_file.unlink(missing_ok=True)
            except (json.JSONDecodeError, OSError):
                pass

    # Atomic write: write to .tmp then rename into place.
    # A rename within the same directory triggers NOTE_WRITE on the directory vnode,
    # which is what DispatchSource watches — plain write_text() on an existing file
    # only modifies the file vnode and the watcher never fires.
    tmp_file = session_file.with_suffix(".tmp")
    try:
        tmp_file.write_text(json.dumps(session_data, indent=2))
        tmp_file.rename(session_file)
    except OSError:
        try:
            tmp_file.unlink(missing_ok=True)
        except OSError:
            pass


if __name__ == "__main__":
    main()
