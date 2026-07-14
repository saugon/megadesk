import SwiftUI

/// Read-only list of the most-recently emitted companion messages, with a
/// colored dot per ghost state, the message text (subject highlighted to
/// match the bubble rendering), and a relative timestamp. Used both inside
/// CompanionSettingsView and inside the popover triggered from the pet
/// panel.
struct CompanionHistoryView: View {
    @State private var engine = CompanionEngine.shared
    @State private var now = Date()

    /// Drives the relative timestamps to refresh ("3 min ago" → "4 min ago")
    /// every minute while the view is on screen.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if engine.recentMessages.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(engine.recentMessages.enumerated()), id: \.element.id) { index, message in
                            row(for: message)
                            if index < engine.recentMessages.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private var emptyState: some View {
        Text("No messages yet")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }

    private func row(for message: CompanionMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(stateColor(message.ghostState))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributed(for: message))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Text(relativeTime(message.timestamp))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func stateColor(_ state: GhostState) -> Color {
        switch state {
        case .alert: return AppSettings.shared.colorAlert
        case .happy: return .green
        case .idle:  return .gray
        }
    }

    /// Builds an AttributedString with the subject portion highlighted, mirroring
    /// the rendering used by the speech bubble.
    private func attributed(for message: CompanionMessage) -> AttributedString {
        var attr = AttributedString(message.text)
        guard let subject = message.subject, !subject.isEmpty else { return attr }
        var searchRange = attr.startIndex..<attr.endIndex
        while let range = attr[searchRange].range(of: subject) {
            attr[range].foregroundColor = AppSettings.shared.colorCompanionSubject
            attr[range].font = .system(size: 12, weight: .semibold)
            searchRange = range.upperBound..<attr.endIndex
        }
        return attr
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
