import AppKit
import SwiftUI

/// Curated, user-facing release highlights, shown once after the app updates to
/// a version that has an entry here.
///
/// On each release: bump MARKETING_VERSION and add a `Release` keyed by that
/// exact version string (matching CFBundleShortVersionString).
enum WhatsNew {
    struct Highlight: Identifiable {
        let id = UUID()
        let icon: String   // SF Symbol name
        let title: String
        let detail: String
        var usesPetArt = false   // hero only: show the companion pet art instead of the icon
    }

    struct Release {
        /// The headline feature, rendered large with the companion pet art.
        let hero: Highlight
        /// Secondary features, in priority order.
        let features: [Highlight]
        /// Smaller changes, shown as a compact list.
        let more: [String]
    }

    static let releases: [String: Release] = [
        "0.10.0": Release(
            hero: Highlight(
                icon: "bell.badge",
                title: "Alerts, tightened up",
                detail: "Snooze brings the alert back instead of burying it, dismissing a toast files it away, creating one has a Create step with an empty title, and a new toast button parks a reminder in the widget."
            ),
            features: [
                Highlight(
                    icon: "cursorarrow.motionlines",
                    title: "Dodge, one click away",
                    detail: "The widget footer now toggles 'Move out of the way' without opening Settings."
                ),
            ],
            more: [
                "The grow-on-hover width is a percentage of the panel now, so 100% reveals the whole widget.",
                "Dodging no longer walks the widget onto a second display.",
                "Sessions whose Claude quit are cleared even if you leave the terminal open.",
            ]
        ),
        "0.9.1": Release(
            hero: Highlight(
                icon: "arrow.right.to.line",
                title: "The widget gets out of your way",
                detail: "Turn on 'Move out of the way' and the widget (and the floating companion) slide to the nearest edge when your cursor comes near, then slide back when it leaves."
            ),
            features: [],
            more: [
                "Hover the tucked edge to peek at more without bringing it back.",
                "Pick the modifier key, and whether holding it pins the panels or is what makes them dodge.",
                "Tune how much peeks out in Settings, under 'Move Out of the Way'.",
            ]
        ),
        "0.9.0": Release(
            hero: Highlight(
                icon: "pawprint.fill",
                title: "Meet your Companion",
                detail: "A little desktop pet that lives in the widget and reacts to your sessions and PRs, cheering you on and nudging you when something needs attention.",
                usesPetArt: true
            ),
            features: [
                Highlight(
                    icon: "lock.shield",
                    title: "Permission mode at a glance",
                    detail: "Session cards now show Claude Code's mode (plan, accept edits, auto) right under the icon."
                ),
                Highlight(
                    icon: "sidebar.right",
                    title: "Collapse to an edge tab",
                    detail: "Tuck the widget against the screen edge with ⌘⇧L, in a compact or interactive style."
                ),
                Highlight(
                    icon: "terminal.fill",
                    title: "Kimi Code CLI",
                    detail: "Kimi is now a first-class provider, tracked right alongside Claude and Codex."
                ),
            ],
            more: [
                "Live session summary in the floating companion.",
                "Create and test your own custom pets from Settings.",
                "The widget is fully opaque at 100% opacity.",
                "More reliable focus for daemon-backed sessions.",
            ]
        ),
    ]

    private static let lastSeenKey = "megadesk.lastSeenVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func release(for version: String) -> Release? { releases[version] }

    /// The most recent release entry by version string, used as a fallback for
    /// the manual "What's New" menu action when the running version has no entry.
    static var latest: (version: String, release: Release)? {
        releases
            .max { $0.key.compare($1.key, options: .numeric) == .orderedAscending }
            .map { ($0.key, $0.value) }
    }

    /// True when the current version differs from the last one the user saw and
    /// has a release entry. Only reached for returning users (fresh installs get
    /// onboarding instead and never call into here), so a missing last-seen
    /// value means "updated from a version that predates this feature" and
    /// should still show the panel.
    static var shouldShow: Bool {
        let lastSeen = UserDefaults.standard.string(forKey: lastSeenKey)
        return lastSeen != currentVersion && release(for: currentVersion) != nil
    }

    static func markCurrentAsSeen() {
        UserDefaults.standard.set(currentVersion, forKey: lastSeenKey)
    }
}

struct WhatsNewView: View {
    let version: String
    let release: WhatsNew.Release
    var onClose: () -> Void

    /// ASCII art of the user's selected pet, to headline the Companion feature.
    private var petArt: String? {
        let id = AppSettings.shared.companionPetId
        return CompanionPetRegistry.shared.pet(id: id)?.previewFrame?.normalized
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text("What's New")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Megadesk \(version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            heroCard

            VStack(spacing: 16) {
                ForEach(release.features) { feature in
                    featureRow(feature)
                }
            }

            if !release.more.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Also in this release")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(Array(release.more.enumerated()), id: \.offset) { _, item in
                        Text("• \(item)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Got it", action: onClose)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(30)
        .frame(width: 460)
    }

    private var heroCard: some View {
        VStack(spacing: 12) {
            if release.hero.usesPetArt, let art = petArt {
                Text(art)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize()
            } else {
                Image(systemName: release.hero.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
            }
            Text(release.hero.title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(release.hero.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    private func featureRow(_ feature: WhatsNew.Highlight) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

final class WhatsNewWindowController: NSWindowController {
    convenience init(version: String, release: WhatsNew.Release, onClose: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "What's New"
        window.isReleasedWhenClosed = false

        let view = WhatsNewView(version: version, release: release, onClose: {
            window.close()
            onClose()
        })
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.center()

        let fittingSize = hosting.fittingSize
        if fittingSize.height > 0 {
            window.setContentSize(fittingSize)
            window.center()
        }

        self.init(window: window)
    }
}
