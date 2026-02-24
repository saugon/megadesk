import SwiftUI
import AppKit

struct ContentView: View {
    @State private var store = StatusStore()
    @AppStorage("megadesk.compact") private var isCompact = false
    @AppStorage("megadesk.prTracking") private var prTrackingEnabled = true
    @State private var previousApp: NSRunningApplication?
    @State private var isAddingPR = false
    @State private var newPRText = ""

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

            if !isCompact, let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                Text("v\(version)  build \(build)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.2))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 2)
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
