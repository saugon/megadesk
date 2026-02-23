import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: FloatingWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        windowController = FloatingWindowController(contentView: contentView)
        windowController?.window?.delegate = self
        windowController?.show()
        setupMenuBar()
        primeAutomationPermission()
    }

    private func primeAutomationPermission() {
        let script = "tell application \"iTerm2\" to get name"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Megadesk")
            button.image?.isTemplate = true  // adapts to light/dark menu bar
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Hide Widget", action: #selector(toggleWidget), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Megadesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    @objc private func toggleWidget() {
        windowController?.toggle()
    }
}

// MARK: - NSMenuDelegate — refresh title before menu appears

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let isVisible = windowController?.isWidgetVisible ?? false
        menu.item(at: 0)?.title = isVisible ? "Hide Widget" : "Show Widget"
    }
}

// MARK: - NSWindowDelegate — close button hides instead of quitting

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        windowController?.hide()
        return false
    }
}
