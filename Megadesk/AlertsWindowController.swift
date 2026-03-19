import AppKit
import SwiftUI

final class AlertsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Megadesk Alerts"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)

        let hosting = NSHostingView(rootView: AlertsView())
        window.contentView = hosting
        window.center()

        self.init(window: window)
    }
}
