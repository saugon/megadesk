import Foundation

struct Session: Identifiable, Codable {
    let sessionId: String
    let cwd: String
    let state: String
    let stateSince: Double
    let lastUpdated: Double
    let toolName: String
    let lastEvent: String
    let terminal: String
    let itermSessionId: String
    let kittyWindowId: String
    let kittyListenOn: String

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

    /// Last hook was PreToolUse for a non-Bash tool and nothing has updated in >4s —
    /// Claude is almost certainly waiting for the user to approve/deny a confirmation.
    /// Bash is excluded because it can run legitimately for minutes.
    var needsConfirmation: Bool {
        guard isWorking && lastEvent == "PreToolUse" else { return false }
        return Date().timeIntervalSince1970 - lastUpdated > 4
    }

    /// Session has been in "waiting" state for >5 minutes — effectively idle.
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
        case terminal
        case itermSessionId = "iterm_session_id"
        case kittyWindowId = "kitty_window_id"
        case kittyListenOn = "kitty_listen_on"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId    = try c.decode(String.self, forKey: .sessionId)
        cwd          = try c.decode(String.self, forKey: .cwd)
        state        = try c.decode(String.self, forKey: .state)
        stateSince   = try c.decode(Double.self, forKey: .stateSince)
        lastUpdated  = try c.decode(Double.self, forKey: .lastUpdated)
        toolName     = try c.decodeIfPresent(String.self, forKey: .toolName) ?? ""
        lastEvent    = try c.decodeIfPresent(String.self, forKey: .lastEvent) ?? ""
        terminal     = try c.decodeIfPresent(String.self, forKey: .terminal) ?? "iterm2"
        itermSessionId  = try c.decodeIfPresent(String.self, forKey: .itermSessionId) ?? ""
        kittyWindowId   = try c.decodeIfPresent(String.self, forKey: .kittyWindowId) ?? ""
        kittyListenOn   = try c.decodeIfPresent(String.self, forKey: .kittyListenOn) ?? ""
    }
}
