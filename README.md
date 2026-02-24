# Megadesk

**Claude Code session monitor for iTerm2.**

Megadesk is a macOS menu-bar widget that shows all your active Claude Code sessions at a glance. Each session card displays its current state, how long it's been in that state, and lets you jump directly to the right iTerm2 tab with a single click.

---

## Requirements

- macOS 14 or later
- [iTerm2](https://iterm2.com)
- [Claude Code](https://claude.ai/code) (the `claude` CLI)
- [gh CLI](https://cli.github.com) — only needed for PR tracking

---

## Setup

On first launch, Megadesk runs a two-step onboarding:

**Step 1 — Install Hook**
Clicks "Install Hook" to add a Python hook to `~/.claude/settings.json`. This hook notifies Megadesk whenever a Claude Code session changes state (tool use, stop, prompt submit, etc.).

**Step 2 — Allow iTerm2 Control**
Clicks "Grant Access" to authorize AppleScript control of iTerm2. This is what lets Megadesk focus the right tab when you click a session card. If you skip this step (or deny it in System Settings), the widget still shows session states but clicking cards won't switch tabs.

After both steps, click **Continue**. The widget appears and stays visible until you hide it with `⌘⇧M`.

---

## The Widget

The widget is a floating panel that sits above all other windows without stealing focus. It shows two sections: **sessions** and **pull requests**.

### Session states

Each session card has a colored dot indicating Claude's current state:

| Dot | State | Meaning |
|-----|-------|---------|
| 🟢 Green | **Working** | Claude is actively running a task |
| 🔵 Cyan | **Needs confirmation** | Waiting for you to approve or deny a tool |
| 🟠 Orange | **Waiting for input** | Claude finished — your turn to respond |
| ⚪ Gray | **Forgotten** | Idle for more than 5 minutes |

The time displayed on the right shows how long the session has been in its current state.

### Interacting with sessions

**Click a card** — focuses the corresponding iTerm2 tab immediately.

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
| `⇧⌥↑` / `⇧⌥↓` | Cycle through sessions (highlights the card and focuses its tab) |
| `⌥⌘1` … `⌥⌘9` | Focus session by position |

---

## Compact Mode

Compact Mode collapses each session card into a single colored dot, reducing the widget to a narrow column. Toggle it from the menu-bar icon menu (**Compact Mode**).

---

## Menu Bar

Click the Megadesk icon in the menu bar to access:

- **Hide / Show Widget** — same as `⌘⇧M`
- **Compact Mode** — toggle the condensed view
- **Show PR Tracking** — show or hide the PR section
- **Help** — opens the reference panel with states, features, and hotkeys
- **Quit**

---

## How it works

On install, Megadesk copies `megadesk-hook.py` to `~/.claude/` and registers it as a hook for five Claude Code events: `PreToolUse`, `PostToolUse`, `Stop`, `UserPromptSubmit`, and `SessionStart`. Each time one of these fires, the hook writes a small JSON payload to a local socket that Megadesk listens on, updating the session card in real time.

No data leaves your machine. The hook runs locally and Megadesk never makes any network requests except through the `gh` CLI for PR status.
