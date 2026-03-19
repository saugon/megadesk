import Foundation

enum Provider: String, Codable, CaseIterable {
    case claude = "claude"
    case codex = "codex"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    var hookScriptName: String {
        switch self {
        case .claude: return "megadesk-hook"
        case .codex:  return "megadesk-codex-hook"
        }
    }
}
