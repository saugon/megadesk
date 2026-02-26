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

    @discardableResult
    static func focusKitty(windowId: String, listenOn: String) -> Bool {
        guard !windowId.isEmpty, !listenOn.isEmpty else { return false }

        NSApp.activate(ignoringOtherApps: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kitty", "@", "--to", listenOn, "focus-window", "--match", "id:\(windowId)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[Megadesk] kitty @ error: \(error)")
            return false
        }

        let success = process.terminationStatus == 0

        if success {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "net.kovidgoyal.kitty" }?
                .activate()
        }

        return success
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
