#!/usr/bin/env python3
"""
Megadesk hook script for Codex CLI.
Reads notify event from sys.argv[1] (JSON), writes session state to
~/.claude/megadesk/sessions/<thread_id>.json
"""
import json
import os
import sys
import time
from pathlib import Path

SESSIONS_DIR = Path.home() / ".claude" / "megadesk" / "sessions"

# Mapping of Codex notify event types to session states
EVENT_STATE_MAP = {
    "agent-turn-complete": "waiting",
    "approval-requested": "working",
}


def main():
    if len(sys.argv) < 2:
        return

    try:
        data = json.loads(sys.argv[1])
    except (json.JSONDecodeError, ValueError):
        return

    event_type = data.get("type", "")
    new_state = EVENT_STATE_MAP.get(event_type)
    if new_state is None:
        return

    session_id = data.get("thread-id", "")
    if not session_id:
        return

    cwd = data.get("cwd", os.getcwd())

    # Terminal session tracking — same logic as the Claude hook
    iterm_raw = os.environ.get("ITERM_SESSION_ID", "")
    terminal_session_id = iterm_raw.split(":", 1)[-1] if ":" in iterm_raw else iterm_raw
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if tmux_pane and terminal_session_id:
        terminal_session_id = f"{terminal_session_id}:{tmux_pane}"
    if not terminal_session_id:
        terminal_session_id = session_id

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
        "tool_name": "",
        "last_event": event_type,
        "terminal_session_id": terminal_session_id,
        "provider": "codex",
    }

    # On first event for a thread, remove stale files from the same terminal tab
    if terminal_session_id and not session_file.exists():
        for old_file in SESSIONS_DIR.glob("*.json"):
            if old_file == session_file:
                continue
            try:
                old_data = json.loads(old_file.read_text())
                if old_data.get("terminal_session_id") == terminal_session_id:
                    old_file.unlink(missing_ok=True)
            except (json.JSONDecodeError, OSError):
                pass

    # Atomic write via tmp + rename (triggers DispatchSource on macOS)
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
