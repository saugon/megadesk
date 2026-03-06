import SwiftUI
import AppKit

// MARK: - Section height measurement keys

private struct SessionsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PRHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ContentView: View {
    @State private var store = StatusStore()
    @AppStorage("megadesk.compact") private var isCompact = false
    @AppStorage("megadesk.prTracking") private var prTrackingEnabled = true
    @State private var previousApp: NSRunningApplication?
    @State private var isAddingPR = false
    @State private var newPRText = ""

    // Measured natural heights of each section's scrollable content (inside each ScrollView).
    @State private var sessionsContentHeight: CGFloat = 0
    @State private var prContentHeight: CGFloat = 0

    // Persisted locked height — non-zero when user has manually set a height.
    @AppStorage("megadesk.windowHeight") private var lockedHeightPref: Double = 0

    // Budget available for the two scrollable sections combined.
    // Uses screen-based limit in auto-height mode; switches to locked-height-based limit
    // when the user has manually set a height, so sections scroll rather than overflow.
    private var sectionBudget: CGFloat {
        let screenBudget = max(200, (NSScreen.main?.visibleFrame.height ?? 700) - 68 - 250)
        if lockedHeightPref > 0 {
            // ~150pt overhead: titlebar safeArea(28) + footer(28) + labels/buttons/padding(94)
            return min(max(150, CGFloat(lockedHeightPref) - 150), screenBudget)
        }
        return screenBudget
    }

    // Dynamic allocation: PRs get their natural height (up to 35% of budget), sessions
    // gets everything else. When both sections fit naturally, no scrolling occurs.
    private var sessionsMaxHeight: CGFloat {
        guard prTrackingEnabled else { return sectionBudget }
        let totalNatural = sessionsContentHeight + prContentHeight
        if totalNatural > 0 && totalNatural <= sectionBudget {
            return sessionsContentHeight  // both fit: no caps needed
        }
        // PRs take their natural size (or 35% cap if unusually large).
        // Sessions gets the rest — no wasted space below PRs.
        let prAlloc = prContentHeight > 0 ? min(prContentHeight, sectionBudget * 0.35) : sectionBudget * 0.35
        return max(80, sectionBudget - prAlloc)
    }
    private var prMaxHeight: CGFloat {
        let totalNatural = sessionsContentHeight + prContentHeight
        if totalNatural > 0 && totalNatural <= sectionBudget {
            return prContentHeight  // both fit: no caps needed
        }
        return prContentHeight > 0 ? min(prContentHeight, sectionBudget * 0.35) : sectionBudget * 0.35
    }

    var body: some View {
        VStack(spacing: 4) {
            if prTrackingEnabled {
                sectionLabel(isCompact ? "s" : "sessions")
            }

            if store.sessions.isEmpty {
                emptyState
            } else if isCompact {
                ForEach(store.sessions) { session in
                    CompactSessionCardView(
                        session: session,
                        tick: store.tick,
                        displayName: store.displayName(for: session),
                        onFocus: { store.focusTerminal(session: session) }
                    )
                }
            } else {
                // Sessions section — independent scroll
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(store.sessions) { session in
                            SessionCardView(
                                session: session,
                                tick: store.tick,
                                displayName: store.displayName(for: session),
                                hasCustomName: store.hasCustomName(for: session),
                                isFlashing: store.activeSessionId == session.sessionId,
                                toolDetail: store.toolDetail(for: session),
                                onFocus: { store.focusTerminal(session: session) },
                                onRename: { name in store.setCustomName(session: session, name: name) },
                                onEditStart: beginEditing,
                                onEditEnd: endEditing
                            )
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: SessionsHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .onPreferenceChange(SessionsHeightKey.self) { h in
                    if h != sessionsContentHeight { sessionsContentHeight = h }
                }
                .frame(height: sessionsContentHeight > 0
                       ? min(sessionsContentHeight, sessionsMaxHeight)
                       : nil)
            }

            if prTrackingEnabled {
                if isCompact {
                    sectionLabel("pr")
                    compactPRSection
                } else {
                    prSection
                }
            }

        }
        .padding(8)
        .frame(minWidth: isCompact ? 78 : 220, maxWidth: isCompact ? 78 : 280)
    }

    var footerView: some View {
        Group {
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
                .padding(.bottom, 8)
                .frame(minWidth: 220, maxWidth: 280)
            }
        }
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
        if !store.trackedPRs.isEmpty {
            // PR cards — independent scroll
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 4) {
                    ForEach(store.trackedPRs) { tracked in
                        PRCardView(
                            trackedPR: tracked,
                            onRefresh: { store.fetchPR(repo: tracked.repo, number: tracked.number) },
                            onRemove: { store.removeTrackedPR(id: tracked.id) }
                        )
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: PRHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .onPreferenceChange(PRHeightKey.self) { h in
                if h != prContentHeight { prContentHeight = h }
            }
            .frame(height: prContentHeight > 0
                   ? min(prContentHeight, prMaxHeight)
                   : nil)
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
