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

    // MARK: - Kimi Code CLI

    /// Kimi Code CLI keeps its config in ~/.kimi-code (current builds) or
    /// ~/.kimi. Prefer whichever already exists, defaulting to ~/.kimi-code.
    private static var kimiHome: URL {
        let fm = FileManager.default
        let kimiCode = home.appendingPathComponent(".kimi-code")
        let kimi = home.appendingPathComponent(".kimi")
        if fm.fileExists(atPath: kimiCode.path) { return kimiCode }
        if fm.fileExists(atPath: kimi.path) { return kimi }
        return kimiCode
    }
    private static var kimiHookDest: URL { kimiHome.appendingPathComponent("megadesk-kimi-hook.py") }
    private static var kimiConfigURL: URL { kimiHome.appendingPathComponent("config.toml") }

    // MARK: - Public API

    static func isInstalled(provider: Provider) -> Bool {
        switch provider {
        case .claude: return isClaudeInstalled()
        case .codex:  return isCodexInstalled()
        case .kimi:   return isKimiInstalled()
        }
    }

    /// Installs the hook silently (no dialogs). Throws on failure.
    static func install(provider: Provider) throws {
        switch provider {
        case .claude: try installClaude()
        case .codex:  try installCodex()
        case .kimi:   try installKimi()
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

        // Replace existing root-level notify line if present, otherwise insert
        // at the root level (before the first [section] header).
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
            // Insert before the first TOML section header so it stays at root level
            let firstSection = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            if let idx = firstSection {
                lines.insert(notifyLine, at: idx)
            } else {
                if lines.last?.isEmpty == false { lines.append("") }
                lines.append(notifyLine)
            }
        }

        let output = lines.joined(separator: "\n")
        let tmp = codexConfigURL.appendingPathExtension("tmp")
        try output.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try fm.replaceItemAt(codexConfigURL, withItemAt: tmp)
    }

    // MARK: - Kimi

    private static func isKimiInstalled() -> Bool {
        guard let content = try? String(contentsOf: kimiConfigURL, encoding: .utf8) else { return false }
        return content.contains("megadesk-kimi-hook.py")
    }

    private static func installKimi() throws {
        let fm = FileManager.default
        let kimiDir = kimiHookDest.deletingLastPathComponent()
        try fm.createDirectory(at: kimiDir, withIntermediateDirectories: true)

        guard let bundledHook = Bundle.main.url(forResource: "megadesk-kimi-hook", withExtension: "py") else {
            throw InstallError.hookScriptNotFound(provider: .kimi)
        }
        if fm.fileExists(atPath: kimiHookDest.path) {
            try fm.removeItem(at: kimiHookDest)
        }
        try fm.copyItem(at: bundledHook, to: kimiHookDest)

        if !isKimiInstalled() { try patchKimiConfig() }
    }

    /// Appends `[[hooks]]` blocks to ~/.kimi/config.toml for the lifecycle
    /// events Megadesk tracks. Text based, to avoid a TOML dependency.
    private static func patchKimiConfig() throws {
        let fm = FileManager.default
        var content = ""
        if fm.fileExists(atPath: kimiConfigURL.path),
           let existing = try? String(contentsOf: kimiConfigURL, encoding: .utf8) {
            content = existing
        }

        let hookPath = kimiHookDest.path
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
        var blocks = ""
        for event in events {
            blocks += "\n[[hooks]]\nevent = \"\(event)\"\ncommand = \"python3 '\(hookPath)'\"\ntimeout = 3\n"
        }

        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += blocks

        let tmp = kimiConfigURL.appendingPathExtension("tmp")
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try fm.replaceItemAt(kimiConfigURL, withItemAt: tmp)
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
