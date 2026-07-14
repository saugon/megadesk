import AppKit
import SwiftUI

struct HelpView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Megadesk")
                            .font(.title2).fontWeight(.semibold)
                        Text("Session monitor for Claude Code & Codex")
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }

            Section("Session States") {
                StateRow(color: .green,             label: "Working",            description: "Actively running a task")
                StateRow(color: .cyan,              label: "Needs confirmation", description: "Waiting for you to approve or deny a tool")
                StateRow(color: .orange,            label: "Waiting for input",  description: "Finished — your turn to respond")
                StateRow(color: Color(white: 0.45), label: "Forgotten",          description: "Idle for more than 5 minutes")
            }

            Section("Pull Request States") {
                StateRow(color: .green,             label: "CI passing",      description: "All checks passed")
                StateRow(color: .orange,            label: "CI pending",      description: "Checks are still running")
                StateRow(color: .red,               label: "CI failing",      description: "One or more checks failed")
                StateRow(color: .cyan,              label: "Merged",          description: "PR was successfully merged")
                StateRow(color: Color(white: 0.45), label: "Closed / no CI",  description: "Closed without merging, or no CI")
            }

            Section("Features") {
                FeatureRow(icon: "bolt.horizontal",             text: "Supports Claude Code and Codex CLI sessions")
                FeatureRow(icon: "cursorarrow.click",           text: "Click a card to focus its terminal tab (iTerm2, Ghostty)")
                FeatureRow(icon: "pencil",                      text: "Click ✏ on a card to rename it — persists through cd changes")
                FeatureRow(icon: "textformat.size",             text: "Adjustable card font size (10–18 pt) for sessions, alerts, and PRs")
                FeatureRow(icon: "rectangle.compress.vertical", text: "Compact Mode: condensed single-column view")
                FeatureRow(icon: "arrow.triangle.pull",         text: "PR Tracking: paste a PR URL to monitor CI status via the gh CLI")
                FeatureRow(icon: "bell.badge",                  text: "Alerts: set one-time or recurring reminders with toast, widget, and notification display")
                FeatureRow(icon: "note.text",                   text: "Context Save: jot down what you're working on before stepping away, with snooze and resume")
            }

            Section("Hotkeys") {
                FeatureRow(icon: "keyboard", text: "⌘⇧M — toggle widget visibility from anywhere")
                FeatureRow(icon: "keyboard", text: "⌘⇧L — collapse the widget to an edge tab (or expand it back)")
                FeatureRow(icon: "keyboard", text: "⌘⇧A — quick alert popover for fast reminders")
                FeatureRow(icon: "keyboard", text: "⌘⇧C — save a context note before stepping away")
                FeatureRow(icon: "keyboard", text: "⇧⌥↑ / ⇧⌥↓ — cycle through sessions up or down")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Helpers

private struct StateRow: View {
    let color: Color
    let label: String
    let description: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout).fontWeight(.medium)
                Text(description)
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
