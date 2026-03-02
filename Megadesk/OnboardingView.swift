import AppKit
import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var claudeHookDone = HookInstaller.isInstalled(provider: .claude)
    @State private var codexHookDone = HookInstaller.isInstalled(provider: .codex)
    @State private var itermDone = false
    @State private var itermDenied = false

    private var anyHookDone: Bool { claudeHookDone || codexHookDone }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
                Text("Welcome to Megadesk")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Connect at least one provider to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Step 1: Install Claude hook
            StepCard(
                number: 1,
                title: "Connect Claude Code",
                description: "Adds a hook to ~/.claude/settings.json to track session activity.",
                buttonLabel: "Install Hook",
                isDone: claudeHookDone,
                isDisabled: false
            ) {
                do {
                    try HookInstaller.install(provider: .claude)
                    claudeHookDone = true
                } catch {
                    // silently ignore; user can retry
                }
            }

            // Step 2: Install Codex hook (optional)
            StepCard(
                number: 2,
                title: "Connect Codex",
                description: "Sets the notify command in ~/.codex/config.toml. Optional — skip if you don't use Codex.",
                buttonLabel: "Install Hook",
                isDone: codexHookDone,
                isDisabled: false
            ) {
                do {
                    try HookInstaller.install(provider: .codex)
                    codexHookDone = true
                } catch {
                    // silently ignore; user can retry
                }
            }

            // Step 3: iTerm2 AppleScript permission
            StepCard(
                number: 3,
                title: "Allow iTerm2 Control",
                description: "Uses AppleScript to focus the right tab when you click a session card.",
                buttonLabel: "Grant Access",
                isDone: itermDone,
                isDisabled: !anyHookDone
            ) {
                var errorDict: NSDictionary?
                NSAppleScript(source: "tell application \"iTerm2\" to get name")?
                    .executeAndReturnError(&errorDict)
                if errorDict == nil {
                    itermDone = true
                    itermDenied = false
                } else {
                    itermDenied = true
                }
            }

            if itermDenied {
                Text("Focus won't work until you grant access in System Settings → Privacy → Automation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Continue") {
                UserDefaults.standard.set(true, forKey: "megadesk.onboardingComplete")
                onFinish()
            }
            .disabled(!anyHookDone)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct StepCard: View {
    let number: Int
    let title: String
    let description: String
    let buttonLabel: String
    let isDone: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(isDisabled ? Color.secondary : Color.accentColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        if isDone {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .imageScale(.large)
                        } else {
                            Button(buttonLabel, action: action)
                                .buttonStyle(.bordered)
                                .disabled(isDisabled)
                        }
                    }
                }
            }
            .padding(4)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}
