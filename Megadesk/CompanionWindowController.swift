import AppKit
import SwiftUI

final class CompanionWindowController: NSWindowController {

    private weak var mainWidgetWindow: NSWindow?
    private var moveObserver: Any?
    private var resizeObserver: Any?
    private var contentResizeObserver: Any?
    private var suppressPositionSave = false

    convenience init(mainWidgetWindow: NSWindow?) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 90),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: CompanionView())
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        // Hide standard buttons
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.init(window: panel)
        self.mainWidgetWindow = mainWidgetWindow

        if AppSettings.shared.companionMode == .docked, let mainWindow = mainWidgetWindow {
            observeMainWindow(mainWindow)
        }

        // Listen for content resize (when speech bubble appears/disappears).
        // The panel grows/shrinks upward (preserving bottom-left).
        contentResizeObserver = NotificationCenter.default.addObserver(
            forName: .megadeskCompanionContentResized,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let h = note.userInfo?["height"] as? CGFloat else { return }
            self?.resizeContent(height: h)
        }

        // Save position when the user drags the companion panel (floating mode).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.savePosition()
        }
    }

    // MARK: - Show / Hide

    func show() {
        guard AppSettings.shared.companionEnabled, let window else { return }

        positionWindow()

        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                window.animator().alphaValue = 1.0
            }
        } else {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1.0
        })
    }

    // MARK: - Resize on content change (grow/shrink upward)

    private func resizeContent(height: CGFloat) {
        guard let window else { return }
        let targetHeight = max(60, ceil(height))

        guard abs(targetHeight - window.frame.height) > 1 else { return }

        // Preserve bottom-left — panel grows upward when content grows.
        let bottomLeft = NSPoint(x: window.frame.origin.x, y: window.frame.origin.y)
        let newFrame = NSRect(x: bottomLeft.x, y: bottomLeft.y,
                              width: window.frame.width, height: targetHeight)
        suppressPositionSave = true
        window.setFrame(newFrame, display: true, animate: false)
        suppressPositionSave = false
    }

    // MARK: - Positioning

    private func positionWindow() {
        guard let window else { return }
        let mode = AppSettings.shared.companionMode

        if mode == .docked, let main = mainWidgetWindow, main.isVisible {
            positionDocked(relativeTo: main)
        } else if mode == .floating {
            positionFloating()
        } else {
            // Docked but main widget not visible — use saved or default
            positionFloating()
        }
    }

    private func positionDocked(relativeTo main: NSWindow) {
        guard let window else { return }
        let gap: CGFloat = 4
        let x = main.frame.maxX + gap
        let y = main.frame.maxY - window.frame.height
        suppressPositionSave = true
        window.setFrameOrigin(NSPoint(x: x, y: y))
        suppressPositionSave = false
    }

    private func positionFloating() {
        guard let window else { return }
        let ud = UserDefaults.standard

        // Saved as bottom-left so position stays stable when panel grows upward.
        if ud.object(forKey: "megadesk.companion.windowX") != nil {
            let x = ud.double(forKey: "megadesk.companion.windowX")
            let y = ud.double(forKey: "megadesk.companion.windowY")
            let bottomLeft = NSPoint(x: x, y: y)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(bottomLeft) }) {
                window.setFrameOrigin(bottomLeft)
                return
            }
        }

        // Default: top-right area of main screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - window.frame.width - 16
            let y = screen.visibleFrame.maxY - 200
            window.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }
    }

    func savePosition() {
        guard !suppressPositionSave, let window, AppSettings.shared.companionMode == .floating else { return }
        let bottomLeft = window.frame.origin
        UserDefaults.standard.set(Double(bottomLeft.x), forKey: "megadesk.companion.windowX")
        UserDefaults.standard.set(Double(bottomLeft.y), forKey: "megadesk.companion.windowY")
    }

    // MARK: - Docked mode: track main widget

    func observeMainWindow(_ mainWindow: NSWindow) {
        clearMainWindowObservers()
        self.mainWidgetWindow = mainWindow

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: mainWindow,
            queue: .main
        ) { [weak self] _ in
            guard AppSettings.shared.companionMode == .docked else { return }
            self?.positionDocked(relativeTo: mainWindow)
        }

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: mainWindow,
            queue: .main
        ) { [weak self] _ in
            guard AppSettings.shared.companionMode == .docked else { return }
            self?.positionDocked(relativeTo: mainWindow)
        }
    }

    private func clearMainWindowObservers() {
        if let obs = moveObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = resizeObserver { NotificationCenter.default.removeObserver(obs) }
        moveObserver = nil
        resizeObserver = nil
    }

    func updateMode() {
        guard let window else { return }
        let mode = AppSettings.shared.companionMode

        if mode == .docked, let main = mainWidgetWindow {
            observeMainWindow(main)
            if window.isVisible { positionDocked(relativeTo: main) }
        } else {
            clearMainWindowObservers()
            if window.isVisible { positionFloating() }
        }
    }

    deinit {
        clearMainWindowObservers()
        if let obs = contentResizeObserver { NotificationCenter.default.removeObserver(obs) }
    }
}
