import SwiftUI
import AppKit

// MARK: - PRCardView

struct PRCardView: View {
    let trackedPR: TrackedPR
    let onRefresh: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Group {
            if let pr = trackedPR.data {
                // Always keep showing existing data; state drives subtle indicators inside the card.
                loadedCard(pr)
            } else {
                switch trackedPR.fetchState {
                case .loading:         loadingCard
                case .error(let msg):  errorCard(msg)
                default:               loadingCard
                }
            }
        }
        .background(PointingHandCursor())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Divider()
            Button(role: .destructive, action: onRemove) {
                Label("Remove \(trackedPR.id)", systemImage: "trash")
            }
        }
    }

    // MARK: - State views

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)

            Text(trackedPR.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(1)

            Spacer()

            deleteButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cardShell)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.7))

            VStack(alignment: .leading, spacing: 1) {
                Text(trackedPR.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)

            deleteButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(isHovered ? 0.12 : 0.06))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
    }

    private func loadedCard(_ pr: PullRequest) -> some View {
        Button(action: { openURL(pr.url) }) {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(color: dotColor(pr), pulse: pr.ciStatus == .pending)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(pr.number) · \(pr.title)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)

                    Text("\(trackedPR.repo) · \(pr.shortBranch)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(relativeDate(pr.updatedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(trackedPR.fetchState == .loading ? .clear : .white.opacity(0.35))
                        .overlay {
                            if trackedPR.fetchState == .loading {
                                ProgressView().scaleEffect(0.45)
                            }
                        }

                    ZStack(alignment: .trailing) {
                        HStack(spacing: 3) {
                            if pr.hasConflicts { badge("conflict", color: .red) }
                            if pr.isBehindMain { badge("behind", color: .yellow) }
                        }
                        .opacity(isHovered ? 0 : 1)
                        .animation(.easeInOut(duration: 0.15), value: isHovered)

                    HStack(spacing: 2) {
                        if let prompt = fixPrompt(pr) {
                            fixButton(prompt: prompt)
                        }
                        deleteButton
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(loadedBackground(pr))
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func fixPrompt(_ pr: PullRequest) -> String? {
        guard !pr.isMerged, !pr.isClosed else { return nil }
        if pr.hasConflicts { return "Fix conflicts in PR \(trackedPR.repo)#\(pr.number)" }
        if pr.ciStatus == .failing { return "Fix CI in PR \(trackedPR.repo)#\(pr.number)" }
        if pr.isBehindMain { return "Make PR \(trackedPR.repo)#\(pr.number) up-to-date" }
        return nil
    }

    private func fixButton(prompt: String) -> some View {
        Button(action: { TerminalFocuser.runCommand("claudios \"\(prompt)\"") }) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.3))
                .frame(width: 16, height: 16)
                .background(Color.white.opacity(isHovered ? 0.1 : 0))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var deleteButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.3))
                .frame(width: 16, height: 16)
                .background(Color.white.opacity(isHovered ? 0.1 : 0))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private func relativeDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 3600   { return "\(max(1, Int(diff / 60)))m ago" }
        if diff < 86400  { return "\(Int(diff / 3600))h ago" }
        if diff < 604800 { return "\(Int(diff / 86400))d ago" }
        let comps = Calendar.current.dateComponents([.month, .day], from: date)
        let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        let idx = (comps.month ?? 1) - 1
        let m = idx >= 0 && idx < months.count ? months[idx] : ""
        return "\(m) \(comps.day ?? 0)"
    }

    private var cardShell: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(isHovered ? 0.10 : 0.04))
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func dotColor(_ pr: PullRequest) -> Color {
        if pr.isMerged { return AppSettings.shared.colorPRMerged }
        if pr.isClosed { return AppSettings.shared.colorPRClosed }
        switch pr.ciStatus {
        case .failing: return AppSettings.shared.colorPRFailing
        case .pending: return AppSettings.shared.colorPRPending
        case .passing: return AppSettings.shared.colorPRPassing
        case .none:    return AppSettings.shared.colorPRClosed
        }
    }

    private func loadedBackground(_ pr: PullRequest) -> Color {
        if pr.isMerged { return AppSettings.shared.colorPRMerged.opacity(isHovered ? 0.12 : 0.06) }
        if pr.isClosed { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
        switch pr.ciStatus {
        case .failing: return AppSettings.shared.colorPRFailing.opacity(isHovered ? 0.16 : 0.08)
        case .pending: return AppSettings.shared.colorPRPending.opacity(isHovered ? 0.16 : 0.08)
        default:       return Color.white.opacity(isHovered ? 0.12 : 0.05)
        }
    }
}

// MARK: - CompactPRCardView

struct CompactPRCardView: View {
    let trackedPR: TrackedPR

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 3) {
            StatusDot(color: dotColor, pulse: trackedPR.data?.ciStatus == .pending)
            Text("#\(trackedPR.number)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(cardBackground)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
        .onHover { isHovered = $0 }
    }

    private var dotColor: Color {
        guard trackedPR.fetchState == .loaded, let pr = trackedPR.data else {
            return AppSettings.shared.colorPRClosed
        }
        if pr.isMerged { return AppSettings.shared.colorPRMerged }
        if pr.isClosed { return AppSettings.shared.colorPRClosed }
        switch pr.ciStatus {
        case .failing: return AppSettings.shared.colorPRFailing
        case .pending: return AppSettings.shared.colorPRPending
        case .passing: return AppSettings.shared.colorPRPassing
        case .none:    return AppSettings.shared.colorPRClosed
        }
    }

    private var cardBackground: Color {
        guard let pr = trackedPR.data else {
            return Color.white.opacity(isHovered ? 0.10 : 0.04)
        }
        if pr.isMerged { return AppSettings.shared.colorPRMerged.opacity(isHovered ? 0.12 : 0.06) }
        if pr.isClosed { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
        switch pr.ciStatus {
        case .failing: return AppSettings.shared.colorPRFailing.opacity(isHovered ? 0.16 : 0.08)
        case .pending: return AppSettings.shared.colorPRPending.opacity(isHovered ? 0.16 : 0.08)
        default:       return Color.white.opacity(isHovered ? 0.12 : 0.05)
        }
    }
}
