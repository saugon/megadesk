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


def _find_codex_pid() -> int:
    """Walk the process tree upward to find the 'codex' ancestor PID."""
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
            if comm == "codex":
                return pid
            if ppid <= 1:
                break
            pid = ppid
        except Exception:
            break
    return os.getppid()  # fallback


def _is_untracked_thread(thread_id: str) -> bool:
    """True when the thread is not a session anyone sits at.

    Two kinds fire notify like a TUI session does:
    - `codex exec` runs, the non-interactive mode scripts and agents call. Each
      run is a new thread in whatever terminal launched it, so tracking them
      buries the board in cards for runs nobody can go back to. The rollout's
      first record names the originator.
    - Codex's own background threads, which the app-server starts next to a
      real one and never writes a rollout for.

    Thread ids are UUIDv7, so the id carries the day the rollout was filed
    under (local time); the neighbouring days cover a run around midnight.
    A missing rollout only counts when Codex does file rollouts in those
    folders, and anything unreadable counts as interactive: a card too many
    beats a session that never shows up.
    """
    from datetime import datetime, timedelta
    try:
        started = datetime.fromtimestamp(int(thread_id.replace("-", "")[:12], 16) / 1000)
    except ValueError:
        return False
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    folders = [
        codex_home / "sessions" / (started + timedelta(days=offset)).strftime("%Y/%m/%d")
        for offset in (0, -1, 1)
    ]
    for folder in folders:
        for rollout in folder.glob(f"rollout-*-{thread_id}.jsonl"):
            try:
                with rollout.open() as fh:
                    meta = json.loads(fh.readline()).get("payload", {})
            except (OSError, json.JSONDecodeError, AttributeError):
                return False
            return meta.get("originator") == "codex_exec" or meta.get("source") == "exec"
    return folders[0].is_dir()


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

    if _is_untracked_thread(session_id):
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

    term_program = os.environ.get("TERM_PROGRAM", "").lower()
    if iterm_raw:
        terminal = "iterm2"
    elif term_program == "ghostty":
        terminal = "ghostty"
    else:
        terminal = "unknown"

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
        "terminal": terminal,
        "claude_pid": _find_codex_pid(),
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
