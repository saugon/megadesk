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
            return false
        }
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
