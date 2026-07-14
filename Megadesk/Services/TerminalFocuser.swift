import Foundation
import AppKit

struct TerminalFocuser {

    /// Serial queue for the cwd-based focus lookup. Enumerating every iTerm
    /// session's variables is slow, so it must run off the main thread or it
    /// freezes the whole UI while iTerm responds.
    private static let cwdFocusQueue = DispatchQueue(label: "com.megadesk.terminalfocuser")

    /// Focuses the correct terminal tab/pane based on the session's terminal type.
    @discardableResult
    static func focus(session: Session) -> Bool {
        switch session.terminal {
        case .iterm2:
            return focusiTerm2(sessionId: session.terminalSessionId)
        case .ghostty:
            return focusGhostty(terminalId: session.ghosttyTerminalId, cwd: session.cwd)
        case .unknown:
            focusByCwd(cwd: session.cwd)
            return true   // work happens asynchronously; assume success
        }
    }

    /// Best-effort focus for sessions whose terminal the hook never resolved
    /// (terminal == .unknown — e.g. Claude ran as a daemon with no
    /// ITERM_SESSION_ID/TTY, so no tab id was captured). Matches an open
    /// terminal tab by its working directory. Runs off the main thread because
    /// enumerating every iTerm session is slow and would freeze the UI.
    static func focusByCwd(cwd: String) {
        guard !cwd.isEmpty else { return }
        cwdFocusQueue.async {
            activateApp()
            if isRunning("com.googlecode.iterm2"), focusiTerm2ByCwd(cwd: cwd) { return }
            if isRunning("com.mitchellh.ghostty") {
                DispatchQueue.main.async { _ = focusGhostty(terminalId: "", cwd: cwd) }
            }
        }
    }

    private static func activateApp() {
        DispatchQueue.main.async {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private struct ItermPane {
        let tty: String
        let job: String
        let path: String
    }

    private static func focusiTerm2ByCwd(cwd: String) -> Bool {
        // Collect every iTerm session's tty, foreground job and cwd, then pick
        // the best match in Swift — the hook's cwd (e.g. …/vertex_t2/backend)
        // often differs from the shell's reported cwd (…/vertex_t2), so an
        // exact match isn't enough; fall back to the closest ancestor path and
        // prefer the agent's `node` pane.
        guard let panes = listItermPanes(), !panes.isEmpty else { return false }
        guard let target = bestPane(for: cwd, among: panes) else { return false }

        let escapedTty = target.tty.replacingOccurrences(of: "\"", with: "\\\"")
        let focusScript = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) is "\(escapedTty)" then
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

        return runAppleScript(focusScript, permissionTerminal: "iTerm2")
    }

    private static func listItermPanes() -> [ItermPane]? {
        let script = """
        tell application "iTerm2"
            set d to (character id 9)
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set p to ""
                        try
                            set p to (variable s named "path")
                        end try
                        set jn to ""
                        try
                            set jn to (variable s named "jobName")
                        end try
                        set out to out & (tty of s) & d & jn & d & p & linefeed
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            // Only surface the automation-permission alert for real permission
            // errors, not transient scripting failures.
            let num = error[NSAppleScript.errorNumber] as? Int ?? 0
            if num == -1743 || num == -600 { showPermissionAlert(terminal: "iTerm2") }
            return nil
        }
        guard let raw = result.stringValue else { return nil }
        return raw
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { line -> ItermPane? in
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 3, !cols[0].isEmpty else { return nil }
                return ItermPane(
                    tty: cols[0],
                    job: cols[1].trimmingCharacters(in: .whitespaces),
                    path: cols[2]
                )
            }
    }

    /// Ranks panes against a target cwd: exact path wins, then the deepest
    /// ancestor path, then a descendant path; the agent's `node` job breaks ties.
    private static func bestPane(for cwd: String, among panes: [ItermPane]) -> ItermPane? {
        func score(_ p: ItermPane) -> (rank: Int, node: Int, depth: Int)? {
            guard !p.path.isEmpty else { return nil }
            let node = (p.job == "node") ? 1 : 0
            if p.path == cwd { return (3, node, p.path.count) }
            if cwd.hasPrefix(p.path + "/") { return (2, node, p.path.count) }   // pane is an ancestor of the session
            if p.path.hasPrefix(cwd + "/") { return (1, node, -p.path.count) }  // session is an ancestor of the pane
            return nil
        }
        return panes
            .compactMap { pane -> (ItermPane, (Int, Int, Int))? in
                score(pane).map { (pane, ($0.rank, $0.node, $0.depth)) }
            }
            .max { lhs, rhs in
                if lhs.1.0 != rhs.1.0 { return lhs.1.0 < rhs.1.0 }
                if lhs.1.1 != rhs.1.1 { return lhs.1.1 < rhs.1.1 }
                return lhs.1.2 < rhs.1.2
            }?
            .0
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
