import AppKit

extension Notification.Name {
    /// Posted whenever the toast stack grows or shrinks, so anything that
    /// stacks alongside it (the companion-style task reminder) can move out of
    /// the way instead of landing on top.
    static let megadeskToastStackChanged = Notification.Name("megadesk.toastStackChanged")
}

/// What a toast belongs to. Alerts and task reminders share the panel, the
/// snooze and the settle round-trip, but each settles against its own store.
enum ToastOwner: Equatable {
    case alert(UUID)
    case task(UUID)
}

final class ToastWindowController {
    static let shared = ToastWindowController()

    private var activeToasts: [(panel: NSPanel, toastId: UUID, owner: ToastOwner)] = []
    private let toastWidth: CGFloat = 280
    private let toastHeight: CGFloat = 90
    private let spacing: CGFloat = 8
    private let margin: CGFloat = 16

    /// How many toasts are stacked right now. The companion-style task
    /// reminder reads it so it doesn't land on top of one.
    var activeToastCount: Int { activeToasts.count }

    func showToast(for alert: MegadeskAlert) {
        let panel = makePanel()

        let toastId = UUID()
        let snoozeMinutes = AppSettings.shared.snoozeMinutes
        let contentView = ToastContentView(
            title: alert.title,
            time: Self.timeString(),
            iconSymbol: "bell.fill",
            iconLabel: "Alert",
            snoozeMinutes: snoozeMinutes,
            secondaryTitle: "Disable",
            showMoveToWidget: true,
            onClose: { [weak self] in
                self?.dismissToast(toastId: toastId)
            },
            // Closing the toast used to be all the X did, leaving the alert
            // pending forever. Dismissing settles it.
            onDismiss: {
                StatusStore.shared.dismissFiredAlert(id: alert.id)
            },
            onMoveToWidget: {
                StatusStore.shared.moveAlertToWidget(id: alert.id)
            },
            onSnooze: {
                NotificationCenter.default.post(name: .megadeskSnoozeAlert, object: nil,
                                                userInfo: ["alertId": alert.id, "minutes": snoozeMinutes])
            },
            onSecondary: {
                StatusStore.shared.toggleAlert(id: alert.id, enabled: false)
                StatusStore.shared.dismissFiredAlert(id: alert.id)
            }
        )
        panel.contentView = contentView

        // Round the content view corners now that it's attached to the panel
        if let cv = panel.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = 12
            cv.layer?.masksToBounds = true
        }

        let origin = toastOrigin(index: activeToasts.count)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        activeToasts.append((panel: panel, toastId: toastId, owner: .alert(alert.id)))
        notifyStackChanged()
    }

    /// A task reminder takes the same panel, the same snooze and the same
    /// settle as an alert. Only two things differ: it settles against the task
    /// store, and its second button completes the task instead of disabling a
    /// schedule — which is also what stops a repeating reminder for good.
    func showToast(for task: MegadeskTask) {
        // One panel per task: a repeating reminder coming back around replaces
        // its own toast instead of stacking copies of itself until they walk
        // off the screen — and so that settling the task takes every panel it
        // has with it. Same rule the companion-style reminder follows.
        if let index = activeToasts.firstIndex(where: { $0.owner == .task(task.id) }) {
            activeToasts.remove(at: index).panel.orderOut(nil)
        }

        let panel = makePanel()

        let toastId = UUID()
        let snoozeMinutes = AppSettings.shared.snoozeMinutes
        let taskId = task.id
        let contentView = ToastContentView(
            title: task.title,
            time: Self.timeString(),
            iconSymbol: "checklist",
            iconLabel: "Task reminder",
            snoozeMinutes: snoozeMinutes,
            secondaryTitle: "Complete",
            showMoveToWidget: false,
            onClose: { [weak self] in
                self?.dismissToast(toastId: toastId)
            },
            onDismiss: {
                TaskStore.shared.dismissFiredReminder(id: taskId)
            },
            onMoveToWidget: {},
            onSnooze: {
                NotificationCenter.default.post(name: .megadeskSnoozeTaskReminder, object: nil,
                                                userInfo: ["taskId": taskId, "minutes": snoozeMinutes])
            },
            onSecondary: {
                TaskStore.shared.setCompleted(id: taskId, true)
            }
        )
        panel.contentView = contentView

        if let cv = panel.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = 12
            cv.layer?.masksToBounds = true
        }

        panel.setFrameOrigin(toastOrigin(index: activeToasts.count))
        panel.orderFrontRegardless()

        activeToasts.append((panel: panel, toastId: toastId, owner: .task(taskId)))
        // A replaced toast left a gap in the stack; this closes it.
        repositionToasts()
        notifyStackChanged()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovableByWindowBackground = false
        return panel
    }

    func dismissToast(alertId: UUID) {
        dismissToast(owner: .alert(alertId))
    }

    func dismissToast(taskId: UUID) {
        dismissToast(owner: .task(taskId))
    }

    private func dismissToast(owner: ToastOwner) {
        guard let index = activeToasts.firstIndex(where: { $0.owner == owner }) else { return }
        animateDismiss(at: index)
    }

    /// Pulls every task reminder off the screen, leaving alert toasts alone.
    func dismissAllTaskToasts() {
        for entry in activeToasts.reversed() {
            guard case .task = entry.owner else { continue }
            guard let index = activeToasts.firstIndex(where: { $0.toastId == entry.toastId }) else { continue }
            animateDismiss(at: index)
        }
    }

    func dismissAll() {
        for entry in activeToasts { entry.panel.orderOut(nil) }
        activeToasts.removeAll()
        notifyStackChanged()
    }

    private func notifyStackChanged() {
        NotificationCenter.default.post(name: .megadeskToastStackChanged, object: nil)
    }

    private func dismissToast(toastId: UUID) {
        guard let index = activeToasts.firstIndex(where: { $0.toastId == toastId }) else { return }
        animateDismiss(at: index)
    }

    private func animateDismiss(at index: Int) {
        let panel = activeToasts[index].panel
        activeToasts.remove(at: index)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.repositionToasts()
        })
        notifyStackChanged()
    }

    private func toastOrigin(index: Int) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let visibleFrame = screen.visibleFrame
        let yOffset = CGFloat(index) * (toastHeight + spacing)

        switch AppSettings.shared.toastPosition {
        case .topRight:
            return NSPoint(
                x: visibleFrame.maxX - toastWidth - margin,
                y: visibleFrame.maxY - toastHeight - margin - yOffset
            )
        case .topCenter:
            return NSPoint(
                x: visibleFrame.midX - toastWidth / 2,
                y: visibleFrame.maxY - toastHeight - margin - yOffset
            )
        case .center:
            return NSPoint(
                x: visibleFrame.midX - toastWidth / 2,
                y: visibleFrame.midY - toastHeight / 2 + (toastHeight + spacing) / 2 - yOffset
            )
        }
    }

    private func repositionToasts() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (i, entry) in activeToasts.enumerated() {
                entry.panel.animator().setFrameOrigin(toastOrigin(index: i))
            }
        }
    }

    private static func timeString() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}

// MARK: - Hover-aware button with pill background

private final class ToastButton: NSView {
    private let label: NSTextField
    private let action: () -> Void
    private let normalColor: NSColor
    private let hoverBgColor: NSColor
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(title: String, color: NSColor, hoverBg: NSColor = NSColor(white: 0.25, alpha: 1), action: @escaping () -> Void) {
        self.action = action
        self.normalColor = color
        self.hoverBgColor = hoverBg
        self.label = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 4

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = hoverBgColor.cgColor
        label.textColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
        label.textColor = normalColor
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.35, alpha: 1).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            action()
        } else {
            layer?.backgroundColor = nil
            label.textColor = normalColor
        }
    }
}

// MARK: - Hover-aware dismiss (X) button

private final class ToastDismissButton: NSView {
    private let imageView: NSImageView
    private let action: () -> Void
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String = "xmark", tooltip: String? = nil, action: @escaping () -> Void) {
        self.action = action
        self.imageView = NSImageView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        toolTip = tooltip

        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip ?? "Dismiss")
        imageView.contentTintColor = NSColor(white: 0.5, alpha: 1)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 12),
            imageView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        imageView.contentTintColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
        imageView.contentTintColor = NSColor(white: 0.5, alpha: 1)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.35, alpha: 1).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { action() }
        else {
            layer?.backgroundColor = nil
            imageView.contentTintColor = NSColor(white: 0.5, alpha: 1)
        }
    }
}

// MARK: - Toast Content View

private final class ToastContentView: NSView {
    init(title: String, time: String, iconSymbol: String, iconLabel: String, snoozeMinutes: Int,
         secondaryTitle: String, showMoveToWidget: Bool,
         onClose: @escaping () -> Void, onDismiss: @escaping () -> Void,
         onMoveToWidget: @escaping () -> Void, onSnooze: @escaping () -> Void,
         onSecondary: @escaping () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
        setupUI(title: title, time: time, iconSymbol: iconSymbol, iconLabel: iconLabel, snoozeMinutes: snoozeMinutes,
                secondaryTitle: secondaryTitle, showMoveToWidget: showMoveToWidget,
                onClose: onClose, onDismiss: onDismiss, onMoveToWidget: onMoveToWidget,
                onSnooze: onSnooze, onSecondary: onSecondary)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(white: 0.1, alpha: 0.92).setFill()
        path.fill()
    }

    private func setupUI(title: String, time: String, iconSymbol: String, iconLabel: String, snoozeMinutes: Int,
                          secondaryTitle: String, showMoveToWidget: Bool,
                          onClose: @escaping () -> Void, onDismiss: @escaping () -> Void,
                          onMoveToWidget: @escaping () -> Void, onSnooze: @escaping () -> Void,
                          onSecondary: @escaping () -> Void) {
        let bellIcon = NSImageView()
        bellIcon.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: iconLabel)
        bellIcon.contentTintColor = NSColor(AppSettings.shared.colorAlert)
        bellIcon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = NSColor(white: 0.6, alpha: 1)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        let dismissBtn = ToastDismissButton(action: { onDismiss(); onClose() })
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false

        // Sends the reminder to the widget instead of settling it, for when the
        // toast is in the way but the thing still has to get done. Only alerts
        // have a widget card to go to.
        let widgetBtn = ToastDismissButton(symbol: "macwindow", tooltip: "Move to widget",
                                           action: { onMoveToWidget(); onClose() })
        widgetBtn.translatesAutoresizingMaskIntoConstraints = false

        let snoozeTitle = snoozeMinutes == 1 ? "Snooze 1 min" : "Snooze \(snoozeMinutes) min"
        let snoozeBtn = ToastButton(title: snoozeTitle, color: .systemBlue) { onSnooze(); onClose() }
        snoozeBtn.translatesAutoresizingMaskIntoConstraints = false

        let secondaryBtn = ToastButton(title: secondaryTitle, color: NSColor(white: 0.55, alpha: 1)) { onSecondary(); onClose() }
        secondaryBtn.translatesAutoresizingMaskIntoConstraints = false

        addSubview(bellIcon)
        addSubview(titleLabel)
        addSubview(timeLabel)
        addSubview(dismissBtn)
        if showMoveToWidget { addSubview(widgetBtn) }
        addSubview(snoozeBtn)
        addSubview(secondaryBtn)

        // Whatever sits leftmost in the button cluster is what the title has to
        // stop short of.
        let titleTrailingAnchor = showMoveToWidget ? widgetBtn.leadingAnchor : dismissBtn.leadingAnchor

        var constraints: [NSLayoutConstraint] = [
            bellIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            bellIcon.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            bellIcon.widthAnchor.constraint(equalToConstant: 20),
            bellIcon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: bellIcon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleTrailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            timeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            snoozeBtn.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -8),
            snoozeBtn.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 8),

            secondaryBtn.leadingAnchor.constraint(equalTo: snoozeBtn.trailingAnchor, constant: 4),
            secondaryBtn.centerYAnchor.constraint(equalTo: snoozeBtn.centerYAnchor),

            dismissBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dismissBtn.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dismissBtn.widthAnchor.constraint(equalToConstant: 20),
            dismissBtn.heightAnchor.constraint(equalToConstant: 20),
        ]

        if showMoveToWidget {
            constraints += [
                widgetBtn.trailingAnchor.constraint(equalTo: dismissBtn.leadingAnchor, constant: -2),
                widgetBtn.centerYAnchor.constraint(equalTo: dismissBtn.centerYAnchor),
                widgetBtn.widthAnchor.constraint(equalToConstant: 20),
                widgetBtn.heightAnchor.constraint(equalToConstant: 20),
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }
}
