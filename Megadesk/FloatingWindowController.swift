import AppKit
import SwiftUI

/// NSHostingView subclass that accepts the first mouse-down event so that
/// clicks on the floating panel fire immediately without first activating the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// PreferenceKey that captures ContentView's natural height.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey that captures the footer's natural height.
private struct FooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Bridge class: SwiftUI writes content and footer heights, AppKit reads them.
private final class HeightReporter {
    var onHeightChange: (() -> Void)?
    var contentHeight: CGFloat = 0 {
        didSet { if contentHeight != oldValue { onHeightChange?() } }
    }
    var footerHeight: CGFloat = 0 {
        didSet { if footerHeight != oldValue { onHeightChange?() } }
    }
}

/// Lays out content at the top, footer pinned to the bottom, Spacer fills any gap between them.
/// Content and footer heights are measured independently so adjustPanelHeight always has
/// up-to-date values for both.
private struct HeightMeasuringScrollView<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer
    let reporter: HeightReporter

    var body: some View {
        VStack(spacing: 0) {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
            Spacer(minLength: 0)
            footer
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FooterHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(ContentHeightKey.self) { reporter.contentHeight = $0 }
        .onPreferenceChange(FooterHeightKey.self)  { reporter.footerHeight  = $0 }
    }
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
    private var isHovered = false
    private var heightReporter = HeightReporter()
    private var userSetHeight: CGFloat? = nil  // nil = auto-height; non-nil = user-locked
    private var lastKnownHeight: CGFloat = 120 // tracks last applied height to detect real user changes
    private var resetHeightButton: NSButton?
    private var isLiveResizing = false

    convenience init(contentView: some View, footerView: some View) {
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

        // Use FirstMouseHostingView so taps fire on the first click.
        // Wrap content in HeightMeasuringScrollView for height clamping + scrolling.
        let reporter = HeightReporter()
        let hosting = FirstMouseHostingView(rootView:
            HeightMeasuringScrollView(
                content: contentView
                    .background(Color(nsColor: NSColor(white: 0.1, alpha: 0.0))),
                footer: footerView,
                reporter: reporter
            )
        )
        hosting.sizingOptions = []  // We control the panel height, not the hosting view
        panel.contentView = hosting

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

        // Tracking area for hover-based opacity
        if let cv = panel.contentView {
            cv.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }
        observeOpacity()

        self.heightReporter = reporter
        reporter.onHeightChange = { [weak self] in
            self?.adjustPanelHeight()
        }

        let savedH = UserDefaults.standard.double(forKey: "megadesk.windowHeight")
        if savedH > 0 { self.userSetHeight = CGFloat(savedH) }

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

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.adjustPanelHeight()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.isLiveResizing = true }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.isLiveResizing = false }
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

        // Reset-to-auto-height button — right side of title bar, visible only when height is locked
        let resetBtn = NSButton()
        resetBtn.isBordered = false
        let symConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        resetBtn.image = NSImage(systemSymbolName: "arrow.up.and.down.circle",
                                 accessibilityDescription: "Reset to auto height")?
            .withSymbolConfiguration(symConfig)
        resetBtn.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        let btnSize: CGFloat = 16
        resetBtn.frame = NSRect(
            x: titlebarView.bounds.width - btnSize - 8,
            y: sysClose.frame.midY - btnSize / 2,
            width: btnSize, height: btnSize
        )
        resetBtn.autoresizingMask = [.minXMargin]   // stays right-anchored when window resizes
        resetBtn.target = self
        resetBtn.action = #selector(resetToAutoHeightAction)
        resetBtn.isHidden = (userSetHeight == nil)
        titlebarView.addSubview(resetBtn)
        self.resetHeightButton = resetBtn
    }

    @objc private func customClosePressed() {
        hide()
    }

    @objc private func resetToAutoHeightAction() {
        userSetHeight = nil
        UserDefaults.standard.removeObject(forKey: "megadesk.windowHeight")
        resetHeightButton?.isHidden = true
        // Defer so SwiftUI can re-render with the cleared lockedHeightPref before we
        // measure heights — prevents using stale contentHeight from the locked layout.
        DispatchQueue.main.async { self.adjustPanelHeight() }
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
        if let label = titleLabel, let superview = label.superview {
            label.frame.origin.x = (superview.bounds.width - label.frame.width) / 2
        }
        if !isCompact {
            UserDefaults.standard.set(Double(panel.frame.width), forKey: "megadesk.windowWidth")
        }
        // Only lock height for user-initiated resizes, not programmatic ones
        if !suppressPositionSave && abs(panel.frame.height - lastKnownHeight) > 1 {
            userSetHeight = panel.frame.height
            UserDefaults.standard.set(Double(panel.frame.height), forKey: "megadesk.windowHeight")
            resetHeightButton?.isHidden = false
        }
        lastKnownHeight = panel.frame.height
    }

    // MARK: - Hover opacity

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1.0
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = AppSettings.shared.idleOpacity
        }
    }

    private func observeOpacity() {
        withObservationTracking {
            _ = AppSettings.shared.idleOpacity
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.applyIdleOpacity()
                self?.observeOpacity()
            }
        }
    }

    private func applyIdleOpacity() {
        guard let window, window.isVisible, !isHovered else { return }
        window.alphaValue = AppSettings.shared.idleOpacity
    }

    // MARK: - State

    var isWidgetVisible: Bool { window?.isVisible ?? false }

    var isCompact: Bool { UserDefaults.standard.bool(forKey: "megadesk.compact") }

    func toggleCompact() {
        guard let panel = window else { return }
        userSetHeight = nil
        UserDefaults.standard.removeObject(forKey: "megadesk.windowHeight")
        resetHeightButton?.isHidden = true
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
            panel.alphaValue = AppSettings.shared.idleOpacity   // reset para show()

            let width: CGFloat = newValue ? 78 : 280
            self.suppressPositionSave = true
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - width - 16
                let topY = screen.visibleFrame.maxY - 60
                panel.setFrame(NSRect(x: x, y: topY - panel.frame.height, width: width, height: panel.frame.height),
                               display: true, animate: false)
            }
            self.suppressPositionSave = false
            self.adjustPanelHeight()
            self.titleLabel?.stringValue = newValue ? "md" : "megadesk"
            self.titleLabel?.sizeToFit()
            if let label = self.titleLabel, let superview = label.superview {
                label.frame.origin.x = (superview.bounds.width - label.frame.width) / 2
            }

            self.show()   // fade-in reutilizando la animación existente
        }
    }

    private func adjustPanelHeight() {
        guard !isLiveResizing else { return }
        guard let panel = window else { return }

        let screenMax: CGFloat
        if let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let panelTopY = panel.frame.origin.y + panel.frame.height
            screenMax = panelTopY - visibleFrame.origin.y - 8
        } else {
            screenMax = 800
        }

        let targetHeight: CGFloat
        if let fixedHeight = userSetHeight {
            // Height is user-locked: respect it, only clamp to screen bounds
            targetHeight = max(120, min(fixedHeight, screenMax))
        } else {
            // Auto-height: content + footer + titlebar safe-area inset.
            // The VStack inside the hosting view has its usable height reduced by the
            // safe-area inset (≈28pt for the titlebar), so the panel frame must be
            // contentHeight + footerHeight + safeTop to fit without clipping the footer.
            let contentHeight = heightReporter.contentHeight
            guard contentHeight > 0 else { return }
            let safeTop = panel.contentView?.safeAreaInsets.top ?? 0
            targetHeight = max(120, min(contentHeight + heightReporter.footerHeight + safeTop, screenMax))
        }

        let topLeft = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + panel.frame.height)
        let newFrame = NSRect(x: topLeft.x, y: topLeft.y - targetHeight,
                              width: panel.frame.width, height: targetHeight)
        suppressPositionSave = true
        panel.setFrame(newFrame, display: true, animate: false)
        suppressPositionSave = false
        lastKnownHeight = targetHeight
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
                window.animator().alphaValue = AppSettings.shared.idleOpacity
            }
        } else {
            window.orderFrontRegardless()
        }
        adjustPanelHeight()
    }

    func hide() {
        guard let window = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = AppSettings.shared.idleOpacity
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
