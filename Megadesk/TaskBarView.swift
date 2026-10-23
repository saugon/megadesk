import SwiftUI

/// The task module's presence in the widget: one row of counters, above the
/// alerts. Tasks are many and long-lived, so the widget only summarizes them —
/// the whole row opens the window where they're actually handled.
struct TaskBarView: View {
    @State private var store = TaskStore.shared
    var isCompact: Bool = false

    @State private var isHovered = false

    var body: some View {
        // Reading the minute tick keeps the counters honest without a timer of
        // their own: "today" and "overdue" move on the clock, not on an edit,
        // and they have to follow it across midnight.
        let _ = store.minuteTick
        Button(action: open) {
            if isCompact { compactContent } else { fullContent }
        }
        .buttonStyle(.plain)
        .background(PointingHandCursor())
        .onHover { isHovered = $0 }
        .help("Open tasks")
    }

    // MARK: - Content

    private var fullContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))

            if isEmpty {
                // Zero tasks is still the module being there, quietly.
                Text("no tasks")
                    .font(.system(size: statusFontSize, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                HStack(spacing: 8) {
                    if store.overdueCount > 0 {
                        counter(store.overdueCount, "overdue", color: AppSettings.shared.colorAlert)
                    }
                    if store.todayCount > 0 {
                        counter(store.todayCount, "today", color: .white.opacity(0.75))
                    }
                    counter(store.openCount, "open", color: .white.opacity(0.45))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 0.5 : 0.25))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isHovered ? 0.10 : 0.04))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
        .contentShape(Rectangle())
    }

    private var compactContent: some View {
        VStack(spacing: 3) {
            Image(systemName: "checklist")
                .font(.system(size: 11))
                .foregroundColor(store.overdueCount > 0
                                 ? AppSettings.shared.colorAlert
                                 : .white.opacity(0.45))
            Text(isEmpty ? "-" : "\(store.openCount)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovered ? 0.10 : 0.04))
        )
        .contentShape(Rectangle())
    }

    private func counter(_ value: Int, _ label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: statusFontSize, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: statusFontSize - 1, design: .monospaced))
                .foregroundColor(color.opacity(0.6))
        }
        .fixedSize()
    }

    private var isEmpty: Bool { store.openCount == 0 }

    private var statusFontSize: CGFloat { CGFloat(AppSettings.shared.cardFontSize - 2) }

    private func open() {
        NotificationCenter.default.post(name: .megadeskShowTasks, object: nil)
    }
}
