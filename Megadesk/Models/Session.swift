import Foundation
import Darwin

struct Session: Identifiable, Codable {
    let sessionId: String
    let cwd: String
    let state: String
    let stateSince: Double
    let createdAt: Double?
    let lastUpdated: Double
    let toolName: String
    let lastEvent: String
    let itermSessionId: String
    let claudePid: Int32?

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

    /// True when Claude is waiting for the user to approve/deny a tool call.
    /// For non-Bash tools: >4s since PreToolUse with no update is conclusive.
    /// For Bash: checks the process tree — when the confirmation dialog is showing,
    /// Bash hasn't launched yet so there's no child process under claude.
    /// When Bash is legitimately running it appears as a child of the claude process.
    var needsConfirmation: Bool {
        guard isWorking && lastEvent == "PreToolUse" else { return false }
        guard Date().timeIntervalSince1970 - lastUpdated > 4 else { return false }
        if toolName == "Bash" {
            guard let pid = claudePid else { return false }
            return !hasChildProcess(parentPid: pid)
        }
        return true
    }

    /// Returns true if the given PID has at least one child process.
    /// Uses sysctl(KERN_PROC_PPID) which returns only children of the given PID —
    /// far cheaper than iterating all processes.
    private func hasChildProcess(parentPid: Int32) -> Bool {
        // [CTL_KERN=1, KERN_PROC=14, KERN_PROC_PPID=7, parentPid]
        // KERN_PROC_PPID is not bridged to Swift so use its raw value.
        var mib: [Int32] = [1, 14, 7, parentPid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return false }
        return size >= MemoryLayout<kinfo_proc>.stride
    }

    /// Session has been in "waiting" state for longer than the configured threshold — effectively idle.
    var isForgotten: Bool {
        !isWorking && timeInState > TimeInterval(AppSettings.shared.forgottenMinutes * 60)
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case state
        case stateSince = "state_since"
        case createdAt = "created_at"
        case lastUpdated = "last_updated"
        case toolName = "tool_name"
        case lastEvent = "last_event"
        case itermSessionId = "iterm_session_id"
        case claudePid = "claude_pid"
    }
}
