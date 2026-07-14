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

/// Orientation of the live session-summary bar in the floating companion panel.
enum CompanionSummaryOrientation: String, CaseIterable {
    case horizontal
    case vertical

    var label: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical:   return "Vertical"
        }
    }
}

/// Which side the vertical session-summary bar docks to.
enum CompanionSummarySide: String, CaseIterable {
    case left
    case right

    var label: String {
        switch self {
        case .left:  return "Left"
        case .right: return "Right"
        }
    }
}

struct CompanionMessage: Identifiable {
    let id = UUID()
    let text: String
    let subject: String?   // Session/PR name to highlight in the text
    let ghostState: GhostState
    let ruleId: String
    let timestamp: Date

    init(text: String, ghostState: GhostState, ruleId: String, subject: String? = nil, timestamp: Date = Date()) {
        self.text = text
        self.ghostState = ghostState
        self.ruleId = ruleId
        self.subject = subject
        self.timestamp = timestamp
    }
}
