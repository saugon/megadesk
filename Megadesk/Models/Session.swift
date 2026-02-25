import Foundation

struct Session: Identifiable, Codable {
    let sessionId: String
    let cwd: String
    let state: String
    let stateSince: Double
    let createdAt: Double?
    let lastUpdated: Double
    let toolName: String
    let lastEvent: String
    let terminalSessionId: String
    let claudePid: Int32?
    let provider: Provider

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
    /// For Codex, approval-requested events set needsConfirmation via last_event.
    var needsConfirmation: Bool {
        if provider == .codex {
            return lastEvent == "approval-requested"
        }
        guard isWorking && lastEvent == "PreToolUse" else { return false }
        return Date().timeIntervalSince1970 - lastUpdated > 4
    }

    /// Session has been in "waiting" state for longer than the configured threshold — effectively idle.
    var isForgotten: Bool {
        !isWorking && timeInState > TimeInterval(AppSettings.shared.forgottenMinutes * 60)
    }

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case state
        case stateSince = "state_since"
        case createdAt = "created_at"
        case lastUpdated = "last_updated"
        case toolName = "tool_name"
        case lastEvent = "last_event"
        case terminalSessionId = "terminal_session_id"
        case itermSessionId = "iterm_session_id"
        case claudePid = "claude_pid"
        case provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId   = try c.decode(String.self, forKey: .sessionId)
        cwd         = try c.decode(String.self, forKey: .cwd)
        state       = try c.decode(String.self, forKey: .state)
        stateSince  = try c.decode(Double.self, forKey: .stateSince)
        createdAt   = try c.decodeIfPresent(Double.self, forKey: .createdAt)
        lastUpdated = try c.decode(Double.self, forKey: .lastUpdated)
        toolName    = try c.decode(String.self, forKey: .toolName)
        lastEvent   = try c.decode(String.self, forKey: .lastEvent)
        claudePid   = try c.decodeIfPresent(Int32.self, forKey: .claudePid)
        provider    = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude

        // Accept both "terminal_session_id" (new) and "iterm_session_id" (legacy)
        if let tid = try c.decodeIfPresent(String.self, forKey: .terminalSessionId) {
            terminalSessionId = tid
        } else {
            terminalSessionId = try c.decode(String.self, forKey: .itermSessionId)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId,          forKey: .sessionId)
        try c.encode(cwd,                forKey: .cwd)
        try c.encode(state,              forKey: .state)
        try c.encode(stateSince,         forKey: .stateSince)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(lastUpdated,        forKey: .lastUpdated)
        try c.encode(toolName,           forKey: .toolName)
        try c.encode(lastEvent,          forKey: .lastEvent)
        try c.encode(terminalSessionId,  forKey: .terminalSessionId)
        try c.encodeIfPresent(claudePid, forKey: .claudePid)
        try c.encode(provider,           forKey: .provider)
    }
}
