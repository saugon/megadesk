#!/usr/bin/env python3
"""
Megadesk hook script for Kimi Code CLI.
Reads a lifecycle hook event from stdin (same JSON shape as Claude Code:
session_id, cwd, hook_event_name, tool_name, ...) and writes session state to
~/.claude/megadesk/sessions/<session_id>.json (the shared Megadesk directory).
Configured via [[hooks]] blocks in ~/.kimi/config.toml.
"""
import json
import os
import sys
import time
from pathlib import Path

SESSIONS_DIR = Path.home() / ".claude" / "megadesk" / "sessions"

EVENT_STATE_MAP = {
    "PreToolUse": "working",
    "PostToolUse": "working",
    "PostToolUseFailure": "working",
    "UserPromptSubmit": "working",
    "Stop": "waiting",
    "StopFailure": "waiting",
    "SessionStart": "waiting",
}


def _find_agent_pid() -> int:
    """Walk the process tree upward to find the 'kimi' ancestor PID."""
    import subprocess
    pid = os.getpid()
    for _ in range(6):
        try:
            out = subprocess.check_output(
                ["ps", "-p", str(pid), "-o", "ppid=,comm="],
                stderr=subprocess.DEVNULL, text=True,
            ).split(None, 1)
            ppid = int(out[0])
            comm = out[1].strip().rsplit("/", 1)[-1] if len(out) > 1 else ""
            if comm == "kimi":
                return pid
            if ppid <= 1:
                break
            pid = ppid
        except Exception:
            break
    return os.getppid()  # fallback


def _get_ghostty_terminal_id() -> str:
    """Query the focused Ghostty terminal's unique ID via AppleScript."""
    import subprocess
    try:
        return subprocess.check_output(
            ["osascript", "-e",
             'tell application "Ghostty" to get id of focused terminal of selected tab of front window'],
            stderr=subprocess.DEVNULL, text=True, timeout=3,
        ).strip()
    except Exception:
        return ""


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
    if hook_event == "Notification":
        return

    new_state = EVENT_STATE_MAP.get(hook_event)
    if new_state is None:
        return

    cwd = data.get("cwd", os.getcwd())
    tool_name = data.get("tool_name") or data.get("tool", "") or ""
    term_program = os.environ.get("TERM_PROGRAM", "").lower()

    # iTerm2 session ID: "w0t0p0:UUID" → extract UUID
    iterm_raw = os.environ.get("ITERM_SESSION_ID", "")
    terminal_session_id = iterm_raw.split(":", 1)[-1] if ":" in iterm_raw else iterm_raw
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if tmux_pane and terminal_session_id:
        terminal_session_id = f"{terminal_session_id}:{tmux_pane}"
    if not terminal_session_id:
        terminal_session_id = session_id

    if iterm_raw:
        terminal = "iterm2"
    elif term_program == "ghostty":
        terminal = "ghostty"
    else:
        terminal = "unknown"

    session_file = SESSIONS_DIR / f"{session_id}.json"
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    now = time.time()

    state_since = now
    created_at = now
    ghostty_terminal_id = ""
    if session_file.exists():
        try:
            existing = json.loads(session_file.read_text())
            if existing.get("state") == new_state:
                state_since = existing.get("state_since", now)
            created_at = existing.get("created_at", now)
            ghostty_terminal_id = existing.get("ghostty_terminal_id", "")
        except (json.JSONDecodeError, OSError):
            pass

    if terminal == "ghostty" and (hook_event == "SessionStart" or not ghostty_terminal_id):
        ghostty_terminal_id = _get_ghostty_terminal_id()

    session_data = {
        "session_id": session_id,
        "cwd": cwd,
        "state": new_state,
        "state_since": state_since,
        "created_at": created_at,
        "last_updated": now,
        "tool_name": tool_name,
        "last_event": hook_event,
        "terminal_session_id": terminal_session_id,
        "terminal": terminal,
        "claude_pid": _find_agent_pid(),
        "provider": "kimi",
        "ghostty_terminal_id": ghostty_terminal_id,
    }

    if hook_event == "SessionStart" and terminal_session_id:
        for old_file in SESSIONS_DIR.glob("*.json"):
            if old_file == session_file:
                continue
            try:
                old_data = json.loads(old_file.read_text())
                if old_data.get("terminal_session_id") == terminal_session_id:
                    old_file.unlink(missing_ok=True)
            except (json.JSONDecodeError, OSError):
                pass

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
