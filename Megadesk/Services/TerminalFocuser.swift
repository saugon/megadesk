import Foundation
import AppKit

struct TerminalFocuser {
    @discardableResult
    static func focusiTerm2(sessionId: String) -> Bool {
        // sessionId is the bare UUID (hook script strips the "w0t0p0:" prefix).
        // Inside tmux the format is "{uuid}:{tmux_pane}" — strip the suffix.
        let rawId = sessionId.components(separatedBy: ":").first ?? sessionId
        guard !rawId.isEmpty else { return false }

        // `tell s to select` is the canonical iTerm2 AppleScript call:
        // it switches the tab, selects the session, and brings the window to front
        // in one atomic operation — avoids the race where `set current tab`
        // fails when the window is already frontmost.
        // Returns true if the session was found, false otherwise.
        // `tell s to select` is the canonical iTerm2 AppleScript call:
        // it switches the tab, selects the session, and brings the window to front
        // in one atomic operation — avoids the race where `set current tab`
        // fails when the window is already frontmost.
        // Returns true if the session was found, false otherwise.
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

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error {
                print("[Megadesk] AppleScript error: \(error)")
                showPermissionAlert()
                return false
            }
            return result.booleanValue
        }
        return false
    }

    static func runCommand(_ command: String, closeOnCompletion: Bool = false) {
        let sentinel: String?
        let finalCommand: String
        if closeOnCompletion {
            sentinel = "/tmp/megadesk-\(UUID().uuidString)"
            finalCommand = "\(command); touch \(sentinel!)"
        } else {
            sentinel = nil
            finalCommand = command
        }

        let escaped = finalCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            tell current window
                create tab with default profile
                set sid to unique id of current session of current tab
                tell current session of current tab
                    write text "\(escaped)"
                end tell
            end tell
            activate
            return sid
        end tell
        """
        NSApp.activate(ignoringOtherApps: true)
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error != nil { showPermissionAlert(); return }
            if let sentinel, let sessionId = result.stringValue {
                pollAndClose(sessionId: sessionId, sentinel: sentinel)
            }
        }
    }

    private static func pollAndClose(sessionId: String, sentinel: String) {
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<7200 { // 4 hours at 2s intervals
                Thread.sleep(forTimeInterval: 2)
                if FileManager.default.fileExists(atPath: sentinel) {
                    try? FileManager.default.removeItem(atPath: sentinel)
                    closeSession(sessionId: sessionId)
                    return
                }
            }
            try? FileManager.default.removeItem(atPath: sentinel)
        }
    }

    private static func closeSession(sessionId: String) {
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(sessionId)" then
                            close s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }

    private static var hasShownPermissionAlert = false

    private static func showPermissionAlert() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Megadesk needs Automation permission"
            alert.informativeText = "Megadesk needs permission to control iTerm2.\nGo to System Settings → Privacy & Security → Automation → enable iTerm2 under Megadesk."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
