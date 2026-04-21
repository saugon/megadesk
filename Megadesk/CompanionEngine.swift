import Foundation
import Observation

@Observable
final class CompanionEngine {
    static let shared = CompanionEngine()

    var currentMessage: CompanionMessage?
    /// The most recently emitted message, kept after dismissal so it can be
    /// repeated on demand (double-clicking the pet).
    private(set) var lastMessage: CompanionMessage?

    var ghostState: GhostState {
        currentMessage?.ghostState ?? .idle
    }

    private var periodicTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var dismissTimer: Timer?
    private var persistedState: PersistedState
    private let stateFileURL: URL
    private let ioQueue = DispatchQueue(label: "com.megadesk.companion-io")

    // Edge-detection flags for threshold-based rules
    private var wasAboveMultipleWaitingThreshold = false
    private var wasAllForgotten = false

    // MARK: - Persisted state

    struct PersistedState: Codable {
        var lastGreetedDate: String = ""
        var firedRules: [String: String] = [:]
        var prLastKnownStatus: [String: String] = [:]
    }

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        stateFileURL = home.appendingPathComponent(".claude/megadesk/companion-state.json")
        persistedState = PersistedState()
        loadState()

        if AppSettings.shared.companionEnabled {
            start()
        }
        observeEnabledSetting()
    }

    // MARK: - Lifecycle

    func start() {
        observeStore()
        startPeriodicTimer()
    }

    func stop() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    func dismissMessage() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        currentMessage = nil
    }

    // MARK: - Test

    func emitTestMessage() {
        let store = StatusStore.shared
        let sessions = store.sessions
        let sessionName = sessions.randomElement().map { store.displayName(for: $0) } ?? "session"
        let otherName  = sessions.randomElement().map { store.displayName(for: $0) } ?? "project"

        // (text, ghostState, subject-to-highlight)
        let candidates: [(String, GhostState, String?)] = [
            ("Hey \u{2014} \(sessionName) has been waiting for you for 23 min.", .alert, sessionName),
            ("You have \(max(3, sessions.count)) sessions waiting. Oldest is \(sessionName).", .alert, sessionName),
            ("\(sessionName) has been working for 45 min. Might be stuck.", .alert, sessionName),
            ("CI is failing on \(sessionName).", .alert, sessionName),
            ("\(otherName) has merge conflicts.", .alert, otherName),
            ("Still there?", .idle, nil),
            ("All quiet. Good time for a break.", .idle, nil),
            ("Hey! Let's get to work.", .happy, nil),
            ("\(sessionName) merged. Nice.", .happy, sessionName),
        ]
        let pick = candidates.randomElement()!
        emit(CompanionMessage(text: pick.0, ghostState: pick.1, ruleId: "test", subject: pick.2))
    }

    // MARK: - Observation

    private func observeEnabledSetting() {
        withObservationTracking {
            _ = AppSettings.shared.companionEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AppSettings.shared.companionEnabled {
                    self.start()
                } else {
                    self.stop()
                    self.dismissMessage()
                }
                self.observeEnabledSetting()
            }
        }
    }

    private func observeStore() {
        guard AppSettings.shared.companionEnabled else { return }
        withObservationTracking {
            _ = StatusStore.shared.sessions
            _ = StatusStore.shared.trackedPRs
        } onChange: {
            Task { @MainActor [weak self] in
                self?.scheduleEvaluation()
                self?.observeStore()
            }
        }
    }

    private func scheduleEvaluation() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateStateChangeRules()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func startPeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard AppSettings.shared.companionEnabled else { return }
            self?.evaluateTimerRules()
        }
    }

    // MARK: - Emit

    private func emit(_ message: CompanionMessage) {
        currentMessage = message
        lastMessage = message
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.currentMessage = nil
            self?.dismissTimer = nil
        }
    }

    /// Re-emits the last message (triggered by double-clicking the pet).
    func repeatLastMessage() {
        guard let last = lastMessage else { return }
        // Re-wrap so SwiftUI sees a new identity (triggers re-render).
        emit(CompanionMessage(
            text: last.text,
            ghostState: last.ghostState,
            ruleId: last.ruleId,
            subject: last.subject
        ))
    }

    // MARK: - State-change rules

    private func evaluateStateChangeRules() {
        let store = StatusStore.shared
        let sessions = store.sessions
        let prs = store.trackedPRs

        checkFirstSessionOfDay(sessions)
        checkMultipleWaiting(sessions)
        checkAllForgotten(sessions)
        checkPRRules(prs)
    }

    // MARK: - Timer rules

    private func evaluateTimerRules() {
        let sessions = StatusStore.shared.sessions
        checkWaitingTooLong(sessions)
        checkStuckWorking(sessions)
        checkUserIdle(sessions)
    }

    // MARK: - Rule 1: waitingTooLong

    private func checkWaitingTooLong(_ sessions: [Session]) {
        let threshold = TimeInterval(AppSettings.shared.companionWaitingThresholdMinutes * 60)
        let store = StatusStore.shared

        for session in sessions {
            guard !session.isWorking, !session.isForgotten,
                  session.timeInState > threshold else {
                // Session is not waiting long enough — clear cooldown so it can re-fire
                // if it leaves and re-enters waiting
                persistedState.firedRules.removeValue(forKey: "waitingTooLong:\(session.sessionId)")
                continue
            }

            let key = "waitingTooLong:\(session.sessionId)"
            guard persistedState.firedRules[key] == nil else { continue }

            let name = store.displayName(for: session)
            let duration = formatDuration(session.timeInState)
            persistedState.firedRules[key] = ISO8601DateFormatter().string(from: Date())
            saveState()
            emit(CompanionMessage(
                text: "Hey \u{2014} \(name) has been waiting for you for \(duration).",
                ghostState: .alert,
                ruleId: "waitingTooLong",
                subject: name
            ))
            return
        }
    }

    // MARK: - Rule 2: multipleWaiting

    private func checkMultipleWaiting(_ sessions: [Session]) {
        let waiting = sessions.filter { !$0.isWorking && !$0.isForgotten }
        let count = waiting.count
        let isAbove = count >= 3

        if isAbove && !wasAboveMultipleWaitingThreshold {
            let oldest = waiting.max(by: { $0.timeInState < $1.timeInState })
            let name = oldest.map { StatusStore.shared.displayName(for: $0) } ?? "unknown"
            emit(CompanionMessage(
                text: "You have \(count) sessions waiting. Oldest is \(name).",
                ghostState: .alert,
                ruleId: "multipleWaiting",
                subject: name
            ))
        }
        wasAboveMultipleWaitingThreshold = isAbove
    }

    // MARK: - Rule 3: stuckWorking

    private func checkStuckWorking(_ sessions: [Session]) {
        let threshold = TimeInterval(AppSettings.shared.companionStuckWorkingThresholdMinutes * 60)
        let store = StatusStore.shared

        for session in sessions {
            guard session.isWorking, session.timeInState > threshold else {
                persistedState.firedRules.removeValue(forKey: "stuckWorking:\(session.sessionId)")
                continue
            }

            let key = "stuckWorking:\(session.sessionId)"
            guard persistedState.firedRules[key] == nil else { continue }

            let name = store.displayName(for: session)
            let duration = formatDuration(session.timeInState)
            persistedState.firedRules[key] = ISO8601DateFormatter().string(from: Date())
            saveState()
            emit(CompanionMessage(
                text: "\(name) has been working for \(duration). Might be stuck.",
                ghostState: .alert,
                ruleId: "stuckWorking",
                subject: name
            ))
            return
        }
    }

    // MARK: - Rule 4: prCIFailing

    private func checkPRRules(_ prs: [TrackedPR]) {
        for pr in prs {
            guard let data = pr.data else { continue }
            let id = pr.id

            // Rule 4 — CI failing
            let ciKey = "\(id).ci"
            let currentCI = data.ciStatus.rawString
            let previousCI = persistedState.prLastKnownStatus[ciKey]

            if data.ciStatus == .failing && previousCI != "failing" {
                let firedKey = "prCIFailing:\(id)"
                if persistedState.firedRules[firedKey] == nil {
                    persistedState.firedRules[firedKey] = ISO8601DateFormatter().string(from: Date())
                    emit(CompanionMessage(
                        text: "CI is failing on \(data.title).",
                        ghostState: .alert,
                        ruleId: "prCIFailing",
                        subject: data.title
                    ))
                }
            } else if data.ciStatus != .failing {
                persistedState.firedRules.removeValue(forKey: "prCIFailing:\(id)")
            }
            persistedState.prLastKnownStatus[ciKey] = currentCI

            // Rule 5 — conflicts
            let mergeKey = "\(id).mergeable"
            let previousMergeable = persistedState.prLastKnownStatus[mergeKey]

            if data.hasConflicts && previousMergeable != "CONFLICTING" {
                let firedKey = "prConflicts:\(id)"
                if persistedState.firedRules[firedKey] == nil {
                    persistedState.firedRules[firedKey] = ISO8601DateFormatter().string(from: Date())
                    emit(CompanionMessage(
                        text: "\(data.title) has merge conflicts.",
                        ghostState: .alert,
                        ruleId: "prConflicts",
                        subject: data.title
                    ))
                }
            } else if !data.hasConflicts {
                persistedState.firedRules.removeValue(forKey: "prConflicts:\(id)")
            }
            persistedState.prLastKnownStatus[mergeKey] = data.mergeable

            // Rule 9 — merged
            let stateKey = "\(id).state"
            let previousState = persistedState.prLastKnownStatus[stateKey]

            if data.isMerged && previousState != "MERGED" {
                let firedKey = "prMerged:\(id)"
                if persistedState.firedRules[firedKey] == nil {
                    persistedState.firedRules[firedKey] = ISO8601DateFormatter().string(from: Date())
                    emit(CompanionMessage(
                        text: "\(data.title) merged. Nice.",
                        ghostState: .happy,
                        ruleId: "prMerged",
                        subject: data.title
                    ))
                }
            }
            persistedState.prLastKnownStatus[stateKey] = data.state
        }
        saveState()
    }

    // MARK: - Rule 6: userIdle

    private func checkUserIdle(_ sessions: [Session]) {
        let threshold = TimeInterval(AppSettings.shared.companionIdleThresholdMinutes * 60)
        let activeSessions = sessions.filter { !$0.isForgotten }
        guard !activeSessions.isEmpty else { return }

        let latestStateSince = sessions.map(\.stateSince).max() ?? 0
        let timeSinceLastTransition = Date().timeIntervalSince1970 - latestStateSince

        guard timeSinceLastTransition > threshold else {
            persistedState.firedRules.removeValue(forKey: "userIdle")
            saveState()
            return
        }

        let key = "userIdle"
        if let lastFired = persistedState.firedRules[key],
           let lastFiredDate = ISO8601DateFormatter().date(from: lastFired) {
            if Date().timeIntervalSince(lastFiredDate) < threshold { return }
        }

        persistedState.firedRules[key] = ISO8601DateFormatter().string(from: Date())
        saveState()
        emit(CompanionMessage(text: "Still there?", ghostState: .idle, ruleId: "userIdle"))
    }

    // MARK: - Rule 7: allForgotten

    private func checkAllForgotten(_ sessions: [Session]) {
        guard !sessions.isEmpty else { return }
        let allForgotten = sessions.allSatisfy(\.isForgotten)

        if allForgotten && !wasAllForgotten {
            emit(CompanionMessage(
                text: "All quiet. Good time for a break.",
                ghostState: .idle,
                ruleId: "allForgotten"
            ))
        }
        wasAllForgotten = allForgotten
    }

    // MARK: - Rule 8: firstSessionOfDay

    private func checkFirstSessionOfDay(_ sessions: [Session]) {
        guard !sessions.isEmpty else { return }

        let today = Self.dateString(from: Date())
        guard persistedState.lastGreetedDate != today else { return }

        persistedState.lastGreetedDate = today
        saveState()
        emit(CompanionMessage(
            text: "Hey! Let's get to work.",
            ghostState: .happy,
            ruleId: "firstSessionOfDay"
        ))
    }

    // MARK: - Persistence

    private func loadState() {
        ioQueue.sync {
            guard let data = try? Data(contentsOf: stateFileURL),
                  let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
            self.persistedState = decoded
        }
    }

    private func saveState() {
        let state = persistedState
        let url = stateFileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
    }

    private static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - CIStatus raw string helper

extension PullRequest.CIStatus {
    var rawString: String {
        switch self {
        case .passing: return "passing"
        case .pending: return "pending"
        case .failing: return "failing"
        case .none:    return "none"
        }
    }
}
