import AppKit
import SwiftUI

/// The tasks window. Tasks get their own window rather than a widget section:
/// there are many of them, they live for days, and they'd bury the cards.
final class TasksWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tasks"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 460)

        self.init(window: window)

        let hosting = NSHostingController(rootView: TasksView())
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 860, height: 560))
        window.center()
        window.delegate = self
    }

    func show() {
        guard AppSettings.shared.tasksEnabled else { return }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        guard window?.isVisible == true else { return }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.regularWindowDidClose(window)
    }
}
