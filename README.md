<p align="center">
  <img src="docs/icon.png" width="96" alt="Megadesk icon">
</p>

# Megadesk

**Session monitor for Claude Code & Codex on iTerm2 and Ghostty.**

<p align="center">
  <a href="https://github.com/saugon/megadesk/releases/latest/download/Megadesk.dmg">
    <img src="https://img.shields.io/badge/Download-Megadesk.dmg-blue?style=for-the-badge&logo=apple" alt="Download">
  </a>
</p>

Megadesk is a macOS menu-bar widget that shows all your active Claude Code and Codex CLI sessions at a glance. Each session card displays its current state, how long it's been in that state, and lets you jump directly to the right terminal tab with a single click. Supports iTerm2 and Ghostty with per-tab focus.

---

<p align="center">
  <img src="docs/widget.png" width="320" alt="Megadesk widget showing sessions and pull requests">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/help.png" width="560" alt="Megadesk help panel with session states and hotkeys">
</p>

---

## Requirements

- macOS 14 or later
- [iTerm2](https://iterm2.com) or [Ghostty](https://ghostty.org)
- [Claude Code](https://claude.ai/code) and/or [Codex CLI](https://github.com/openai/codex)
- [gh CLI](https://cli.github.com) — only needed for PR tracking

---

## Setup

On first launch, Megadesk runs a three-step onboarding:

**Step 1 — Connect Claude Code**
Clicks "Install Hook" to add a Python hook to `~/.claude/settings.json`. This hook notifies Megadesk whenever a Claude Code session changes state (tool use, stop, prompt submit, etc.).

**Step 2 — Connect Codex** *(optional)*
Clicks "Install Hook" to set the `notify` command in `~/.codex/config.toml`. Skip this if you don't use Codex.

**Step 3 — Allow Terminal Control**
Clicks "Grant Access" to authorize AppleScript control of your terminal (iTerm2 and/or Ghostty). This is what lets Megadesk focus the right tab when you click a session card. If you skip this step (or deny it in System Settings), the widget still shows session states but clicking cards won't switch tabs.

After setup, click **Continue**. The widget appears and stays visible until you hide it with `⌘⇧M`.

---

## The Widget

The widget is a floating panel that sits above all other windows without stealing focus. It shows three sections: **sessions**, **pull requests**, and **alerts**.

### Session states

Each session card has a colored badge showing its provider (**C** for Claude, **X** for Codex) and current state:

| Color | State | Meaning |
|-------|-------|---------|
| 🟢 Green | **Working** | Actively running a task |
| 🔵 Cyan | **Needs confirmation** | Waiting for you to approve or deny a tool |
| 🟠 Orange | **Waiting for input** | Finished — your turn to respond |
| ⚪ Gray | **Forgotten** | Idle for longer than the configured timeout (default: 5 min) |

The time displayed on the right shows how long the session has been in its current state.

### Interacting with sessions

**Click a card** — focuses the corresponding terminal tab and pane via AppleScript. Works with both iTerm2 and Ghostty, including split panes.

**Rename a session** — hover over a card and click the pencil icon (✏) that appears. Type a name and press Enter to confirm, Escape to cancel. Custom names persist even when you `cd` into a different directory in that tab. To revert to the auto-detected name, click the ↩ button that appears while editing.

---

## Pull Request Tracking

The **pull requests** section shows live CI status for any GitHub PR you want to monitor.

**To track a PR**, click **+ Track PR** at the bottom of the widget and paste a GitHub PR URL — for example:

```
https://github.com/org/repo/pull/123
```

Megadesk uses the `gh` CLI to poll the PR every 60 seconds. The countdown until the next refresh is shown next to the section header.

### PR states

| Dot | State | Meaning |
|-----|-------|---------|
| 🟢 Green | **CI passing** | All checks passed |
| 🟠 Orange | **CI pending** | Checks are still running |
| 🔴 Red | **CI failing** | One or more checks failed |
| 🔵 Cyan | **Merged** | PR was successfully merged |
| ⚪ Gray | **Closed / no CI** | Closed without merging, or no CI configured |

To remove a PR from tracking, hover over its card and click the **×** button.

---

## Hotkeys

| Shortcut | Action |
|----------|--------|
| `⌘⇧M` | Toggle widget visibility from anywhere |
| `⌘⇧A` | Quick alert popover for fast reminders |
| `⇧⌥↑` / `⇧⌥↓` | Cycle through sessions (highlights the card and focuses its tab) |
| `⌥⌘1` … `⌥⌘9` | Focus session by position |

---

## Alerts

Megadesk includes a built-in reminder system. Create one-time or recurring alerts that notify you through configurable channels.

**Quick capture** — press `⌘⇧A` (or click the bell icon in the widget titlebar) to open a popover where you type a title and pick a time preset (1m, 5m, 10m, 15m, 30m, 1h).

**Alerts window** — open from the menu bar (**Alerts...**) to manage all alerts. The window has two tabs: active alerts with full configuration (title, time, recurrence, per-alert notification overrides) and completed alerts.

### Recurrence options

Once, Daily, Weekdays (Mon–Fri), Weekly, Monthly, Every N minutes, Every N hours.

### Notification channels

Each channel can be toggled globally in the Alerts window, and overridden per-alert:

| Channel | Description |
|---------|-------------|
| **Toast** | Floating notification in the top-right corner, auto-dismisses after 10s |
| **Widget** | Alert card appears in the widget with snooze/dismiss buttons |
| **macOS Notification** | Standard notification center alert with Snooze/Dismiss actions |
| **Badge** | Orange dot on the menu bar icon |
| **Sound** | Plays a system sound |

Toast and Widget are mutually exclusive — you can enable one or the other per alert, not both.

---

## Compact Mode

Compact Mode collapses each session card into a single colored badge, reducing the widget to a narrow column. Toggle it from the menu-bar icon menu (**Compact Mode**).

---

## Settings

Open Settings with `⌘,` or via the menu bar icon.

| Setting | Description |
|---------|-------------|
| **Forgotten after** | How long a session must be idle before it turns gray (default: 5 min) |
| **Widget opacity** | Opacity of the widget when the mouse is not over it. Hover restores full opacity |
| **Sort sessions** | Order cards by state, last activity, name, or creation time |
| **Colors** | Customize the dot color for each session and PR state |

---

## Menu Bar

Click the Megadesk icon in the menu bar to access:

- **Hide / Show Widget** — same as `⌘⇧M`
- **Compact Mode** — toggle the condensed view
- **Show PR Tracking** — show or hide the PR section
- **Alerts...** — open the alerts management window
- **Settings** — open the settings panel (`⌘,`)
- **Help** — opens the reference panel with states, features, and hotkeys
- **Quit**

---

## Known Issues

- **Session state may not always update correctly.** Megadesk relies on hooks to detect state changes. If a session is interrupted (e.g. `Ctrl+C`), the hook may not fire and the card can remain stuck on "working" until the next event arrives. This is a limitation of the hook-based approach.
- **Codex sessions update less frequently.** Codex only notifies on `agent-turn-complete` and `approval-requested`, so there's no real-time tool-use tracking like Claude Code has. The card shows the last known state.

---

## How it works

On install, Megadesk copies hook scripts and registers them with each provider:

- **Claude Code**: `megadesk-hook.py` is added to `~/.claude/settings.json` for five events: `PreToolUse`, `PostToolUse`, `Stop`, `UserPromptSubmit`, and `SessionStart`.
- **Codex CLI**: `megadesk-codex-hook.py` is set as the `notify` command in `~/.codex/config.toml`, triggered on `agent-turn-complete` and `approval-requested`.

Each time an event fires, the hook writes a small JSON file to `~/.claude/megadesk/sessions/`, which Megadesk watches via kqueue to update the session card in real time. For Ghostty, the hook also captures the terminal's unique ID via AppleScript at session start, enabling precise tab and split-pane focusing.

No data leaves your machine. The hooks run locally and Megadesk never makes any network requests except through the `gh` CLI for PR status.
