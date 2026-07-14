import Foundation
import AppKit

struct TerminalFocuser {

    /// Focuses the correct terminal tab/pane based on the session's terminal type.
    @discardableResult
    static func focus(session: Session) -> Bool {
        switch session.terminal {
        case .iterm2:
            return focusiTerm2(sessionId: session.terminalSessionId)
        case .ghostty:
            return focusGhostty(terminalId: session.ghosttyTerminalId, cwd: session.cwd)
        case .unknown:
            return focusByCwd(cwd: session.cwd)
        }
    }

    /// Best-effort focus for sessions whose terminal the hook never resolved
    /// (terminal == .unknown — e.g. Claude ran as a daemon with no
    /// ITERM_SESSION_ID/TTY, so no tab id was captured). Matches an open
    /// terminal tab by its working directory instead.
    @discardableResult
    static func focusByCwd(cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        if isRunning("com.googlecode.iterm2"), focusiTerm2ByCwd(cwd: cwd) { return true }
        if isRunning("com.mitchellh.ghostty"), focusGhostty(terminalId: "", cwd: cwd) { return true }
        return false
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private static func focusiTerm2ByCwd(cwd: String) -> Bool {
        let escapedCwd = cwd.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")

        // A single cwd can back several sessions (the agent, extra shells,
        // `make`, …). Prefer the one running the agent (jobName "node"); fall
        // back to the first tab that matches the directory.
        let script = """
        tell application "iTerm2"
            set fbW to missing value
            set fbT to missing value
            set fbS to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set p to ""
                        try
                            set p to (variable s named "path")
                        end try
                        if p is "\(escapedCwd)" then
                            set jn to ""
                            try
                                set jn to (variable s named "jobName")
                            end try
                            if jn is "node" then
                                tell t to select
                                tell s to select
                                tell w to select
                                activate
                                return true
                            else if fbS is missing value then
                                set fbW to w
                                set fbT to t
                                set fbS to s
                            end if
                        end if
                    end repeat
                end repeat
            end repeat
            if fbS is not missing value then
                tell fbT to select
                tell fbS to select
                tell fbW to select
                activate
                return true
            end if
            return false
        end tell
        """

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        return runAppleScript(script, permissionTerminal: "iTerm2")
    }

    private static func focusiTerm2(sessionId: String) -> Bool {
        // sessionId is the bare UUID (hook script strips the "w0t0p0:" prefix).
        // Inside tmux the format is "{uuid}:{tmux_pane}" — strip the suffix.
        let rawId = sessionId.components(separatedBy: ":").first ?? sessionId
        guard !rawId.isEmpty else { return false }

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(rawId)" then
                            tell t to select
                            tell s to select
                            tell w to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        return runAppleScript(script, permissionTerminal: "iTerm2")
    }

    private static func focusGhostty(terminalId: String, cwd: String) -> Bool {
        let escapedId = terminalId.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedCwd = cwd.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")

        // Match by unique terminal ID when available, fall back to CWD
        let matchCondition = !terminalId.isEmpty
            ? "if id of term is \"\(escapedId)\""
            : "if working directory of term is \"\(escapedCwd)\""

        let script = """
        tell application "Ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        \(matchCondition) then
                            select tab t
                            focus term
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """

        let found = runAppleScript(script, permissionTerminal: "Ghostty")
        if found {
            // AppleScript `activate` alone doesn't always transfer keyboard focus
            // when triggered from a non-activating panel click. Resign key on the
            // Megadesk panel first, then force-activate Ghostty.
            if let panel = NSApp.keyWindow {
                panel.resignKey()
            }
            if let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first {
                if #available(macOS 14.0, *) {
                    ghostty.activate(from: NSRunningApplication.current)
                } else {
                    ghostty.activate(options: .activateIgnoringOtherApps)
                }
            }
        }
        return found
    }

    private static func runAppleScript(_ source: String, permissionTerminal: String) -> Bool {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return false }
        let result = appleScript.executeAndReturnError(&error)
        if error != nil {
            showPermissionAlert(terminal: permissionTerminal)
            return false
        }
        return result.booleanValue
    }

    // MARK: - Spinner scraping

    struct SpinnerInfo {
        let verb: String
        let detail: String      // e.g., "14m 43s · ↓ 9.4k tokens"
        let isHighEffort: Bool
    }

    private static let spinnerRegex = try! NSRegularExpression(
        pattern: "^. ([A-Z][A-Za-z\u{00C0}-\u{00FF}\u{2019}'-]+)\u{2026} ?(?:\\(([^)]+)\\))?",
        options: .anchorsMatchLines
    )

    /// Reads the current spinner verb and detail from an iTerm2 session's terminal content.
    /// Must be called from the AppleScript serial queue (NSAppleScript is not thread-safe).
    static func readiTerm2SpinnerInfo(terminalSessionId: String) -> SpinnerInfo? {
        let rawId = terminalSessionId.components(separatedBy: ":").first ?? terminalSessionId
        guard !rawId.isEmpty else { return nil }

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(rawId)" then
                            return contents of s
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let content = result.stringValue, !content.isEmpty else { return nil }
        return parseSpinnerInfo(from: content)
    }

    private static func parseSpinnerInfo(from content: String) -> SpinnerInfo? {
        // Only scan the tail — the spinner line is always near the bottom of the screen.
        // This avoids running regex over the entire scrollback buffer (potentially MB of text).
        let tail = content.count > 2000 ? String(content.suffix(2000)) : content
        let range = NSRange(tail.startIndex..., in: tail)
        let matches = spinnerRegex.matches(in: tail, range: range)
        guard let lastMatch = matches.last,
              let verbRange = Range(lastMatch.range(at: 1), in: tail)
        else { return nil }

        // Detail is optional — spinner initially shows just the verb
        let detail: String
        if lastMatch.range(at: 2).location != NSNotFound,
           let detailRange = Range(lastMatch.range(at: 2), in: tail) {
            detail = String(tail[detailRange])
        } else {
            detail = ""
        }

        let isHighEffort = detail.contains("high effort")

        return SpinnerInfo(
            verb: String(tail[verbRange]),
            detail: detail,
            isHighEffort: isHighEffort
        )
    }

    private static var shownPermissionAlerts: Set<String> = []

    private static func showPermissionAlert(terminal: String) {
        guard !shownPermissionAlerts.contains(terminal) else { return }
        shownPermissionAlerts.insert(terminal)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Megadesk needs Automation permission"
            alert.informativeText = "Megadesk needs permission to control \(terminal).\nGo to System Settings → Privacy & Security → Automation → enable \(terminal) under Megadesk."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
