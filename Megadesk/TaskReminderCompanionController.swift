import AppKit
import SwiftUI

/// Hosting view that takes the first click, so a button on a panel that never
/// becomes key still fires on the first press.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The companion-flavored task reminder: a pet says the reminder where the
/// toast would have appeared, with the same buttons.
///
/// This is a second companion, not the one from the widget. It owns its panel,
/// its animator and its position, reads no companion engine and posts no
/// companion notifications, so nothing it does can reach the main pet — and it
/// works just the same while the main pet is switched off.
final class TaskReminderCompanionController {
    static let shared = TaskReminderCompanionController()

    private struct Entry {
        let panel: NSPanel
        let taskId: UUID
        let animator: CompanionAnimator
        var size: NSSize
    }

    private var entries: [Entry] = []

    private let minWidth: CGFloat = 280
    private let maxWidth: CGFloat = 520
    private let defaultSize = NSSize(width: 280, height: 150)
    private let spacing: CGFloat = 8
    private let margin: CGFloat = 16
    /// Height of one alert toast, used to stack below any that are on screen.
    private let toastHeight: CGFloat = 90

    private var toastObserver: Any?

    private init() {
        // The alert toasts and these panels share the same corner. When that
        // stack grows or shrinks, this one moves with it instead of being
        // drawn over (or leaving a hole where a toast used to be).
        toastObserver = NotificationCenter.default.addObserver(
            forName: .megadeskToastStackChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.layout()
        }
    }

    // MARK: - Show / dismiss

    func show(for task: MegadeskTask) {
        // One panel per task: a repeating reminder coming back around reuses
        // its own panel instead of stacking copies of itself.
        if let existing = entries.first(where: { $0.taskId == task.id }) {
            existing.panel.orderFrontRegardless()
            return
        }
        // The view reads the task back out of the store by id, so a rename
        // reaches a panel that is already on screen.

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
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

        let animator = CompanionAnimator()
        animator.petId = AppSettings.shared.companionPetId
        animator.ghostState = .alert

        let taskId = task.id
        let snoozeMinutes = AppSettings.shared.snoozeMinutes
        let view = TaskReminderCompanionView(
            taskId: taskId,
            fallbackTitle: task.title,
            snoozeMinutes: snoozeMinutes,
            animator: animator,
            onSnooze: {
                NotificationCenter.default.post(name: .megadeskSnoozeTaskReminder, object: nil,
                                                userInfo: ["taskId": taskId, "minutes": snoozeMinutes])
                TaskReminderCompanionController.shared.dismiss(taskId: taskId)
            },
            onComplete: {
                TaskStore.shared.setCompleted(id: taskId, true)
            },
            onDismiss: {
                TaskStore.shared.dismissFiredReminder(id: taskId)
                TaskReminderCompanionController.shared.dismiss(taskId: taskId)
            },
            onMeasure: { [weak self] size in
                self?.updateSize(taskId: taskId, size: size)
            }
        )

        let hosting = FirstClickHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        entries.append(Entry(panel: panel, taskId: taskId, animator: animator, size: defaultSize))
        animator.isVisible = true
        layout()
        panel.orderFrontRegardless()
    }

    func dismiss(taskId: UUID) {
        guard let index = entries.firstIndex(where: { $0.taskId == taskId }) else { return }
        remove(at: index)
    }

    func dismissAll() {
        for entry in entries {
            entry.animator.isVisible = false
            entry.panel.orderOut(nil)
        }
        entries.removeAll()
    }

    private func remove(at index: Int) {
        let entry = entries[index]
        entries.remove(at: index)
        // Stopping the animator by hand: the frame timer belongs to this panel
        // and must not outlive it.
        entry.animator.isVisible = false

        let panel = entry.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.layout()
        })
    }

    // MARK: - Size & position

    /// The pet's art grows with the configured size, so the panel takes its
    /// measurements from the content instead of guessing them.
    private func updateSize(taskId: UUID, size: NSSize) {
        guard let index = entries.firstIndex(where: { $0.taskId == taskId }) else { return }
        let width = min(maxWidth, max(minWidth, ceil(size.width)))
        let height = max(80, ceil(size.height))
        guard abs(width - entries[index].size.width) > 1 ||
              abs(height - entries[index].size.height) > 1 else { return }
        entries[index].size = NSSize(width: width, height: height)
        layout()
    }

    /// Stacks the reminders where the toasts go, continuing below any alert
    /// toast already on screen so the two never land on the same spot.
    private func layout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let position = AppSettings.shared.toastPosition

        // Top edge of the first slot, matching where `ToastWindowController`
        // puts its own first toast for each position.
        let firstSlotTop: CGFloat
        switch position {
        case .topRight, .topCenter:
            firstSlotTop = visibleFrame.maxY - margin
        case .center:
            firstSlotTop = visibleFrame.midY + (toastHeight + spacing) / 2 + toastHeight / 2
        }
        var top = firstSlotTop - CGFloat(ToastWindowController.shared.activeToastCount) * (toastHeight + spacing)

        for entry in entries {
            // A big pet on a small screen still has to stay reachable: its
            // buttons are the only way to settle the reminder and the panel
            // can't be dragged.
            let height = min(entry.size.height, visibleFrame.height - margin * 2)
            let width = min(entry.size.width, visibleFrame.width - margin * 2)
            let size = NSSize(width: width, height: height)

            let x: CGFloat = position == .topRight
                ? visibleFrame.maxX - size.width - margin
                : visibleFrame.midX - size.width / 2
            let y = min(max(top - size.height, visibleFrame.minY + margin),
                        visibleFrame.maxY - size.height - margin)

            entry.panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            top -= size.height + spacing
        }
    }
}

// MARK: - View

private struct TaskReminderSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

/// The reminder as the pet tells it. Deliberately standalone: it doesn't read
/// `CompanionEngine`, doesn't write to the companion's history and doesn't post
/// the companion resize notification, so the main pet can't be disturbed by it.
private struct TaskReminderCompanionView: View {
    let taskId: UUID
    /// What the task was called when the reminder went off, for the moment
    /// after it's deleted and there's nothing left to read.
    let fallbackTitle: String
    let snoozeMinutes: Int
    let animator: CompanionAnimator
    let onSnooze: () -> Void
    let onComplete: () -> Void
    let onDismiss: () -> Void
    let onMeasure: (CGSize) -> Void

    private var settings = AppSettings.shared
    private var store = TaskStore.shared

    private var title: String {
        store.tasks.first(where: { $0.id == taskId })?.title ?? fallbackTitle
    }

    init(taskId: UUID, fallbackTitle: String, snoozeMinutes: Int, animator: CompanionAnimator,
         onSnooze: @escaping () -> Void, onComplete: @escaping () -> Void,
         onDismiss: @escaping () -> Void, onMeasure: @escaping (CGSize) -> Void) {
        self.taskId = taskId
        self.fallbackTitle = fallbackTitle
        self.snoozeMinutes = snoozeMinutes
        self.animator = animator
        self.onSnooze = onSnooze
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        self.onMeasure = onMeasure
    }

    /// Size of the pet's art in this panel. Its own setting, kept apart from
    /// the main companion's so one can be tuned without moving the other.
    private var petFont: Font {
        Font(NSFont.monospacedSystemFont(ofSize: CGFloat(settings.taskCompanionFontSize), weight: .regular))
    }

    var body: some View {
        VStack(spacing: 0) {
            bubble
            Text(animator.currentFrame)
                .font(petFont)
                .foregroundStyle(settings.colorCompanionPet.opacity(0.9))
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.top, 6)
            buttons
        }
        .padding(.vertical, 10)
        .background(settings.colorCompanionBackground.opacity(0.94))
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .fixedSize(horizontal: true, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TaskReminderSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(TaskReminderSizeKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            onMeasure(size)
        }
        .transaction { $0.animation = nil }
        .onChange(of: settings.companionPetId) { _, newPetId in
            // Its own animator, so this only ever repaints this panel.
            animator.petId = newPetId
        }
    }

    private var bubble: some View {
        Text(title)
            .font(Font(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)))
            .foregroundStyle(.white)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.top, 4)
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            pill(snoozeMinutes == 1 ? "Snooze 1 min" : "Snooze \(snoozeMinutes) min",
                 color: .blue, action: onSnooze)
            pill("Complete", color: Color(white: 0.55), action: onComplete)
        }
        .padding(.top, 8)
        .padding(.horizontal, 10)
    }

    private func pill(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
