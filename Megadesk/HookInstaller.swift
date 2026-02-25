import AppKit
import Foundation

enum HookInstaller {

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: - Claude Code

    private static let claudeHookCommand  = "python3 ~/.claude/megadesk-hook.py"
    private static let claudeHookDest     = home.appendingPathComponent(".claude/megadesk-hook.py")
    private static let claudeSettingsURL  = home.appendingPathComponent(".claude/settings.json")

    // MARK: - Codex

    private static let codexHookDest      = home.appendingPathComponent(".codex/megadesk-codex-hook.py")
    private static let codexHookCommand   = "python3 ~/.codex/megadesk-codex-hook.py"
    private static let codexConfigURL     = home.appendingPathComponent(".codex/config.toml")

    // MARK: - Public API

    static func isInstalled(provider: Provider) -> Bool {
        switch provider {
        case .claude: return isClaudeInstalled()
        case .codex:  return isCodexInstalled()
        }
    }

    /// Installs the hook silently (no dialogs). Throws on failure.
    static func install(provider: Provider) throws {
        switch provider {
        case .claude: try installClaude()
        case .codex:  try installCodex()
        }
    }

    /// Legacy convenience — installs Claude hook only.
    static func isInstalled() -> Bool { isInstalled(provider: .claude) }
    static func install() throws { try install(provider: .claude) }

    // MARK: - Claude

    private static func isClaudeInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            "\(value)".contains(claudeHookCommand)
        }
    }

    private static func installClaude() throws {
        let fm = FileManager.default
        let claudeDir = claudeHookDest.deletingLastPathComponent()
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        guard let bundledHook = Bundle.main.url(forResource: "megadesk-hook", withExtension: "py") else {
            throw InstallError.hookScriptNotFound(provider: .claude)
        }
        if fm.fileExists(atPath: claudeHookDest.path) {
            try fm.removeItem(at: claudeHookDest)
        }
        try fm.copyItem(at: bundledHook, to: claudeHookDest)

        if !isClaudeInstalled() { try patchClaudeSettings() }
    }

    private static func patchClaudeSettings() throws {
        let fm = FileManager.default
        var settings: [String: Any]

        if fm.fileExists(atPath: claudeSettingsURL.path),
           let data = try? Data(contentsOf: claudeSettingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        } else {
            settings = [:]
        }

        let hookEntry: [String: Any] = ["type": "command", "command": claudeHookCommand, "timeout": 3]
        let withMatcher:    [[String: Any]] = [["matcher": ".*", "hooks": [hookEntry]]]
        let withoutMatcher: [[String: Any]] = [["hooks": [hookEntry]]]

        let events: [String: [[String: Any]]] = [
            "PreToolUse":       withMatcher,
            "PostToolUse":      withMatcher,
            "Stop":             withoutMatcher,
            "UserPromptSubmit": withoutMatcher,
            "SessionStart":     withoutMatcher,
        ]

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, config) in events {
            let existing = "\(hooks[event] ?? "")"
            if !existing.contains(claudeHookCommand) {
                let current = hooks[event] as? [[String: Any]] ?? []
                hooks[event] = current + config
            }
        }
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let tmp  = claudeSettingsURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try fm.replaceItemAt(claudeSettingsURL, withItemAt: tmp)
    }

    // MARK: - Codex

    private static func isCodexInstalled() -> Bool {
        guard let content = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return false }
        return content.contains("megadesk-codex-hook.py")
    }

    private static func installCodex() throws {
        let fm = FileManager.default
        let codexDir = codexHookDest.deletingLastPathComponent()
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)

        guard let bundledHook = Bundle.main.url(forResource: "megadesk-codex-hook", withExtension: "py") else {
            throw InstallError.hookScriptNotFound(provider: .codex)
        }
        if fm.fileExists(atPath: codexHookDest.path) {
            try fm.removeItem(at: codexHookDest)
        }
        try fm.copyItem(at: bundledHook, to: codexHookDest)

        if !isCodexInstalled() { try patchCodexConfig() }
    }

    /// Patches ~/.codex/config.toml to set the `notify` key.
    /// Uses line-based parsing to avoid an external TOML dependency.
    private static func patchCodexConfig() throws {
        let fm = FileManager.default
        var lines: [String]

        if fm.fileExists(atPath: codexConfigURL.path),
           let content = try? String(contentsOf: codexConfigURL, encoding: .utf8) {
            lines = content.components(separatedBy: "\n")
        } else {
            lines = []
        }

        let hookPath = codexHookDest.path
        let notifyLine = "notify = [\"python3\", \"\(hookPath)\"]"

        // Replace existing notify line if present, otherwise append
        var replaced = false
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("notify") && trimmed.contains("=") {
                lines[i] = notifyLine
                replaced = true
                break
            }
        }
        if !replaced {
            // If file is empty or doesn't end with a newline, ensure clean append
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(notifyLine)
        }

        let output = lines.joined(separator: "\n")
        let tmp = codexConfigURL.appendingPathExtension("tmp")
        try output.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try fm.replaceItemAt(codexConfigURL, withItemAt: tmp)
    }
}

private enum InstallError: LocalizedError {
    case hookScriptNotFound(provider: Provider)
    var errorDescription: String? {
        switch self {
        case .hookScriptNotFound(let provider):
            return "\(provider.hookScriptName).py was not found inside the app bundle."
        }
    }
}
