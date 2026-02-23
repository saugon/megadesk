import Foundation

struct Session: Identifiable, Codable {
    let sessionId: String
    let cwd: String
    let state: String
    let stateSince: Double
    let lastUpdated: Double
    let toolName: String
    let lastEvent: String
    let itermSessionId: String

    var id: String { sessionId }

    var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    var isWorking: Bool { state == "working" }

    var isStale: Bool {
        Date().timeIntervalSince1970 - lastUpdated > 300
    }

    var timeInState: TimeInterval {
        Date().timeIntervalSince1970 - stateSince
    }

    /// Last hook was PreToolUse and nothing has updated in >4s — Claude is almost
    /// certainly waiting for the user to approve/deny a command confirmation.
    var needsConfirmation: Bool {
        guard isWorking && lastEvent == "PreToolUse" else { return false }
        return Date().timeIntervalSince1970 - lastUpdated > 4
    }

    /// Session has been in "waiting" state for >2 minutes — effectively idle.
    var isForgotten: Bool {
        !isWorking && timeInState > 300
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case state
        case stateSince = "state_since"
        case lastUpdated = "last_updated"
        case toolName = "tool_name"
        case lastEvent = "last_event"
        case itermSessionId = "iterm_session_id"
    }
}
