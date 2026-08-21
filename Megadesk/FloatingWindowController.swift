import AppKit
import SwiftUI

/// NSHostingView subclass that accepts the first mouse-down event so that
/// clicks on the floating panel fire immediately without first activating the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// SwiftUI's default `windowDidLayout` implementation reacts to window
    /// layout notifications by calling `updateAnimatedWindowSize(_:)`, which
    /// invokes `window.setFrame(...)` with content height + ~21pt title-bar
    /// padding. Combined with `.titled + .fullSizeContentView` that extra
    /// 21pt is unwanted: after every user live-resize the panel would grow
    /// that much from the bottom (top pinned). Overriding this selector as
    /// a no-op stops the auto-resize without affecting layout/rendering.
    @objc func windowDidLayout() {
        // Intentionally empty.
    }
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
/// Also serves the context menu (right-click) on the panel background.
private final class EditablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu, let contentView else { return super.rightMouseDown(with: event) }
        // Only show the panel menu on empty background — not on cards/PRs
        // (those will get their own context menus later).
        let loc = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(loc)
        // If the click landed on the hosting view itself (background), show the menu.
        // If it landed on a subview (card content), let it handle the event.
        if hitView === contentView || hitView == nil {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// Live window-frame metrics shared with SwiftUI views. Updated on every
/// didResize (including during live resize) so layout decisions that depend
/// on the panel's current height reflow in real time while the user drags.
@Observable
final class WidgetWindowMetrics {
    static let shared = WidgetWindowMetrics()
    var currentHeight: CGFloat = 0
    private init() {}
}

extension Notification.Name {
    static let megadeskHideWidget    = Notification.Name("megadesk.hideWidget")
    static let megadeskFocusSession  = Notification.Name("megadesk.focusSession")
    static let megadeskCycleSession  = Notification.Name("megadesk.cycleSession")
    static let megadeskOpenContextSave = Notification.Name("megadesk.openContextSave")
    static let megadeskShowAlerts = Notification.Name("megadesk.showAlerts")
    static let megadeskCompanionBubbleChanged = Notification.Name("megadesk.companion.bubbleChanged")
    static let megadeskCompanionContentResized = Notification.Name("megadesk.companion.contentResized")
}

final class FloatingWindowController: NSWindowController {

    private var titleLabel: NSTextField?
    private var suppressPositionSave = false
    private var isHovered = false
    private var edgeDodger: EdgeDodger?
    private var heightReporter = HeightReporter()
    private var userSetHeight: CGFloat? = nil  // nil = auto-height; non-nil = user-locked
    private var lastKnownHeight: CGFloat = 120 // tracks last applied height to detect real user changes
    private var isAdjustingHeight = false       // prevents re-entrant adjustPanelHeight calls
    private var heightAdjustWorkItem: DispatchWorkItem?
    private var resetHeightButton: NSButton?
    private var gearButton: TitlebarGearButton?
    private var alertButton: TitlebarIconButton?
    private var contextNoteButton: TitlebarIconButton?
    private var quickAlertPopover: NSPopover?
    private var isLiveResizing = false
    // Height captured when a live resize begins — used to decide at the end
    // of the drag whether the user actually changed the height (vs. dragging
    // only a side edge). The height lock is applied ONLY at didEndLiveResize,
    // never on intermediate didResize notifications, to avoid misinterpreting
    // system-triggered or programmatic resizes as user input.
    private var heightAtLiveResizeStart: CGFloat?

    // MARK: - Peek tab state
    //
    // A separate lightweight action from hide(): instead of removing the widget
    // entirely (⌘⇧M), collapse it to a tab flush against the screen edge (⌘⇧L)
    // that always stays visible — so it can't be forgotten. Clicking the tab
    // (or pressing ⌘⇧L again) restores the widget.
    private enum DisplayState { case expanded, peeked, hidden }
    private var displayState: DisplayState = .expanded
    private var peekPanel: NSPanel?
    private let peekTabWidth: CGFloat = 24
    private let peekTabHeight: CGFloat = 116
    private let peekTabInteractiveWidth: CGFloat = 34
    /// The style the cached peek panel was built for; rebuilt when it changes.
    private var peekPanelStyle: PeekTabStyle?
    /// Borderless panel that shows a session/PR/alert card as the hover tooltip
    /// for the interactive peek tab (own opaque background + corner, unlike a
    /// system popover).
    private var peekTooltipPanel: NSPanel?

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
        // Opaque background — overall translucency is controlled by the
        // window's alphaValue (the "Widget opacity" setting), so at 100% the
        // widget is fully opaque and only becomes see-through below 100%.
        panel.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
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
            self?.scheduleHeightAdjust()
        }

        let savedH = UserDefaults.standard.double(forKey: "megadesk.windowHeight")
        if savedH > 0 { self.userSetHeight = CGFloat(savedH) }

        // Seed the live metric so SwiftUI has a sensible value on first render,
        // before the first didResize fires.
        WidgetWindowMetrics.shared.currentHeight = panel.frame.height

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
        ) { [weak self] _ in
            self?.isLiveResizing = true
            self?.heightAtLiveResizeStart = panel.frame.height
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isLiveResizing = false
            // Commit the user-chosen height only if the drag actually changed
            // height (a pure width drag leaves userSetHeight alone).
            if let startH = self.heightAtLiveResizeStart,
               abs(panel.frame.height - startH) > 1 {
                self.userSetHeight = panel.frame.height
                UserDefaults.standard.set(Double(panel.frame.height), forKey: "megadesk.windowHeight")
                self.resetHeightButton?.isHidden = false
            }
            self.heightAtLiveResizeStart = nil
            self.lastKnownHeight = panel.frame.height
        }
    }

    // MARK: - Edge dodge (move out of the mouse's way)

    /// Creates the dodger on first use and starts/stops it to match the setting.
    /// Called at launch and whenever `edgeDodgeEnabled` changes. Only dodges
    /// while the widget is expanded and visible (not collapsed to the peek tab).
    func updateEdgeDodge() {
        if edgeDodger == nil {
            let dodger = EdgeDodger(window: window)
            dodger.shouldApply = { [weak self] in
                guard let self, let window = self.window else { return false }
                return AppSettings.shared.edgeDodgeEnabled
                    && self.displayState == .expanded
                    && window.isVisible
            }
            dodger.bypassFlags = { AppSettings.shared.edgeDodgeBypassModifier.flag }
            dodger.setSuppressSave = { [weak self] in self?.suppressPositionSave = $0 }
            edgeDodger = dodger
        }
        if AppSettings.shared.edgeDodgeEnabled {
            edgeDodger?.start()
        } else {
            edgeDodger?.stop()
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

        // Yellow peek button — collapse the widget to the edge tab (⌘⇧L)
        let peekFrame = NSRect(
            x: sysClose.frame.midX - size / 2 + 20,
            y: sysClose.frame.midY - size / 2,
            width: size, height: size
        )
        let peekBtn = TitlebarPeekButton(frame: peekFrame)
        peekBtn.target = self
        peekBtn.action = #selector(peekButtonPressed)
        peekBtn.toolTip = "Collapse to edge tab"
        titlebarView.addSubview(peekBtn)

        // Green reset button — traffic-light position to the right of the yellow button
        let resetFrame = NSRect(
            x: sysClose.frame.midX - size / 2 + 40,
            y: sysClose.frame.midY - size / 2,
            width: size, height: size
        )
        let resetBtn = TitlebarResetButton(frame: resetFrame)
        resetBtn.target = self
        resetBtn.action = #selector(resetToAutoHeightAction)
        resetBtn.isHidden = (userSetHeight == nil)
        titlebarView.addSubview(resetBtn)
        self.resetHeightButton = resetBtn

        // Gear button — right side of the titlebar, opens the app menu
        let gearSize: CGFloat = 18
        let gearFrame = NSRect(
            x: titlebarView.bounds.width - gearSize - 10,
            y: sysClose.frame.midY - gearSize / 2,
            width: gearSize, height: gearSize
        )
        let gear = TitlebarGearButton(frame: gearFrame)
        gear.autoresizingMask = [.minXMargin]  // stay pinned to the right edge
        gear.target = self
        gear.action = #selector(gearPressed(_:))
        titlebarView.addSubview(gear)
        self.gearButton = gear

        // Alert button — to the left of the gear button
        let alertFrame = NSRect(
            x: titlebarView.bounds.width - gearSize * 2 - 14,
            y: sysClose.frame.midY - gearSize / 2,
            width: gearSize, height: gearSize
        )
        let alertBtn = TitlebarIconButton(frame: alertFrame, symbolName: "bell.fill", label: "Alerts")
        alertBtn.autoresizingMask = [.minXMargin]
        alertBtn.target = self
        alertBtn.action = #selector(alertButtonPressed)
        titlebarView.addSubview(alertBtn)
        self.alertButton = alertBtn

        // Context note button — to the left of the alert button, hidden in compact mode
        if !compact {
            let contextFrame = NSRect(
                x: titlebarView.bounds.width - gearSize * 3 - 18,
                y: sysClose.frame.midY - gearSize / 2,
                width: gearSize, height: gearSize
            )
            let contextBtn = TitlebarIconButton(frame: contextFrame, symbolName: "note.text", label: "Context Note")
            contextBtn.autoresizingMask = [.minXMargin]
            contextBtn.target = self
            contextBtn.action = #selector(contextNoteButtonPressed)
            titlebarView.addSubview(contextBtn)
            self.contextNoteButton = contextBtn
        }
    }

    @objc private func gearPressed(_ sender: NSButton) {
        guard let menu = window?.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func alertButtonPressed() {
        showQuickAlert()
    }

    @objc private func contextNoteButtonPressed() {
        NotificationCenter.default.post(name: .megadeskOpenContextSave, object: nil)
    }

    func showQuickAlert() {
        if let popover = quickAlertPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let anchor = alertButton else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 100)
        popover.contentViewController = NSHostingController(rootView: QuickAlertView {
            popover.performClose(nil)
        })
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        quickAlertPopover = popover
    }

    /// Sets the menu used by the gear button and right-click context menu.
    func setMenu(_ menu: NSMenu) {
        window?.menu = menu
    }

    @objc private func customClosePressed() {
        hide()
    }

    @objc private func peekButtonPressed() {
        togglePeek()
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
        // Height locking happens exclusively at didEndLiveResize — this
        // handler just tracks the current height for other logic.
        lastKnownHeight = panel.frame.height
        WidgetWindowMetrics.shared.currentHeight = panel.frame.height
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

            let savedWidth = UserDefaults.standard.double(forKey: "megadesk.windowWidth")
            let normalWidth: CGFloat = savedWidth > 0 ? max(220, min(280, CGFloat(savedWidth))) : 280
            let width: CGFloat = newValue ? 78 : normalWidth
            // Pin width so SwiftUI layout cannot oscillate it
            panel.minSize = NSSize(width: width, height: 120)
            panel.maxSize = NSSize(width: width, height: NSScreen.main?.frame.height ?? 2000)
            self.suppressPositionSave = true
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - width - 16
                let topY = screen.visibleFrame.maxY - 60
                panel.setFrame(NSRect(x: x, y: topY - panel.frame.height, width: width, height: panel.frame.height),
                               display: true, animate: false)
            }
            self.suppressPositionSave = false
            self.adjustPanelHeight()
            // Re-enable user resizing in normal mode
            if !newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    panel.minSize = NSSize(width: 220, height: 120)
                    panel.maxSize = NSSize(width: 280, height: NSScreen.main?.frame.height ?? 2000)
                }
            }
            self.titleLabel?.stringValue = newValue ? "md" : "megadesk"
            self.titleLabel?.sizeToFit()
            if let label = self.titleLabel, let superview = label.superview {
                label.frame.origin.x = (superview.bounds.width - label.frame.width) / 2
            }

            self.show()   // fade-in reutilizando la animación existente
        }
    }

    private func scheduleHeightAdjust() {
        heightAdjustWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.adjustPanelHeight() }
        heightAdjustWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func adjustPanelHeight() {
        guard !isLiveResizing, !isAdjustingHeight else { return }
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
            targetHeight = max(120, min(fixedHeight, screenMax))
        } else {
            let contentHeight = heightReporter.contentHeight
            guard contentHeight > 0 else { return }
            let safeTop = panel.contentView?.safeAreaInsets.top ?? 0
            targetHeight = max(120, min(contentHeight + heightReporter.footerHeight + safeTop, screenMax))
        }

        // Skip if the height barely changed — prevents oscillation from
        // measurement jitter after mode switches or layout recalculations.
        guard abs(targetHeight - panel.frame.height) > 2 else { return }

        isAdjustingHeight = true
        // Keep top-left fixed — widget grows downward when content grows.
        let topLeft = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + panel.frame.height)
        let newFrame = NSRect(x: topLeft.x, y: topLeft.y - targetHeight,
                              width: panel.frame.width, height: targetHeight)
        suppressPositionSave = true
        panel.setFrame(newFrame, display: true, animate: false)
        suppressPositionSave = false
        lastKnownHeight = targetHeight
        isAdjustingHeight = false
    }

    func show() {
        guard let window = window else { return }
        dismissPeekPanel()
        displayState = .expanded
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
        dismissPeekPanel()
        displayState = .hidden
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

    // MARK: - Peek tab

    /// ⌘⇧L: collapse the widget to an edge tab, or expand it back.
    func togglePeek() {
        switch displayState {
        case .peeked:
            show()   // dismisses the peek tab and restores the widget
        case .expanded, .hidden:
            collapseToPeek()
        }
    }

    private func collapseToPeek() {
        guard let panel = window else { return }
        let screen = panel.screen ?? NSScreen.main
        let topY = panel.frame.maxY
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = AppSettings.shared.idleOpacity
        })
        showPeekPanel(topY: topY, screen: screen)
        displayState = .peeked
        observePeekSize()
    }

    private var peekPanelWidth: CGFloat {
        AppSettings.shared.peekTabStyle == .interactive ? peekTabInteractiveWidth : peekTabWidth
    }

    /// Interactive tab height: header chevron + one fixed slot per session/PR/
    /// alert + separators between groups. Compact stays a fixed size.
    private func peekPanelHeight() -> CGFloat {
        guard AppSettings.shared.peekTabStyle == .interactive else { return peekTabHeight }
        let store = StatusStore.shared
        let sessions = store.sessions.count
        let prs = store.trackedPRs.count
        let alerts = store.alerts.filter {
            store.alertShowsInWidget($0) && store.firedAlertIds.contains($0.id)
                && !store.dismissedFiredAlertIds.contains($0.id)
        }.count
        let items = sessions + prs + alerts
        let groups = [alerts, sessions, prs].filter { $0 > 0 }.count
        let separators = max(0, groups - 1)
        let slotH = CGFloat(AppSettings.shared.peekSlotHeight)
        let sepH: CGFloat = 1, chevronH: CGFloat = 16, mdH: CGFloat = 15
        let gap: CGFloat = 3, padV: CGFloat = 9
        // VStack elements: md label + chevron + items + separators.
        let gaps = max(0, (2 + items + separators) - 1)
        let content = mdH + chevronH
            + CGFloat(items) * slotH
            + CGFloat(separators) * sepH
            + CGFloat(gaps) * gap
        return max(56, padV * 2 + content)
    }

    private func showPeekPanel(topY: CGFloat, screen: NSScreen?) {
        let s = screen ?? NSScreen.main
        let w = peekPanelWidth
        let h = peekPanelHeight()
        // Flush against the right screen edge (no gap).
        let x = (s?.visibleFrame.maxX ?? w) - w
        let panel = ensurePeekPanel()
        panel.setFrame(NSRect(x: x, y: topY - h, width: w, height: h), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1.0
        }
    }

    /// Re-applies the interactive tab's height when its item count changes,
    /// keeping the top edge anchored.
    private func resizePeekPanel() {
        guard let p = peekPanel, p.isVisible,
              AppSettings.shared.peekTabStyle == .interactive else { return }
        let topY = p.frame.maxY
        let h = peekPanelHeight()
        guard abs(h - p.frame.height) > 0.5 else { return }
        p.setFrame(NSRect(x: p.frame.origin.x, y: topY - h, width: p.frame.width, height: h), display: true)
    }

    private func observePeekSize() {
        guard displayState == .peeked, AppSettings.shared.peekTabStyle == .interactive else { return }
        withObservationTracking {
            let store = StatusStore.shared
            _ = store.sessions.count
            _ = store.trackedPRs.count
            _ = store.alerts.count
            _ = store.firedAlertIds.count
            _ = store.dismissedFiredAlertIds.count
            _ = AppSettings.shared.peekSlotHeight
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.displayState == .peeked else { return }
                self.resizePeekPanel()
                self.observePeekSize()
            }
        }
    }

    /// Shows the hover card for the interactive peek tab, positioned to the
    /// left of the hovered slot. `slotWindowRect` is the slot's frame in the
    /// peek panel's window coordinates (top-left origin).
    func showPeekTooltip(_ view: AnyView, slotWindowRect: CGRect) {
        guard let peek = peekPanel, peek.isVisible else { return }
        let panel = peekTooltipPanel ?? {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            peekTooltipPanel = p
            return p
        }()
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        // Convert the slot's window rect (top-left origin) to screen coords.
        let slotScreenX = peek.frame.minX + slotWindowRect.minX
        let slotBottom = peek.frame.maxY - slotWindowRect.maxY
        let slotMidY = slotBottom + slotWindowRect.height / 2
        let x = slotScreenX - size.width - 8
        let y = slotMidY - size.height / 2
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFront(nil)   // instant — no popover fade
    }

    func hidePeekTooltip() {
        peekTooltipPanel?.orderOut(nil)
    }

    private func dismissPeekPanel() {
        hidePeekTooltip()
        guard let p = peekPanel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            p.animator().alphaValue = 0.0
        }, completionHandler: {
            p.orderOut(nil)
            p.alphaValue = 1.0
        })
    }

    private func ensurePeekPanel() -> NSPanel {
        let style = AppSettings.shared.peekTabStyle
        if let p = peekPanel, peekPanelStyle == style { return p }

        let p = peekPanel ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: peekPanelWidth, height: peekTabHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content: NSView
        switch style {
        case .compact:
            let tab = PeekTabNSView(frame: .zero)
            tab.onClick = { [weak self] in self?.show() }
            let hosting = NSHostingView(rootView: PeekTabView())
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = p.contentLayoutRect
            tab.addSubview(hosting)
            content = tab
        case .interactive:
            content = FirstMouseHostingView(rootView:
                PeekTabInteractiveView(
                    onExpand: { [weak self] in self?.show() },
                    showTooltip: { [weak self] view, rect in self?.showPeekTooltip(view, slotWindowRect: rect) },
                    hideTooltip: { [weak self] in self?.hidePeekTooltip() }
                )
            )
        }
        p.contentView = content
        peekPanel = p
        peekPanelStyle = style
        return p
    }
}

// MARK: - TitlebarCloseButton

/// An NSButton that draws as a green circle (reset to auto-height), with a ↕ icon on hover.
private final class TitlebarResetButton: NSButton {

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
        NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        if isHovered {
            // Draw a ↕ symbol: two small arrow heads pointing up and down
            NSColor.black.withAlphaComponent(0.55).setStroke()
            NSColor.black.withAlphaComponent(0.55).setFill()
            let cx = bounds.midX
            let cy = bounds.midY
            let aw: CGFloat = bounds.width * 0.30  // arrow half-width
            let ah: CGFloat = bounds.height * 0.22  // arrow head height
            let gap: CGFloat = bounds.height * 0.06 // gap from center

            // Up arrow
            let upTip = NSPoint(x: cx, y: cy + gap + ah + ah * 0.5)
            let upLeft = NSPoint(x: cx - aw, y: cy + gap + ah * 0.5)
            let upRight = NSPoint(x: cx + aw, y: cy + gap + ah * 0.5)
            let upPath = NSBezierPath()
            upPath.move(to: upTip); upPath.line(to: upLeft); upPath.line(to: upRight)
            upPath.close(); upPath.fill()

            // Down arrow
            let dnTip = NSPoint(x: cx, y: cy - gap - ah - ah * 0.5)
            let dnLeft = NSPoint(x: cx - aw, y: cy - gap - ah * 0.5)
            let dnRight = NSPoint(x: cx + aw, y: cy - gap - ah * 0.5)
            let dnPath = NSBezierPath()
            dnPath.move(to: dnTip); dnPath.line(to: dnLeft); dnPath.line(to: dnRight)
            dnPath.close(); dnPath.fill()
        }
    }
}

/// An NSButton that draws a gear icon, visible on hover.
private final class TitlebarGearButton: NSButton {

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
        let alpha: CGFloat = isHovered ? 0.85 : 0.35
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: bounds.height * 0.7, weight: .medium)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)])
        let config = sizeConfig.applying(colorConfig)
        if let image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(config) {
            let imageSize = image.size
            let x = (bounds.width - imageSize.width) / 2
            let y = (bounds.height - imageSize.height) / 2
            image.draw(in: NSRect(x: x, y: y, width: imageSize.width, height: imageSize.height))
        }
    }
}

/// A reusable titlebar icon button that draws an SF Symbol, visible on hover.
private final class TitlebarIconButton: NSButton {

    private let symbolName: String
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, symbolName: String, label: String) {
        self.symbolName = symbolName
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .circular
        title = ""
        toolTip = label
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent)  { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isHovered ? 0.85 : 0.35
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: bounds.height * 0.6, weight: .medium)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)])
        let config = sizeConfig.applying(colorConfig)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config) {
            let imageSize = image.size
            let x = (bounds.width - imageSize.width) / 2
            let y = (bounds.height - imageSize.height) / 2
            image.draw(in: NSRect(x: x, y: y, width: imageSize.width, height: imageSize.height))
        }
    }
}

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

/// An NSButton that always draws as a yellow circle, with a › chevron on hover
/// (collapse the widget to the edge tab).
private final class TitlebarPeekButton: NSButton {

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
        NSColor(red: 0.98, green: 0.74, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        if isHovered {
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath()
            let midY = bounds.midY
            let x0 = bounds.width * 0.40
            let x1 = bounds.width * 0.62
            let dy = bounds.height * 0.16
            path.move(to: NSPoint(x: x0, y: midY + dy))
            path.line(to: NSPoint(x: x1, y: midY))
            path.line(to: NSPoint(x: x0, y: midY - dy))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}

// MARK: - Peek tab

/// The edge tab shown while the widget is collapsed (⌘⇧L). Forwards clicks to
/// the controller; hosts the SwiftUI content.
private final class PeekTabNSView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Collects each interactive slot's frame (window coords) so the controller
/// can anchor the hover tooltip panel to it.
private struct SlotRectKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Interactive collapsed tab: a chevron button that expands the widget, then
/// one fixed-height clickable slot per widget item (alerts, sessions, PRs).
/// Clicking a slot performs its action (focus tab / open PR / open alerts);
/// hovering shows the item's card as a tooltip.
private struct PeekTabInteractiveView: View {
    @State private var store = StatusStore.shared
    @State private var hoverScaleID: String?        // drives the instant hover scale
    @State private var chevronHover = false
    @State private var hoverWork: DispatchWorkItem?
    @State private var slotRects: [String: CGRect] = [:]
    let onExpand: () -> Void
    let showTooltip: (AnyView, CGRect) -> Void
    let hideTooltip: () -> Void

    /// The real card for a slot, shown as the hover tooltip.
    @ViewBuilder private func cardView(for slot: Slot) -> some View {
        switch slot {
        case .session(let s):
            SessionCardView(
                session: s,
                tick: store.tick,
                spinnerTick: store.spinnerTick,
                displayName: store.displayName(for: s),
                hasCustomName: store.hasCustomName(for: s),
                isFlashing: false,
                toolDetail: store.toolDetail(for: s),
                spinnerInfo: store.spinnerInfo(for: s),
                onFocus: { store.focusTerminal(session: s) },
                onRename: { _ in },
                onEditStart: {},
                onEditEnd: {}
            )
            .frame(width: 250)
        case .pr(let t):
            PRCardView(trackedPR: t, onRefresh: {}, onRemove: {})
                .frame(width: 250)
        case .alert(let a):
            AlertCardView(alert: a, isCompact: false)
                .frame(width: 250)
        case .separator:
            EmptyView()
        }
    }

    /// The card wrapped with an opaque backing + a moderate corner, so it
    /// isn't translucent and isn't as rounded as a system popover.
    private func tooltipContent(for slot: Slot) -> some View {
        cardView(for: slot)
            .background(Color(white: 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func scheduleHover(_ slot: Slot) {
        hoverWork?.cancel()
        let item = DispatchWorkItem {
            guard let rect = slotRects[slot.id] else { return }
            showTooltip(AnyView(tooltipContent(for: slot)), rect)
        }
        hoverWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func endHover(_ slot: Slot) {
        hoverWork?.cancel()
        hideTooltip()
    }

    private enum Slot: Identifiable {
        case session(Session)
        case pr(TrackedPR)
        case alert(MegadeskAlert)
        case separator(Int)

        var id: String {
            switch self {
            case .session(let s):   return "s-\(s.id)"
            case .pr(let p):        return "p-\(p.id)"
            case .alert(let a):     return "a-\(a.id)"
            case .separator(let i): return "sep-\(i)"
            }
        }
    }

    private var slots: [Slot] {
        let s = store.sessions
        let working      = s.filter { $0.isWorking && !$0.needsConfirmation }
        let confirmation = s.filter { $0.needsConfirmation }
        let waiting      = s.filter { !$0.isWorking && !$0.isForgotten }
        let forgotten    = s.filter { !$0.isWorking && $0.isForgotten }
        let sessionSlots = (working + confirmation + waiting + forgotten).map(Slot.session)
        let alertSlots = store.alerts.filter {
            store.alertShowsInWidget($0) && store.firedAlertIds.contains($0.id)
                && !store.dismissedFiredAlertIds.contains($0.id)
        }.map(Slot.alert)
        let prSlots = store.trackedPRs.map(Slot.pr)

        let groups = [alertSlots, sessionSlots, prSlots].filter { !$0.isEmpty }
        var result: [Slot] = []
        for (i, group) in groups.enumerated() {
            if i > 0 { result.append(.separator(i)) }
            result.append(contentsOf: group)
        }
        return result
    }

    private func color(for slot: Slot) -> Color {
        let set = AppSettings.shared
        switch slot {
        case .session(let s):
            if s.needsConfirmation { return set.colorConfirmation }
            if s.isWorking         { return set.colorWorking }
            if s.isForgotten       { return set.colorForgotten }
            return set.colorWaiting
        case .pr(let t):
            guard let pr = t.data else { return set.colorPRClosed }
            if pr.isMerged { return set.colorPRMerged }
            if pr.isClosed { return set.colorPRClosed }
            switch pr.ciStatus {
            case .failing: return set.colorPRFailing
            case .pending: return set.colorPRPending
            case .passing: return set.colorPRPassing
            case .none:    return set.colorPRClosed
            }
        case .alert:     return set.colorAlert
        case .separator: return .clear
        }
    }

    /// Horizontal gradient of the slot color — softer / less flat than a solid fill.
    private func gradient(for slot: Slot) -> LinearGradient {
        let c = color(for: slot)
        return LinearGradient(
            colors: [c.opacity(0.95), c.opacity(0.55)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// True for the slot of the currently selected/focused session.
    private func isSelected(_ slot: Slot) -> Bool {
        if case .session(let s) = slot { return store.activeSessionId == s.sessionId }
        return false
    }

    private func tooltip(for slot: Slot) -> String {
        switch slot {
        case .session(let s): return store.displayName(for: s)
        case .pr(let t):      return t.data?.title ?? t.id
        case .alert(let a):   return a.title
        case .separator:      return ""
        }
    }

    private func activate(_ slot: Slot) {
        switch slot {
        case .session(let s):
            store.focusTerminal(session: s)
        case .pr(let t):
            if let raw = t.data?.url, let url = URL(string: raw) { NSWorkspace.shared.open(url) }
        case .alert:
            NotificationCenter.default.post(name: .megadeskShowAlerts, object: nil)
        case .separator:
            break
        }
    }

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 10,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        )
        .fill(Color(white: 0.12).opacity(0.98))
        .overlay {
            VStack(spacing: 3) {
                Text("md")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Button(action: onExpand) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(chevronHover ? 0.9 : 0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .scaleEffect(chevronHover ? 1.2 : 1.0)
                .animation(.easeOut(duration: 0.1), value: chevronHover)
                .onHover { chevronHover = $0 }
                .help("Expand widget")

                ForEach(slots) { slot in
                    if case .separator = slot {
                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 1)
                            .padding(.horizontal, 3)
                    } else {
                        Button(action: { activate(slot) }) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(gradient(for: slot))
                                .frame(height: CGFloat(AppSettings.shared.peekSlotHeight))
                                .overlay {
                                    if isSelected(slot) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: SlotRectKey.self,
                                value: [slot.id: geo.frame(in: .global)]
                            )
                        })
                        .scaleEffect(hoverScaleID == slot.id ? 1.14 : 1.0)
                        .animation(.easeOut(duration: 0.1), value: hoverScaleID)
                        .onHover { hovering in
                            if hovering {
                                hoverScaleID = slot.id
                                scheduleHover(slot)
                            } else {
                                if hoverScaleID == slot.id { hoverScaleID = nil }
                                endHover(slot)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 9)
            .onPreferenceChange(SlotRectKey.self) { slotRects = $0 }
        }
    }
}

/// Content of the collapsed edge tab: a stub flush against the screen edge
/// (only the inner corners are rounded) holding a vertical bar with one slot
/// per session, colored by state — mirroring the session-summary bar. A faint
/// dot is shown when there are no sessions.
private struct PeekTabView: View {
    @State private var store = StatusStore.shared

    // One color slot per widget item, in the widget's top-to-bottom order:
    // alerts, then sessions, then pull requests — each group split by a rule.

    /// Sessions grouped by state (working → confirmation → waiting → forgotten),
    /// matching the session-summary bar's color mapping.
    private var sessionColors: [Color] {
        let s = store.sessions
        let set = AppSettings.shared
        let working      = s.filter { $0.isWorking && !$0.needsConfirmation }
        let confirmation = s.filter { $0.needsConfirmation }
        let waiting      = s.filter { !$0.isWorking && !$0.isForgotten }
        let forgotten    = s.filter { !$0.isWorking && $0.isForgotten }
        return working.map { _ in set.colorWorking }
            + confirmation.map { _ in set.colorConfirmation }
            + waiting.map { _ in set.colorWaiting }
            + forgotten.map { _ in set.colorForgotten }
    }

    /// Fired, not-yet-dismissed alerts that show in the widget.
    private var alertColors: [Color] {
        let set = AppSettings.shared
        return store.alerts
            .filter { store.alertShowsInWidget($0)
                && store.firedAlertIds.contains($0.id)
                && !store.dismissedFiredAlertIds.contains($0.id) }
            .map { _ in set.colorAlert }
    }

    /// Tracked PRs, colored by CI/merge state (mirrors PRCardView).
    private var prColors: [Color] {
        store.trackedPRs.map(prColor)
    }

    private func prColor(_ tracked: TrackedPR) -> Color {
        let set = AppSettings.shared
        guard let pr = tracked.data else { return set.colorPRClosed }
        if pr.isMerged { return set.colorPRMerged }
        if pr.isClosed { return set.colorPRClosed }
        switch pr.ciStatus {
        case .failing: return set.colorPRFailing
        case .pending: return set.colorPRPending
        case .passing: return set.colorPRPassing
        case .none:    return set.colorPRClosed
        }
    }

    /// Flattened slots with a separator between each non-empty group, so every
    /// slot shares the available height equally regardless of its group.
    private var entries: [(isSeparator: Bool, color: Color)] {
        let groups = [alertColors, sessionColors, prColors].filter { !$0.isEmpty }
        var result: [(Bool, Color)] = []
        for (i, group) in groups.enumerated() {
            if i > 0 { result.append((true, .clear)) }
            result.append(contentsOf: group.map { (false, $0) })
        }
        return result.map { (isSeparator: $0.0, color: $0.1) }
    }

    var body: some View {
        let items = entries
        UnevenRoundedRectangle(
            topLeadingRadius: 10,
            bottomLeadingRadius: 10,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        )
        .fill(Color(white: 0.12).opacity(0.98))
        .overlay {
            VStack(spacing: 4) {
                Text("md")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                if items.isEmpty {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 6, height: 6)
                    Spacer(minLength: 0)
                } else {
                    VStack(spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            if item.isSeparator {
                                Rectangle()
                                    .fill(Color.white.opacity(0.18))
                                    .frame(width: 14, height: 1)
                            } else {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(item.color)
                                    .frame(width: 12)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.top, 7)
            .padding(.bottom, 9)
        }
    }
}
