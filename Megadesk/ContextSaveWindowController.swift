import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ContextSaveWindowController: NSWindowController {
    private var snoozeTimer: Timer?

    convenience init() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // Rounded corners at AppKit level
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.masksToBounds = true

        panel.center()

        self.init(window: panel)
    }

    private var isShowingInput = false

    func showForInput() {
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        // If already showing input, just bring to front without resetting in-progress text
        if window?.isVisible == true && isShowingInput {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        installView(reminderMode: false)
        isShowingInput = true
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showForReminder() {
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        guard AppSettings.shared.contextNote != nil else { return }
        installView(reminderMode: true)
        isShowingInput = false
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        isShowingInput = false
        window?.orderOut(nil)
    }

    func scheduleSnooze() {
        dismiss()
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.showForReminder()
        }
    }

    private func installView(reminderMode: Bool) {
        let view = ContextSaveView(
            existingNote: AppSettings.shared.contextNote,
            startInReminder: reminderMode,
            onDismiss: { [weak self] in self?.dismiss() },
            onSnooze: { [weak self] in self?.scheduleSnooze() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        window?.contentView = hosting

        // Re-apply corner radius after replacing contentView
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 14
        hosting.layer?.masksToBounds = true

        window?.setContentSize(NSSize(width: 380, height: 260))
        window?.center()
    }
}
