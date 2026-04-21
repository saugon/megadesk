import Foundation

enum GhostState: String, Codable {
    case idle, alert, happy
}

enum CompanionMode: String, CaseIterable {
    case docked  = "docked"
    case floating = "floating"

    var label: String {
        switch self {
        case .docked:   return "Docked"
        case .floating: return "Floating"
        }
    }
}

struct CompanionMessage: Identifiable {
    let id = UUID()
    let text: String
    let subject: String?   // Session/PR name to highlight in the text
    let ghostState: GhostState
    let ruleId: String

    init(text: String, ghostState: GhostState, ruleId: String, subject: String? = nil) {
        self.text = text
        self.ghostState = ghostState
        self.ruleId = ruleId
        self.subject = subject
    }
}
