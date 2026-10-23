# Megadesk Companion — Implementation Prompt

## Overview

Add a "Companion" to Megadesk: a small floating ghost rendered in ASCII art that observes session and PR state and surfaces contextual observations to the user. The ghost lives either docked to the main widget or as a standalone floating window (user-configurable). It has personality but is conservative — it speaks only when it has something worth saying.

Before writing any code, read and understand the following files completely:
- `StatusStore.swift` — primary source of truth for sessions and PRs
- All files in `Models/` — understand data shapes for sessions and PRs
- `AppDelegate.swift` and `MegadeskApp.swift` — app lifecycle and dependency wiring
- `FloatingWindowController.swift` — how floating windows are created and managed
- `MainWindowView.swift` and `ContentView.swift` — how the main widget is structured
- `AppSettings.swift` — existing settings pattern to follow

Do not write any code until you have read all of the above.

---

## Architecture

Implement three new components, each in its own file:

### 1. `CompanionEngine.swift`
The brain. A class (or actor) that observes state and emits messages.

- Observe `StatusStore` (or equivalent) reactively — do NOT poll on a timer for state changes
- Use a **single shared timer** firing every 60 seconds for time-based rules only (waiting too long, stuck working, idle user)
- Debounce state change evaluations with a 2-second delay to avoid bursts on app launch or multiple simultaneous session changes
- Emit `CompanionMessage` structs containing: message text, ghost state (`.idle`, `.alert`, `.happy`), and a unique rule identifier
- Enforce a **per-rule cooldown**: once a rule fires for a given subject (e.g. session ID or PR ID), do not re-fire until the subject's state changes and requalifies
- Persist cooldown state and daily flags to `~/.claude/megadesk/companion-state.json` — read on init, write on change. Structure:

```json
{
  "lastGreetedDate": "2026-04-21",
  "firedRules": {
    "waitingTooLong:session-id-123": "2026-04-21T10:30:00Z",
    "stuckWorking:session-id-456": "2026-04-21T11:00:00Z"
  },
  "prLastKnownStatus": {
    "pr-123": "pending"
  }
}
```

### 2. `CompanionAnimator.swift`
Pure rendering. No business logic.

- Holds the current `GhostState` and cycles through ASCII frames on a **slow timer (500ms)**
- Exposes a `@Published var currentFrame: String`
- Three states with distinct frame sets:

**Idle** — slow eye blink:
```
Frame A:        Frame B:
. - - - - - .  . - - - - - .
/  •     •   \ /  ·     ·   \
|             ||             |
~` ~ `~ ` ~ `~~` ~ `~ ` ~ `~
```

**Alert** — eyes open, subtle horizontal tremble (alternate 1 space offset):
```
Frame A:         Frame B:
. - - - - - .   . - - - - - .
/  o     o   \  / o     o    \
|             | |             |
~` ~ `~ ` ~ `~ ~` ~ `~ ` ~ `~
```

**Happy** — curved eyes, bouncy tilde row:
```
Frame A:        Frame B:
. - - - - - .  . - - - - - .
/  ^     ^   \ /  ^     ^   \
|             ||             |
~`~~ `~~ `~~`~ ~` ~~`~ ~~`~~
```

- Stop animating (freeze on last frame) when the window is not visible — use `windowDidMiniaturize` / visibility observation to pause the timer

### 3. `CompanionWindowController.swift` + `CompanionView.swift`
The UI layer.

- `CompanionWindowController` manages a borderless `NSPanel` (same pattern as `FloatingWindowController`)
- `CompanionView` is a SwiftUI view showing:
  - The ASCII ghost (monospace font, fixed size — use SF Mono or fallback to Menlo)
  - A speech bubble that appears when there's an active message and auto-dismisses after 8 seconds
  - A dismiss button (×) on the bubble so the user can clear it manually
- The window can be toggled between **docked mode** (attached to the right edge of the main widget window) and **standalone floating mode**
- Add a setting in `AppSettings` called `companionMode: CompanionMode` with cases `.docked` and `.floating`
- In docked mode, reposition the companion window whenever the main widget moves
- The ghost itself should be ~120×100pt. Keep the total footprint small.

---

## The 9 Rules

Implement each rule in `CompanionEngine`. Each rule has an identifier used for cooldown tracking.

### Rule 1 — `waitingTooLong`
- **Trigger**: timer (every 60s)
- **Condition**: any session has been in `waitingForInput` state for > 15 minutes
- **Cooldown**: do not re-fire for the same session until it leaves and re-enters `waitingForInput`
- **Message**: `"Hey — \(sessionName) has been waiting for you for \(duration)."`
- **Ghost state**: `.alert`

### Rule 2 — `multipleWaiting`
- **Trigger**: state change
- **Condition**: 3 or more sessions simultaneously in `waitingForInput`
- **Cooldown**: once per transition above threshold (don't repeat while count stays ≥ 3)
- **Message**: `"You have \(count) sessions waiting. Oldest is \(sessionName)."`
- **Ghost state**: `.alert`

### Rule 3 — `stuckWorking`
- **Trigger**: timer (every 60s)
- **Condition**: any session has been in `working` state for > 30 minutes without any transition
- **Cooldown**: do not re-fire for the same session until it leaves `working`
- **Message**: `"\(sessionName) has been working for \(duration). Might be stuck."`
- **Ghost state**: `.alert`

### Rule 4 — `prCIFailing`
- **Trigger**: state change on PR list
- **Condition**: a tracked PR transitioned from non-failing to failing CI
- **Cooldown**: once per PR per failing transition (reset when CI goes back to passing/pending)
- **Persist**: previous PR CI status in `companion-state.json` under `prLastKnownStatus`
- **Message**: `"CI is failing on \(prTitle)."`
- **Ghost state**: `.alert`

### Rule 5 — `prConflicts`
- **Trigger**: state change on PR list
- **Condition**: a tracked PR has merge conflicts (check the PR model for a conflicts/mergeable field)
- **Cooldown**: once per PR until conflict is resolved
- **Message**: `"\(prTitle) has merge conflicts."`
- **Ghost state**: `.alert`

### Rule 6 — `userIdle`
- **Trigger**: timer (every 60s)
- **Condition**: no session interaction (no state transitions on any session) for > 45 minutes, and at least one session is not forgotten
- **Cooldown**: once per 45-minute idle window
- **Message**: `"Still there?"`
- **Ghost state**: `.idle`

### Rule 7 — `allForgotten`
- **Trigger**: state change
- **Condition**: all sessions are in `forgotten` state (and there is at least one session)
- **Cooldown**: once per transition to all-forgotten
- **Message**: `"All quiet. Good time for a break."`
- **Ghost state**: `.idle`

### Rule 8 — `firstSessionOfDay`
- **Trigger**: state change — new session appears
- **Condition**: first session created today (compare against `lastGreetedDate` in persisted state)
- **Cooldown**: once per calendar day — persist `lastGreetedDate` to `companion-state.json`
- **Message**: `"Hey! Let's get to work."`
- **Ghost state**: `.happy`

### Rule 9 — `prMerged`
- **Trigger**: state change on PR list
- **Condition**: a tracked PR transitioned to merged state
- **Cooldown**: once per PR
- **Message**: `"\(prTitle) merged. Nice."`
- **Ghost state**: `.happy`

---

## Settings Integration

Add to `AppSettings` (following the existing pattern):

```swift
var companionEnabled: Bool  // default: true
var companionMode: CompanionMode  // default: .docked
// Thresholds (with sensible defaults):
var companionWaitingThresholdMinutes: Int  // default: 15
var companionStuckWorkingThresholdMinutes: Int  // default: 30
var companionIdleThresholdMinutes: Int  // default: 45
```

Add a **Companion** section to `SettingsView` with toggles and threshold sliders.

---

## Performance Requirements

- `CompanionEngine` must not do any work when `companionEnabled == false` — skip all observation and timer setup
- The animation timer in `CompanionAnimator` must be paused when the companion window is hidden or the app is backgrounded
- All file I/O for `companion-state.json` must happen on a background queue — never on the main thread
- Debounce state-change evaluations by 2 seconds to handle burst updates
- The single 60-second timer must be invalidated and recreated only when `companionEnabled` changes, not on every state update
- No retain cycles — use `[weak self]` in all timer and Combine closures

---

## Implementation Order

Work in this order, checking in between each step:

1. `Models` additions if needed (e.g. `CompanionMessage`, `GhostState`, `CompanionMode`)
2. `CompanionEngine.swift` — rules + persistence, no UI
3. `CompanionAnimator.swift` — pure rendering logic
4. `CompanionView.swift` + `CompanionWindowController.swift` — UI shell, ghost visible, no messages yet
5. Wire `CompanionEngine` → `CompanionView` so messages appear
6. Docked vs floating mode logic
7. Settings integration
8. Test all 9 rules manually by temporarily lowering thresholds

Do not proceed to the next step without confirming the current one works.
