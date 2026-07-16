import Foundation

enum Provider: String, Codable, CaseIterable {
    case claude = "claude"
    case codex = "codex"
    case kimi = "kimi"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .kimi:   return "Kimi"
        }
    }

    var hookScriptName: String {
        switch self {
        case .claude: return "megadesk-hook"
        case .codex:  return "megadesk-codex-hook"
        case .kimi:   return "megadesk-kimi-hook"
        }
    }
}
