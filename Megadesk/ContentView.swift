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
    @State private var store = StatusStore.shared
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

    // Live panel height, updated on every didResize (including during drag)
    // so sectionBudget recalculates in real time while the user resizes.
    @State private var metrics = WidgetWindowMetrics.shared

    // Estimated height of non-scrollable chrome: titlebar, footer, labels, alerts, PR controls.
    // Numbers calibrated against actual rendering — they feed sectionBudget, so being
    // ~1-2pt off is fine, but 20pt+ off creates visible gaps at the bottom.
    private var fixedOverhead: CGFloat {
        var h: CGFloat = 66  // titlebar safe area (28) + footer (38)
        h += 17              // "sessions" label (9pt font + 6pt padding)
        if !widgetAlerts.isEmpty {
            h += 17          // "alerts" label
            h += CGFloat(widgetAlerts.count) * 52  // alert cards (~52pt incl. spacing)
        }
        if prTrackingEnabled {
            h += 17          // "pull requests" label
            h += 24          // "+ Track PR" row (11pt font + 12pt padding)
        }
        h += 16              // outer padding (8 top + 8 bottom)
        return h
    }

    // Budget available for the two scrollable sections combined.
    // Uses a screen-based cap in auto-height mode so the widget doesn't blow
    // up to fit 20+ sessions vertically. In locked-height mode, the budget
    // is derived from the user-set height so sections scroll instead of
    // overflowing. During a live drag, `metrics.currentHeight` reflects the
    // panel's actual height so sections reflow in real time.
    private var sectionBudget: CGFloat {
        let screenBudget = max(200, (NSScreen.main?.visibleFrame.height ?? 700) - 68 - 250)
        let effectiveHeight: CGFloat = metrics.currentHeight > 0
            ? metrics.currentHeight
            : CGFloat(lockedHeightPref)
        if effectiveHeight > 0 {
            return min(max(100, effectiveHeight - fixedOverhead), screenBudget)
        }
        return screenBudget
    }

    // Minimum vertical space reserved for the sessions section (about 2-3 cards).
    private static let minSessionsSpace: CGFloat = 180

    // Space PRs are allowed to take when the combined naturals overflow the
    // budget: their own natural height, capped only to keep `minSessionsSpace`
    // available for sessions. A 35% absolute floor prevents starving PRs on
    // very small widgets where `budget - min` would be tiny.
    private var prAllocWhenOverflowing: CGFloat {
        let ceiling = max(sectionBudget - Self.minSessionsSpace, sectionBudget * 0.35)
        return min(prContentHeight, ceiling)
    }

    // Dynamic allocation: PRs get their natural height unless it would starve
    // sessions. When both sections fit naturally, no scrolling occurs.
    private var sessionsMaxHeight: CGFloat {
        guard prTrackingEnabled, prContentHeight > 0 else { return sectionBudget }
        let totalNatural = sessionsContentHeight + prContentHeight
        if totalNatural > 0 && totalNatural <= sectionBudget {
            return sessionsContentHeight
        }
        return max(Self.minSessionsSpace, sectionBudget - prAllocWhenOverflowing)
    }
    private var prMaxHeight: CGFloat {
        guard prContentHeight > 0 else { return sectionBudget * 0.35 }
        let totalNatural = sessionsContentHeight + prContentHeight
        if totalNatural > 0 && totalNatural <= sectionBudget {
            return prContentHeight
        }
        return prAllocWhenOverflowing
    }

    private var widgetAlerts: [MegadeskAlert] {
        return store.alerts.filter {
            $0.effectiveShowWidget &&
            store.firedAlertIds.contains($0.id) &&
            !store.dismissedFiredAlertIds.contains($0.id)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            if isCompact {
                sectionLabel("s")
            }

            if store.sessions.isEmpty && widgetAlerts.isEmpty {
                emptyState
            } else if isCompact {
                ForEach(widgetAlerts) { alert in
                    AlertCardView(alert: alert, isCompact: isCompact)
                }
                ForEach(store.sessions) { session in
                    CompactSessionCardView(
                        session: session,
                        tick: store.tick,
                        displayName: store.displayName(for: session),
                        onFocus: { store.focusTerminal(session: session) }
                    )
                }
            } else {
                // Alerts section — fixed (not scrollable), pinned above sessions
                if !widgetAlerts.isEmpty {
                    sectionLabel("alerts")
                    ForEach(widgetAlerts) { alert in
                        AlertCardView(alert: alert, isCompact: false)
                    }
                }

                // Sessions section — independent scroll
                sectionLabel("sessions")
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(store.sessions) { session in
                            SessionCardView(
                                session: session,
                                tick: store.tick,
                                spinnerTick: store.spinnerTick,
                                displayName: store.displayName(for: session),
                                hasCustomName: store.hasCustomName(for: session),
                                isFlashing: store.activeSessionId == session.sessionId,
                                toolDetail: store.toolDetail(for: session),
                                spinnerInfo: store.spinnerInfo(for: session),
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

            // Companion ghost — docked mode, normal (non-compact) only
            if !isCompact,
               AppSettings.shared.companionEnabled,
               AppSettings.shared.companionMode == .docked {
                sectionLabel("companion")
                CompanionView(inline: true)
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
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
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
