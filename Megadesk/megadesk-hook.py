#!/usr/bin/env python3
"""
Megadesk hook script for Claude Code.
Reads hook event from stdin, writes session state to ~/.claude/megadesk/sessions/<session_id>.json
"""
import json
import os
import re
import sys
import time
from pathlib import Path

SESSIONS_DIR = Path.home() / ".claude" / "megadesk" / "sessions"

EVENT_STATE_MAP = {
    "PreToolUse": "working",
    "PostToolUse": "working",
    "UserPromptSubmit": "working",
    "Stop": "waiting",
    "StopInterrupted": "waiting",
    "SessionStart": "waiting",
}


def _find_claude_pid() -> int:
    """Walk the process tree upward to find the 'claude' ancestor PID."""
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
            if comm == "claude":
                return pid
            if ppid <= 1:
                break
            pid = ppid
        except Exception:
            break
    return os.getppid()  # fallback


def _tty_of(pid: int) -> str:
    """The device path of the process's controlling terminal, or empty."""
    import subprocess
    try:
        tty = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "tty="],
            stderr=subprocess.DEVNULL, text=True, timeout=2,
        ).strip()
    except Exception:
        return ""
    return f"/dev/{tty}" if tty and tty != "??" else ""


def _ghostty_terminals() -> list:
    """(id, title, working directory) for every Ghostty terminal."""
    import subprocess
    # One bulk request per property: walking windows, tabs and terminals one
    # Apple event at a time takes over a second with a few dozen terminals.
    # Tab-separated because a path may contain a comma, and assembled outside
    # the tell block, where Ghostty's own `tab` class shadows the constant.
    script = (
        'set sep to ASCII character 9\n'
        'tell application "Ghostty"\n'
        '  set ids to id of every terminal\n'
        '  set titles to name of every terminal\n'
        '  set dirs to working directory of every terminal\n'
        'end tell\n'
        'set out to ""\n'
        'repeat with i from 1 to count of ids\n'
        '  set out to out & item i of ids & sep & item i of titles & sep & item i of dirs & linefeed\n'
        'end repeat\n'
        'return out'
    )
    try:
        listing = subprocess.check_output(
            ["osascript", "-e", script],
            stderr=subprocess.DEVNULL, text=True, timeout=3,
        )
    except Exception:
        return []
    terminals = []
    for line in listing.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0]:
            terminals.append((parts[0], "\t".join(parts[1:-1]), parts[-1]))
    return terminals


def _set_title(tty: str, title: str) -> None:
    fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        os.write(fd, f"\033]2;{title}\007".encode())
    finally:
        os.close(fd)


def _get_ghostty_terminal_id(cwd: str, tty: str) -> tuple:
    """The ID of the Ghostty terminal this session runs in, and whether the
    terminal itself was asked (as opposed to guessed).

    AppleScript can't tell which terminal owns a tty, and guessing by working
    directory fails exactly when it matters: several tabs open in the same
    repo. A stolen ID is worse than no ID: it aims the card at someone else's
    tab and links the two cards' custom names. So the session's own terminal
    is asked: a unique title is written to its tty (an OSC sequence, which the
    terminal consumes and the program never sees), the terminal showing that
    title is the one, and its previous title is put back right away.

    Without a tty to write to (a daemon-dispatched event, or tmux, which keeps
    titles to itself) only an unambiguous guess counts: the single terminal
    sitting in this directory.
    """
    terminals = _ghostty_terminals()
    if not terminals:
        return "", False

    if tty:
        marker = f"megadesk-{os.getpid()}-{int(time.time() * 1000)}"
        titles = {term_id: title for term_id, title, _ in terminals}
        try:
            _set_title(tty, marker)
        except OSError:
            pass
        else:
            found = ""
            for _ in range(6):
                time.sleep(0.1)
                found = next((t for t, title, _ in _ghostty_terminals() if title == marker), "")
                if found:
                    break
            try:
                # Unseen marker: no way to know which title to restore, and an
                # empty one beats leaving the marker on the tab.
                _set_title(tty, titles.get(found, ""))
            except OSError:
                pass
            if found:
                return found, True

    want = (cwd or "").rstrip("/")
    matches = [t for t, _, term_cwd in terminals if want and term_cwd.rstrip("/") == want]
    return (matches[0] if len(matches) == 1 else ""), bool(tty)


def _project_dir(cwd: str, transcript_path: str) -> str:
    """The directory the session was started in, which names its card.

    `cwd` follows every `cd` the agent runs, so naming the card after it makes
    the card rename itself as the session moves around the repo. Claude files
    the transcript under a folder named after the starting directory (every
    non-alphanumeric character turned into a dash), so the ancestor of `cwd`
    whose path maps to that folder name is where the session began. Anything
    that doesn't map cleanly (a truncated slug, a `cd` outside the project)
    falls back to `cwd`.
    """
    slug = Path(transcript_path).parent.name if transcript_path else ""
    if slug and cwd:
        path = Path(cwd)
        for candidate in (path, *path.parents):
            if re.sub(r"[^A-Za-z0-9]", "-", str(candidate)) == slug:
                return str(candidate)
    return cwd


def main():
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return

        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return

    # `claude -p` and the Agent SDK are not sessions anyone sits at: they are
    # usually spawned by a script or an agent running inside a real session,
    # and they inherit that session's terminal environment. Tracking them puts
    # an extra card on the parent's tab for every run.
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk"):
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
    permission_mode = data.get("permission_mode")  # present on tool/loop events only
    term_program = os.environ.get("TERM_PROGRAM", "").lower()

    # iTerm2 session ID: "w0t0p0:UUID" → extract UUID
    iterm_raw = os.environ.get("ITERM_SESSION_ID", "")
    terminal_session_id = iterm_raw.split(":", 1)[-1] if ":" in iterm_raw else iterm_raw
    # Inside tmux, all panes of the same iTerm2 tab share $ITERM_SESSION_ID.
    # Append the tmux pane ID so each pane gets its own card.
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if tmux_pane and terminal_session_id:
        terminal_session_id = f"{terminal_session_id}:{tmux_pane}"
    # If not running inside iTerm2, fall back to session_id so deduplication
    # doesn't collapse all sessions onto the same empty-string key.
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

    # Read existing data to preserve state_since, created_at, project_dir and
    # ghostty_terminal_id across writes
    state_since = now
    created_at = now
    ghostty_terminal_id = ""
    ghostty_checked = False
    project_dir = ""
    if session_file.exists():
        try:
            existing = json.loads(session_file.read_text())
            if existing.get("state") == new_state:
                state_since = existing.get("state_since", now)
            created_at = existing.get("created_at", now)
            ghostty_terminal_id = existing.get("ghostty_terminal_id", "")
            ghostty_checked = existing.get("ghostty_terminal_checked", False)
            project_dir = existing.get("project_dir", "")
            # permission_mode isn't sent on every event (e.g. SessionStart) —
            # keep the last known value so the UI doesn't lose it.
            if permission_mode is None:
                permission_mode = existing.get("permission_mode")
        except (json.JSONDecodeError, OSError):
            pass

    claude_pid = _find_claude_pid()

    # Resolve the Ghostty terminal on start, and once more for sessions whose
    # ID predates asking the terminal (it may have been guessed wrong).
    if terminal == "ghostty" and (hook_event == "SessionStart" or not ghostty_checked):
        tty = _tty_of(claude_pid)
        # A daemon-dispatched event has no terminal to ask, so it can't do
        # better than an ID already on file.
        if tty or not ghostty_terminal_id:
            found, ghostty_checked = _get_ghostty_terminal_id(cwd, tty)
            if found:
                ghostty_terminal_id = found

    if not project_dir:
        project_dir = _project_dir(cwd, data.get("transcript_path", ""))

    session_data = {
        "session_id": session_id,
        "cwd": cwd,
        "project_dir": project_dir,
        "state": new_state,
        "state_since": state_since,
        "created_at": created_at,
        "last_updated": now,
        "tool_name": tool_name,
        "last_event": hook_event,
        "terminal_session_id": terminal_session_id,
        "terminal": terminal,
        "claude_pid": claude_pid,
        "provider": "claude",
        "ghostty_terminal_id": ghostty_terminal_id,
        "ghostty_terminal_checked": ghostty_checked,
        "permission_mode": permission_mode,
    }

    # On SessionStart, remove stale files from the same terminal tab
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
