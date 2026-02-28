import SwiftUI
import AppKit

struct ContentView: View {
    @State private var store = StatusStore()
    @AppStorage("megadesk.compact") private var isCompact = false
    @AppStorage("megadesk.prTracking") private var prTrackingEnabled = true
    @AppStorage("megadesk.issueTracking") private var issueTrackingEnabled = true
    @State private var previousApp: NSRunningApplication?
    @State private var isAddingPR = false
    @State private var newPRText = ""
    @State private var isAddingIssue = false
    @State private var newIssueText = ""

    var body: some View {
        VStack(spacing: 4) {
            if prTrackingEnabled {
                sectionLabel(isCompact ? "s" : "sessions")
            }

            if store.sessions.isEmpty {
                emptyState
            } else {
                ForEach(store.sessions) { session in
                    if isCompact {
                        CompactSessionCardView(
                            session: session,
                            tick: store.tick,
                            displayName: store.displayName(for: session),
                            onFocus: { store.focusTerminal(session: session) },
                            onDismiss: { store.dismiss(session: session) }
                        )
                    } else {
                        SessionCardView(
                            session: session,
                            tick: store.tick,
                            displayName: store.displayName(for: session),
                            hasCustomName: store.hasCustomName(for: session),
                            isFlashing: store.activeSessionId == session.sessionId,
                            onFocus: { store.focusTerminal(session: session) },
                            onDismiss: { store.dismiss(session: session) },
                            onRename: { name in store.setCustomName(session: session, name: name) },
                            onEditStart: beginEditing,
                            onEditEnd: endEditing
                        )
                    }
                }
            }

            if prTrackingEnabled {
                if isCompact {
                    sectionLabel("pr")
                    compactPRSection
                } else {
                    prSection
                }
            }

            if issueTrackingEnabled {
                if isCompact {
                    sectionLabel("issue")
                    compactIssueSection
                } else {
                    issueSection
                }
            }

            if !isCompact, let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                HStack {
                    Text("⌘⇧M to hide")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                    Spacer()
                    Text("v\(version)  build \(build)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                }
                .padding(.top, 6)
                .padding(.horizontal, 6)
            }
        }
        .padding(8)
        .frame(minWidth: isCompact ? 78 : 220, maxWidth: isCompact ? 78 : 280)
    }

    private var emptyState: some View {
        Text("No active instances")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    // MARK: - PR sections

    @ViewBuilder
    private var prSection: some View {
        prSectionHeader
        ForEach(store.trackedPRs) { tracked in
            PRCardView(
                trackedPR: tracked,
                onRefresh: { store.fetchPR(repo: tracked.repo, number: tracked.number) },
                onRemove: { store.removeTrackedPR(id: tracked.id) }
            )
        }
        addPRRow
    }

    private var prSectionHeader: some View {
        let countdown = prRefreshCountdown
        return HStack(spacing: 6) {
            Text("pull requests")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
                .fixedSize()
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
            Text("\(countdown)s")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var prRefreshCountdown: Int {
        let _ = store.tick  // re-evaluate every second
        guard let last = store.prLastFetchedAt else { return 60 }
        return max(0, 60 - Int(Date().timeIntervalSince(last)))
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
                .fixedSize()
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var compactPRSection: some View {
        ForEach(store.trackedPRs) { tracked in
            CompactPRCardView(trackedPR: tracked)
        }
    }

    @ViewBuilder
    private var addPRRow: some View {
        if isAddingPR {
            HStack(spacing: 6) {
                LimitedTextField(
                    text: $newPRText,
                    limit: 120,
                    font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                    onCommit: submitPR,
                    onCancel: cancelAddPR
                )
                .frame(height: 16)

                Button(action: cancelAddPR) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
            )
        } else {
            Button(action: { isAddingPR = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                    Text("Track PR")
                        .font(.system(size: 11))
                }
                .foregroundColor(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    private func submitPR() {
        let trimmed = newPRText.trimmingCharacters(in: .whitespaces)
        if let (repo, number) = TrackedPR.parse(trimmed) {
            store.addTrackedPR(repo: repo, number: number)
        }
        newPRText = ""
        isAddingPR = false
    }

    private func cancelAddPR() {
        newPRText = ""
        isAddingPR = false
    }

    // MARK: - Issue sections

    @ViewBuilder
    private var issueSection: some View {
        issueSectionHeader
        ForEach(store.trackedIssues) { tracked in
            IssueCardView(
                trackedIssue: tracked,
                onRefresh: { store.fetchIssue(repo: tracked.repo, number: tracked.number) },
                onRemove: { store.removeTrackedIssue(id: tracked.id) }
            )
        }
        addIssueRow
    }

    private var issueSectionHeader: some View {
        let countdown = issueRefreshCountdown
        return HStack(spacing: 6) {
            Text("issues")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
                .fixedSize()
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)
            Text("\(countdown)s")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var issueRefreshCountdown: Int {
        let _ = store.tick
        guard let last = store.issueLastFetchedAt else { return 60 }
        return max(0, 60 - Int(Date().timeIntervalSince(last)))
    }

    @ViewBuilder
    private var compactIssueSection: some View {
        ForEach(store.trackedIssues) { tracked in
            CompactIssueCardView(trackedIssue: tracked)
        }
    }

    @ViewBuilder
    private var addIssueRow: some View {
        if isAddingIssue {
            HStack(spacing: 6) {
                LimitedTextField(
                    text: $newIssueText,
                    limit: 120,
                    font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                    onCommit: submitIssue,
                    onCancel: cancelAddIssue
                )
                .frame(height: 16)

                Button(action: cancelAddIssue) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
            )
        } else {
            Button(action: { isAddingIssue = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                    Text("Track Issue")
                        .font(.system(size: 11))
                }
                .foregroundColor(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    private func submitIssue() {
        let trimmed = newIssueText.trimmingCharacters(in: .whitespaces)
        if let (repo, number) = TrackedIssue.parse(trimmed) {
            store.addTrackedIssue(repo: repo, number: number)
        }
        newIssueText = ""
        isAddingIssue = false
    }

    private func cancelAddIssue() {
        newIssueText = ""
        isAddingIssue = false
    }

    // MARK: - Edit lifecycle

    private func beginEditing() {
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
    }

    private func endEditing() {
        previousApp?.activate()
        previousApp = nil
    }
}
