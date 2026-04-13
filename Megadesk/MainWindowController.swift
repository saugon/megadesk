import AppKit
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate {
    let state = MainWindowState()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Megadesk"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 420)

        self.init(window: window)

        let hosting = NSHostingController(rootView: MainWindowView(state: state))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 820, height: 540))
        window.center()
        window.delegate = self
    }

    func show(section: MainSection) {
        state.selection = section
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
