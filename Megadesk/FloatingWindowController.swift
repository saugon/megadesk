import AppKit
import SwiftUI

/// NSHostingView subclass that accepts the first mouse-down event so that
/// clicks on the floating panel fire immediately without first activating the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// NSPanel subclass that can become the key window, enabling TextField keyboard input
/// without activating the application (handled separately per edit session).
private final class EditablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

extension Notification.Name {
    static let megadeskHideWidget    = Notification.Name("megadesk.hideWidget")
    static let megadeskFocusSession  = Notification.Name("megadesk.focusSession")
    static let megadeskCycleSession  = Notification.Name("megadesk.cycleSession")
}

final class FloatingWindowController: NSWindowController {

    private var titleLabel: NSTextField?
    private var suppressPositionSave = false

    convenience init(contentView: some View) {
        let initialCompact = UserDefaults.standard.bool(forKey: "megadesk.compact")
        let savedWidth = UserDefaults.standard.double(forKey: "megadesk.windowWidth")
        let normalWidth: CGFloat = savedWidth > 0 ? max(220, min(280, CGFloat(savedWidth))) : 280
        let initialWidth: CGFloat = initialCompact ? 78 : normalWidth
        let panel = EditablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 120),
            styleMask: [
                .titled,
                .nonactivatingPanel,
                .fullSizeContentView,
                .resizable,
            ],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden   // we draw our own title label
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(white: 0.1, alpha: 0.92)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Use FirstMouseHostingView so taps fire on the first click
        panel.contentView = FirstMouseHostingView(rootView:
            contentView
                .background(Color(nsColor: NSColor(white: 0.1, alpha: 0.0)))
        )

        if let corner = panel.contentView {
            corner.wantsLayer = true
            corner.layer?.cornerRadius = 12
            corner.layer?.masksToBounds = true
        }

        // Hide system traffic-light buttons
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.init(window: panel)

        installTitlebarControls(in: panel, compact: initialCompact)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowResize()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowMove()
        }
    }

    // MARK: - Title bar controls

    private func installTitlebarControls(in panel: NSPanel, compact: Bool) {
        guard let sysClose = panel.standardWindowButton(.closeButton),
              let titlebarView = sysClose.superview else { return }

        // Custom close button — always-red circle at the traffic-light position
        let size: CGFloat = 12
        let closeFrame = NSRect(
            x: sysClose.frame.midX - size / 2,
            y: sysClose.frame.midY - size / 2,
            width: size,
            height: size
        )
        let btn = TitlebarCloseButton(frame: closeFrame)
        btn.target = self
        btn.action = #selector(customClosePressed)
        titlebarView.addSubview(btn)

        // Custom title label — white, always visible regardless of key state
        let label = NSTextField(labelWithString: compact ? "md" : "megadesk")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        label.sizeToFit()
        // Center vertically in the title bar, center horizontally in the full width
        label.frame = NSRect(
            x: (titlebarView.bounds.width - label.frame.width) / 2,
            y: sysClose.frame.midY - label.frame.height / 2,
            width: label.frame.width,
            height: label.frame.height
        )
        titlebarView.addSubview(label)
        titleLabel = label
    }

    @objc private func customClosePressed() {
        hide()
    }

    private func handleWindowMove() {
        guard !suppressPositionSave, let panel = window else { return }
        // Store the top-left point so position stays stable regardless of window height changes.
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: "megadesk.windowX")
        UserDefaults.standard.set(Double(panel.frame.origin.y + panel.frame.height), forKey: "megadesk.windowY")
    }

    /// Returns the last saved top-left point if it's within a visible screen, otherwise nil.
    private func savedTopLeft(for window: NSWindow) -> NSPoint? {
        guard UserDefaults.standard.object(forKey: "megadesk.windowX") != nil else { return nil }
        let x = UserDefaults.standard.double(forKey: "megadesk.windowX")
        let y = UserDefaults.standard.double(forKey: "megadesk.windowY")
        let topLeft = NSPoint(x: x, y: y)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(topLeft) }) else { return nil }
        return topLeft
    }

    private func handleWindowResize() {
        guard let panel = window else { return }
        // Re-center title label
        if let label = titleLabel, let superview = label.superview {
            label.frame.origin.x = (superview.bounds.width - label.frame.width) / 2
        }
        // Persist width only in normal mode
        if !isCompact {
            UserDefaults.standard.set(Double(panel.frame.width), forKey: "megadesk.windowWidth")
        }
    }

    // MARK: - State

    var isWidgetVisible: Bool { window?.isVisible ?? false }

    var isCompact: Bool { UserDefaults.standard.bool(forKey: "megadesk.compact") }

    func toggleCompact() {
        guard let panel = window else { return }
        let newValue = !isCompact
        // Note: UserDefaults is NOT updated here — doing so would cause SwiftUI to
        // re-render immediately (compact layout visible during the fade-out).

        let fadeOutDuration: TimeInterval = 0.12
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().alphaValue = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) {
            panel.orderOut(nil)      // fuera del Window Server — todo lo que sigue es invisible
            UserDefaults.standard.set(newValue, forKey: "megadesk.compact")  // SwiftUI re-render mientras invisible
            panel.alphaValue = 1.0   // reset para show()

            let width: CGFloat = newValue ? 78 : 280
            self.suppressPositionSave = true
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - width - 16
                let topY = screen.visibleFrame.maxY - 60
                panel.setFrame(NSRect(x: x, y: topY - panel.frame.height, width: width, height: panel.frame.height),
                               display: true, animate: false)
            }
            self.suppressPositionSave = false
            self.titleLabel?.stringValue = newValue ? "md" : "megadesk"
            self.titleLabel?.sizeToFit()
            if let label = self.titleLabel, let superview = label.superview {
                label.frame.origin.x = (superview.bounds.width - label.frame.width) / 2
            }

            self.show()   // fade-in reutilizando la animación existente
        }
    }

    func show() {
        guard let window = window else { return }
        if !window.isVisible {
            let topLeft: NSPoint
            if let saved = savedTopLeft(for: window) {
                topLeft = saved
            } else if let screen = NSScreen.main {
                topLeft = NSPoint(
                    x: screen.visibleFrame.maxX - window.frame.width - 16,
                    y: screen.visibleFrame.maxY - 60
                )
            } else {
                topLeft = NSPoint(x: 0, y: NSScreen.main?.frame.height ?? 800)
            }
            suppressPositionSave = true
            window.setFrameTopLeftPoint(topLeft)
            suppressPositionSave = false
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
                window.animator().alphaValue = 1.0
            }
        } else {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        guard let window = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1.0
        })
    }

    func toggle() {
        isWidgetVisible ? hide() : show()
    }
}

// MARK: - TitlebarCloseButton

/// An NSButton that always draws as a red circle, with an × on hover.
private final class TitlebarCloseButton: NSButton {

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .circular
        title = ""
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent)  { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.98, green: 0.37, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        if isHovered {
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath()
            let inset = bounds.insetBy(dx: bounds.width * 0.28, dy: bounds.height * 0.28)
            path.move(to: NSPoint(x: inset.minX, y: inset.minY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            path.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}
