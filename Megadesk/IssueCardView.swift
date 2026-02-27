import SwiftUI
import AppKit

// MARK: - IssueCardView

struct IssueCardView: View {
    let trackedIssue: TrackedIssue
    let onRefresh: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Group {
            if let issue = trackedIssue.data {
                loadedCard(issue)
            } else {
                switch trackedIssue.fetchState {
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
                Label("Remove \(trackedIssue.id)", systemImage: "trash")
            }
        }
    }

    // MARK: - State views

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)

            Text(trackedIssue.id)
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
                Text(trackedIssue.id)
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

    private func loadedCard(_ issue: Issue) -> some View {
        Button(action: { openURL(issue.url) }) {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(color: dotColor(issue), pulse: false)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(issue.number) · \(issue.title)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(trackedIssue.repo)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)

                        labelBadges(issue.labels)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(relativeDate(issue.updatedAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(trackedIssue.fetchState == .loading ? .clear : .white.opacity(0.35))
                        .overlay {
                            if trackedIssue.fetchState == .loading {
                                ProgressView().scaleEffect(0.45)
                            }
                        }

                    ZStack(alignment: .trailing) {
                        // At-rest badges
                        HStack(spacing: 3) {
                            if issue.isNotPlanned { badge("not planned", color: Color(white: 0.45)) }
                        }
                        .opacity(isHovered ? 0 : 1)
                        .animation(.easeInOut(duration: 0.15), value: isHovered)

                        // Hover buttons
                        HStack(spacing: 2) {
                            if issue.isOpen {
                                solveButton(issue)
                                exploreButton(issue)
                            }
                            deleteButton
                        }
                        .opacity(isHovered ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(loadedBackground(issue))
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func solveCommand(_ issue: Issue) -> String {
        let repoParts = trackedIssue.repo.components(separatedBy: "/")
        guard repoParts.count == 2 else { return "" }
        let owner = repoParts[0]
        let repo = repoParts[1]
        let wt = "issue-\(issue.number)"
        let repoBase = AppSettings.shared.repoBasePath
        let cloneBase = AppSettings.shared.cloneBasePath
        let escapedBody = issue.truncatedBody
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "'\\''")
        let escapedTitle = issue.title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "'\\''")

        return """
        REPO_BASE="\(repoBase)"; \
        REPO="${REPO_BASE/#\\~/$HOME}/\(owner)/\(repo)"; \
        if [ ! -d "$REPO/.git" ]; then \
          CLONE_BASE="\(cloneBase)"; \
          REPO="${CLONE_BASE/#\\~/$HOME}/\(owner)/\(repo)"; \
          if [ ! -d "$REPO/.git" ]; then \
            echo "Cloning \(owner)/\(repo)..."; \
            gh repo clone "\(owner)/\(repo)" "$REPO" -- --filter=blob:none || exit 1; \
          fi; \
        fi; \
        cd "$REPO" && git fetch origin && \
        DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') && \
        : "${DEFAULT_BRANCH:=main}" && \
        git worktree remove ".worktrees/\(wt)" 2>/dev/null; \
        cd "$REPO" && \
        git worktree add ".worktrees/\(wt)" "origin/${DEFAULT_BRANCH}" && \
        cd "$REPO/.worktrees/\(wt)" && \
        claudios 'Implement a fix for issue \(trackedIssue.repo)#\(issue.number): \(escapedTitle). Issue body: '"'"'\(escapedBody)'"'"'. Create a branch, implement the fix, and push.'; \
        cd "$REPO" && git worktree remove ".worktrees/\(wt)" 2>/dev/null
        """
    }

    private func exploreCommand(_ issue: Issue) -> String {
        let repoParts = trackedIssue.repo.components(separatedBy: "/")
        guard repoParts.count == 2 else { return "" }
        let owner = repoParts[0]
        let repo = repoParts[1]
        let repoBase = AppSettings.shared.repoBasePath
        let cloneBase = AppSettings.shared.cloneBasePath
        let escapedBody = issue.truncatedBody
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "'\\''")
        let escapedTitle = issue.title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "'\\''")

        return """
        REPO_BASE="\(repoBase)"; \
        REPO="${REPO_BASE/#\\~/$HOME}/\(owner)/\(repo)"; \
        if [ ! -d "$REPO/.git" ]; then \
          CLONE_BASE="\(cloneBase)"; \
          REPO="${CLONE_BASE/#\\~/$HOME}/\(owner)/\(repo)"; \
          if [ ! -d "$REPO/.git" ]; then \
            echo "Cloning \(owner)/\(repo)..."; \
            gh repo clone "\(owner)/\(repo)" "$REPO" -- --filter=blob:none || exit 1; \
          fi; \
        fi; \
        cd "$REPO" && \
        claudios 'Analyze issue \(trackedIssue.repo)#\(issue.number): \(escapedTitle). Issue body: '"'"'\(escapedBody)'"'"'. Explore the codebase, identify the root cause, and propose potential fixes. Do NOT make any changes.'
        """
    }

    private func solveButton(_ issue: Issue) -> some View {
        Button(action: { TerminalFocuser.runCommand(solveCommand(issue), closeOnCompletion: true) }) {
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

    private func exploreButton(_ issue: Issue) -> some View {
        Button(action: { TerminalFocuser.runCommand(exploreCommand(issue), closeOnCompletion: true) }) {
            Image(systemName: "magnifyingglass")
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

    @ViewBuilder
    private func labelBadges(_ labels: [IssueLabel]) -> some View {
        let visible = Array(labels.prefix(2))
        let remaining = labels.count - visible.count
        ForEach(visible, id: \.name) { label in
            Text(label.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(hex: "#\(label.color)") ?? .white.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill((Color(hex: "#\(label.color)") ?? .white).opacity(0.18))
                )
                .lineLimit(1)
        }
        if remaining > 0 {
            Text("+\(remaining)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
        }
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

    private func dotColor(_ issue: Issue) -> Color {
        if issue.isOpen { return AppSettings.shared.colorIssueOpen }
        return AppSettings.shared.colorIssueClosed
    }

    private func loadedBackground(_ issue: Issue) -> Color {
        if issue.isOpen {
            return AppSettings.shared.colorIssueOpen.opacity(isHovered ? 0.12 : 0.06)
        }
        return Color.white.opacity(isHovered ? 0.07 : 0.02)
    }
}

// MARK: - CompactIssueCardView

struct CompactIssueCardView: View {
    let trackedIssue: TrackedIssue

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 3) {
            StatusDot(color: dotColor, pulse: false)
            Text("#\(trackedIssue.number)")
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
        guard trackedIssue.fetchState == .loaded, let issue = trackedIssue.data else {
            return AppSettings.shared.colorIssueClosed
        }
        if issue.isOpen { return AppSettings.shared.colorIssueOpen }
        return AppSettings.shared.colorIssueClosed
    }

    private var cardBackground: Color {
        guard let issue = trackedIssue.data else {
            return Color.white.opacity(isHovered ? 0.10 : 0.04)
        }
        if issue.isOpen {
            return AppSettings.shared.colorIssueOpen.opacity(isHovered ? 0.12 : 0.06)
        }
        return Color.white.opacity(isHovered ? 0.07 : 0.02)
    }
}
