import AppKit
import SwiftUI

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Header
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Megadesk")
                        .font(.title2).fontWeight(.semibold)
                    Text("Claude Code session monitor for iTerm2")
                        .font(.subheadline).foregroundColor(.secondary)
                }
            }

            Divider()

            // Session + PR state references side by side
            HStack(alignment: .top, spacing: 12) {
                GroupBox("Session States") {
                    VStack(alignment: .leading, spacing: 10) {
                        StateRow(color: .green,             label: "Working",            description: "Claude is actively running a task")
                        StateRow(color: .cyan,              label: "Needs confirmation", description: "Waiting for you to approve or deny a tool")
                        StateRow(color: .orange,            label: "Waiting for input",  description: "Claude finished — your turn to respond")
                        StateRow(color: Color(white: 0.45), label: "Forgotten",          description: "Idle for more than 5 minutes")
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Pull Request States") {
                    VStack(alignment: .leading, spacing: 10) {
                        StateRow(color: .green,             label: "CI passing",      description: "All checks passed")
                        StateRow(color: .orange,            label: "CI pending",      description: "Checks are still running")
                        StateRow(color: .red,               label: "CI failing",      description: "One or more checks failed")
                        StateRow(color: .cyan,              label: "Merged",          description: "PR was successfully merged")
                        StateRow(color: Color(white: 0.45), label: "Closed / no CI", description: "Closed without merging, or no CI")
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Features
            GroupBox("Features") {
                VStack(alignment: .leading, spacing: 8) {
                    FeatureRow(icon: "cursorarrow.click",           text: "Click a card to focus its iTerm2 tab")
                    FeatureRow(icon: "pencil",                      text: "Click ✏ on a card to rename it — persists through cd changes")
                    FeatureRow(icon: "rectangle.compress.vertical", text: "Compact Mode: condensed single-column view")
                    FeatureRow(icon: "arrow.triangle.pull",         text: "PR Tracking: monitor pull request status via the gh CLI")
                    FeatureRow(icon: "keyboard",                    text: "⌘⇧M — toggle widget visibility from anywhere")
                }
                .padding(6)
            }
        }
        .padding(24)
        .frame(width: 620)
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
