import Foundation
import AppKit

struct TerminalFocuser {
    static func focusiTerm2(sessionId: String) {
        // sessionId is the bare UUID (hook script strips the "w0t0p0:" prefix).
        // Inside tmux the format is "{uuid}:{tmux_pane}" — strip the suffix.
        let rawId = sessionId.components(separatedBy: ":").first ?? sessionId
        guard !rawId.isEmpty else { return }

        // `tell s to select` is the canonical iTerm2 AppleScript call:
        // it switches the tab, selects the session, and brings the window to front
        // in one atomic operation — avoids the race where `set current tab`
        // fails when the window is already frontmost.
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
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """

        // Activate Megadesk within the button action so macOS treats it as
        // user-initiated. This gives us an activation token to transfer focus
        // to iTerm2 via the `activate` command in the script below.
        NSApp.activate(ignoringOtherApps: true)

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error {
                print("[Megadesk] AppleScript error: \(error)")
                showPermissionAlert()
            }
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
