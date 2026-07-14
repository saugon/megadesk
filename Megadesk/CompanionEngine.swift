import Foundation
import Observation

@Observable
final class CompanionEngine {
    static let shared = CompanionEngine()

    var currentMessage: CompanionMessage?
    /// The most recently emitted message, kept after dismissal so it can be
    /// repeated on demand (double-clicking the pet).
    private(set) var lastMessage: CompanionMessage?

    /// Rolling buffer of the most-recently-emitted messages, newest first.
    /// Used by the in-app history view and the popover on the pet panel.
    /// In-memory only — clears on app restart.
    private(set) var recentMessages: [CompanionMessage] = []
    private static let recentMessagesLimit = 10

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

    // Per-session snapshot from the previous evaluation tick — used by the
    // event-driven rules (sessionNew, sessionFinishedAfterLong,
    // sessionConfirmation) to detect transitions rather than threshold
    // crossings.
    private struct SessionSnapshot {
        var isWorking: Bool
        var needsConfirmation: Bool
        var workingTimeInState: TimeInterval  // captured while still working, used when a session leaves working
    }
    private var previousSessions: [String: SessionSnapshot] = [:]
    private var seenSessionIds = Set<String>()

    // Per-PR snapshot for prOpened / prClosedWithoutMerge / prCIRecovered /
    // prCIRegressed. PR id → previous (state, ciStatus).
    private struct PRSnapshot {
        var state: String
        var ci: String
    }
    private var previousPRs: [String: PRSnapshot] = [:]
    private var seenPRIds = Set<String>()

    // Shared cooldown for *new* (optional) rules — see VoiceTemplates. Existing
    // legacy rules each keep their independent cooldown so the user-set
    // thresholds in Settings still apply unchanged.
    private static let newRulesGlobalCooldown: TimeInterval = 60
    private var lastNewRuleFiredAt: Date?

    // Last time *any* message (legacy or new) was emitted — used by the
    // ambient cadence so the pet doesn't talk over itself.
    private var lastAnyMessageAt: Date?
    private static let ambientQuietWindow: TimeInterval = 30 * 60
    private static let stretchIdleThreshold: TimeInterval = 90 * 60

    // Time-of-day buckets (hour ranges). Each bucket fires at most once per
    // calendar day.
    private enum TimeBucket: String, CaseIterable {
        case morning, afternoonSlump, endOfDay, lateNight
        var hourRange: ClosedRange<Int> {
            switch self {
            case .morning:        return 8...10
            case .afternoonSlump: return 14...16
            case .endOfDay:       return 18...20
            case .lateNight:      return 22...23
            }
        }
    }

    // MARK: - Persisted state

    struct PersistedState: Codable {
        var lastGreetedDate: String = ""
        var firedRules: [String: String] = [:]
        var prLastKnownStatus: [String: String] = [:]
        /// "<bucket>" → "yyyy-MM-dd" — last day each time-of-day bucket fired.
        var lastTimeOfDayDate: [String: String] = [:]
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
        let v = activeVoice

        // (text, ghostState, subject-to-highlight)
        let candidates: [(String, GhostState, String?)] = [
            (v.waitingTooLong.filling(["name": sessionName, "duration": "23 min"]),                    .alert, sessionName),
            (v.multipleWaiting.filling(["count": "\(max(3, sessions.count))", "oldest": sessionName]), .alert, sessionName),
            (v.stuckWorking.filling(["name": sessionName, "duration": "45 min"]),                      .alert, sessionName),
            (v.prCIFailing.filling(["prTitle": sessionName]),                                          .alert, sessionName),
            (v.prConflicts.filling(["prTitle": otherName]),                                            .alert, otherName),
            (v.userIdle,                                                                               .idle,  nil),
            (v.allForgotten,                                                                           .idle,  nil),
            (v.firstSessionOfDay,                                                                      .happy, nil),
            (v.prMerged.filling(["prTitle": sessionName]),                                             .happy, sessionName),
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

    private func emit(_ message: CompanionMessage, recordInHistory: Bool = true) {
        currentMessage = message
        lastMessage = message
        lastAnyMessageAt = Date()
        if recordInHistory { recordRecent(message) }
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.currentMessage = nil
            self?.dismissTimer = nil
        }
    }

    private func recordRecent(_ message: CompanionMessage) {
        recentMessages.insert(message, at: 0)
        if recentMessages.count > Self.recentMessagesLimit {
            recentMessages.removeLast(recentMessages.count - Self.recentMessagesLimit)
        }
    }

    /// Returns true if the global cooldown shared by all *new* (optional)
    /// rules still applies. Call this before emitting any rule defined as
    /// optional in `VoiceTemplates`.
    private func newRuleCooldownActive() -> Bool {
        guard let last = lastNewRuleFiredAt else { return false }
        return Date().timeIntervalSince(last) < Self.newRulesGlobalCooldown
    }

    /// Marks the global new-rules cooldown as "just fired" and emits the
    /// message. Use this for any optional rule.
    private func emitNewRule(_ message: CompanionMessage) {
        lastNewRuleFiredAt = Date()
        emit(message)
    }

    /// Re-emits the last message (triggered by double-clicking the pet).
    func repeatLastMessage() {
        guard let last = lastMessage else { return }
        // Re-wrap so SwiftUI sees a new identity (triggers re-render).
        emit(CompanionMessage(
            text: last.text,
            ghostState: last.ghostState,
            ruleId: last.ruleId,
            subject: last.subject,
            timestamp: last.timestamp
        ), recordInHistory: false)
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

        // New event-driven rules. These read the previous-tick snapshot to
        // detect transitions, so they must run BEFORE we refresh the snapshot.
        checkSessionNew(sessions)
        checkSessionFinishedAfterLong(sessions)
        checkSessionConfirmation(sessions)
        checkPRTransitionRules(prs)

        refreshSnapshots(sessions: sessions, prs: prs)
    }

    // MARK: - Timer rules

    private func evaluateTimerRules() {
        let sessions = StatusStore.shared.sessions
        checkWaitingTooLong(sessions)
        checkStuckWorking(sessions)
        checkUserIdle(sessions)

        // New timer-driven rules. Each respects the global new-rules cooldown.
        checkSessionWorkingLong(sessions)
        checkSessionWorkingVeryLong(sessions)
        checkSessionConfirmationStuck(sessions)
        checkStretchReminder(sessions)
        checkTimeOfDay()
        checkAmbient(sessions)
    }

    // MARK: - Snapshot refresh

    private func refreshSnapshots(sessions: [Session], prs: [TrackedPR]) {
        var newSessionMap: [String: SessionSnapshot] = [:]
        for s in sessions {
            newSessionMap[s.sessionId] = SessionSnapshot(
                isWorking: s.isWorking,
                needsConfirmation: s.needsConfirmation,
                workingTimeInState: s.isWorking ? s.timeInState : (previousSessions[s.sessionId]?.workingTimeInState ?? 0)
            )
            seenSessionIds.insert(s.sessionId)
        }
        previousSessions = newSessionMap

        var newPRMap: [String: PRSnapshot] = [:]
        for pr in prs {
            guard let data = pr.data else { continue }
            newPRMap[pr.id] = PRSnapshot(state: data.state, ci: data.ciStatus.rawString)
            seenPRIds.insert(pr.id)
        }
        previousPRs = newPRMap
    }

    // MARK: - Voice lookup

    private var activeVoice: CompanionPetDefinition.VoiceTemplates {
        let id = AppSettings.shared.companionPetId
        let registry = CompanionPetRegistry.shared
        return (registry.pet(id: id) ?? registry.defaultPet).voice
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
                text: activeVoice.waitingTooLong.filling(["name": name, "duration": duration]),
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
                text: activeVoice.multipleWaiting.filling(["count": "\(count)", "oldest": name]),
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
                text: activeVoice.stuckWorking.filling(["name": name, "duration": duration]),
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
                        text: activeVoice.prCIFailing.filling(["prTitle": data.title]),
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
                        text: activeVoice.prConflicts.filling(["prTitle": data.title]),
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
                        text: activeVoice.prMerged.filling(["prTitle": data.title]),
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
        emit(CompanionMessage(text: activeVoice.userIdle, ghostState: .idle, ruleId: "userIdle"))
    }

    // MARK: - Rule 7: allForgotten

    private func checkAllForgotten(_ sessions: [Session]) {
        guard !sessions.isEmpty else { return }
        let allForgotten = sessions.allSatisfy(\.isForgotten)

        if allForgotten && !wasAllForgotten {
            emit(CompanionMessage(
                text: activeVoice.allForgotten,
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
            text: activeVoice.firstSessionOfDay,
            ghostState: .happy,
            ruleId: "firstSessionOfDay"
        ))
    }

    // MARK: - New rule: sessionNew

    private func checkSessionNew(_ sessions: [Session]) {
        guard !newRuleCooldownActive(), let template = activeVoice.sessionNew else {
            // Even if we don't fire, mark sessions as seen so we don't replay
            // them as "new" the moment a pet that defines this template is
            // selected.
            return
        }
        let store = StatusStore.shared
        for session in sessions {
            // First time we ever see this session id (this process lifetime).
            // Skip the very first run after launch — otherwise every existing
            // session shows up as "new".
            guard !seenSessionIds.contains(session.sessionId),
                  !previousSessions.isEmpty else { continue }
            let name = store.displayName(for: session)
            emitNewRule(CompanionMessage(
                text: template.filling(["name": name]),
                ghostState: .happy,
                ruleId: "sessionNew",
                subject: name
            ))
            return
        }
    }

    // MARK: - New rule: sessionFinishedAfterLong

    private func checkSessionFinishedAfterLong(_ sessions: [Session]) {
        guard !newRuleCooldownActive(), let template = activeVoice.sessionFinishedAfterLong else { return }
        let store = StatusStore.shared
        let workingThreshold: TimeInterval = 10 * 60  // session must have been working at least this long to count

        for session in sessions {
            guard let prev = previousSessions[session.sessionId] else { continue }
            // Transition: was working, now not working (and not forgotten).
            guard prev.isWorking, !session.isWorking, !session.isForgotten else { continue }
            guard prev.workingTimeInState >= workingThreshold else { continue }

            let name = store.displayName(for: session)
            emitNewRule(CompanionMessage(
                text: template.filling([
                    "name": name,
                    "duration": formatDuration(prev.workingTimeInState)
                ]),
                ghostState: .happy,
                ruleId: "sessionFinishedAfterLong",
                subject: name
            ))
            return
        }
    }

    // MARK: - New rule: sessionConfirmation

    private func checkSessionConfirmation(_ sessions: [Session]) {
        guard !newRuleCooldownActive(), let template = activeVoice.sessionConfirmation else { return }
        let store = StatusStore.shared

        for session in sessions {
            let prev = previousSessions[session.sessionId]
            // Transition into needsConfirmation.
            guard session.needsConfirmation, prev?.needsConfirmation != true else { continue }

            let name = store.displayName(for: session)
            emitNewRule(CompanionMessage(
                text: template.filling(["name": name]),
                ghostState: .alert,
                ruleId: "sessionConfirmation",
                subject: name
            ))
            return
        }
    }

    // MARK: - New rule: prOpened / prClosedWithoutMerge / prCIRecovered / prCIRegressed

    private func checkPRTransitionRules(_ prs: [TrackedPR]) {
        let v = activeVoice

        for pr in prs {
            guard let data = pr.data else { continue }
            let id = pr.id
            let prev = previousPRs[id]

            // prOpened — new id we haven't seen this run, and we already had at
            // least one prior tick (so launch-time backfill doesn't fire it).
            if !seenPRIds.contains(id), !previousPRs.isEmpty,
               let template = v.prOpened, !newRuleCooldownActive() {
                emitNewRule(CompanionMessage(
                    text: template.filling(["prTitle": data.title]),
                    ghostState: .happy,
                    ruleId: "prOpened",
                    subject: data.title
                ))
                continue  // one PR transition per tick is enough
            }

            // prClosedWithoutMerge — state transition into CLOSED.
            if data.isClosed, prev?.state != "CLOSED",
               let template = v.prClosedWithoutMerge, !newRuleCooldownActive() {
                emitNewRule(CompanionMessage(
                    text: template.filling(["prTitle": data.title]),
                    ghostState: .idle,
                    ruleId: "prClosedWithoutMerge",
                    subject: data.title
                ))
                continue
            }

            // CI flips — only if previous CI was known and different.
            let currentCI = data.ciStatus.rawString
            let prevCI = prev?.ci

            if currentCI == "passing", prevCI == "failing",
               let template = v.prCIRecovered, !newRuleCooldownActive() {
                emitNewRule(CompanionMessage(
                    text: template.filling(["prTitle": data.title]),
                    ghostState: .happy,
                    ruleId: "prCIRecovered",
                    subject: data.title
                ))
                continue
            }
            if currentCI == "failing", prevCI == "passing",
               let template = v.prCIRegressed, !newRuleCooldownActive() {
                emitNewRule(CompanionMessage(
                    text: template.filling(["prTitle": data.title]),
                    ghostState: .alert,
                    ruleId: "prCIRegressed",
                    subject: data.title
                ))
                continue
            }
        }
    }

    // MARK: - New rule: sessionWorkingLong / sessionWorkingVeryLong

    private func checkSessionWorkingLong(_ sessions: [Session]) {
        checkWorkingDurationTier(
            sessions: sessions,
            template: activeVoice.sessionWorkingLong,
            threshold: 30 * 60,
            upperBound: 2 * 60 * 60,
            ruleId: "sessionWorkingLong"
        )
    }

    private func checkSessionWorkingVeryLong(_ sessions: [Session]) {
        checkWorkingDurationTier(
            sessions: sessions,
            template: activeVoice.sessionWorkingVeryLong,
            threshold: 2 * 60 * 60,
            upperBound: .infinity,
            ruleId: "sessionWorkingVeryLong"
        )
    }

    private func checkWorkingDurationTier(
        sessions: [Session],
        template: String?,
        threshold: TimeInterval,
        upperBound: TimeInterval,
        ruleId: String
    ) {
        guard let template, !newRuleCooldownActive() else { return }
        let store = StatusStore.shared

        for session in sessions {
            guard session.isWorking,
                  session.timeInState >= threshold,
                  session.timeInState < upperBound else {
                persistedState.firedRules.removeValue(forKey: "\(ruleId):\(session.sessionId)")
                continue
            }
            let key = "\(ruleId):\(session.sessionId)"
            guard persistedState.firedRules[key] == nil else { continue }

            let name = store.displayName(for: session)
            persistedState.firedRules[key] = ISO8601DateFormatter().string(from: Date())
            saveState()
            emitNewRule(CompanionMessage(
                text: template.filling([
                    "name": name,
                    "duration": formatDuration(session.timeInState)
                ]),
                ghostState: .alert,
                ruleId: ruleId,
                subject: name
            ))
            return
        }
    }

    // MARK: - New rule: sessionConfirmationStuck

    private func checkSessionConfirmationStuck(_ sessions: [Session]) {
        guard let template = activeVoice.sessionConfirmationStuck, !newRuleCooldownActive() else { return }
        let store = StatusStore.shared
        let threshold: TimeInterval = 5 * 60

        for session in sessions {
            // `timeInState` tracks how long the session has been in its
            // underlying state (e.g. "working"), but `needsConfirmation` is a
            // derived signal that flips on after a PreToolUse hook stalls —
            // the underlying state never changed, so `timeInState` would
            // pre-date the confirmation. `lastUpdated` is the timestamp of
            // that PreToolUse event and stays put until the user answers,
            // making `now - lastUpdated` the actual time waiting on input.
            let timeWaiting = Date().timeIntervalSince1970 - session.lastUpdated
            guard session.needsConfirmation, timeWaiting >= threshold else {
                persistedState.firedRules.removeValue(forKey: "sessionConfirmationStuck:\(session.sessionId)")
                continue
            }
            let key = "sessionConfirmationStuck:\(session.sessionId)"
            guard persistedState.firedRules[key] == nil else { continue }

            let name = store.displayName(for: session)
            persistedState.firedRules[key] = ISO8601DateFormatter().string(from: Date())
            saveState()
            emitNewRule(CompanionMessage(
                text: template.filling([
                    "name": name,
                    "duration": formatDuration(timeWaiting)
                ]),
                ghostState: .alert,
                ruleId: "sessionConfirmationStuck",
                subject: name
            ))
            return
        }
    }

    // MARK: - New rule: stretchReminder

    private func checkStretchReminder(_ sessions: [Session]) {
        guard let template = activeVoice.stretchReminder, !newRuleCooldownActive() else { return }
        let active = sessions.filter { !$0.isForgotten }
        guard !active.isEmpty else { return }

        let latestStateSince = sessions.map(\.stateSince).max() ?? 0
        let idle = Date().timeIntervalSince1970 - latestStateSince
        guard idle >= Self.stretchIdleThreshold else {
            persistedState.firedRules.removeValue(forKey: "stretchReminder")
            return
        }

        let key = "stretchReminder"
        if let last = persistedState.firedRules[key],
           let lastDate = ISO8601DateFormatter().date(from: last),
           Date().timeIntervalSince(lastDate) < Self.stretchIdleThreshold {
            return
        }
        persistedState.firedRules[key] = ISO8601DateFormatter().string(from: Date())
        saveState()
        emitNewRule(CompanionMessage(
            text: template.filling(["duration": formatDuration(idle)]),
            ghostState: .idle,
            ruleId: "stretchReminder"
        ))
    }

    // MARK: - New rule: time-of-day

    private func checkTimeOfDay() {
        guard !newRuleCooldownActive() else { return }
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let today = Self.dateString(from: now)

        for bucket in TimeBucket.allCases where bucket.hourRange.contains(hour) {
            // Skip if we already fired this bucket today.
            if persistedState.lastTimeOfDayDate[bucket.rawValue] == today { continue }

            let template: String?
            switch bucket {
            case .morning:        template = activeVoice.morningGreeting
            case .afternoonSlump: template = activeVoice.afternoonSlump
            case .endOfDay:       template = activeVoice.endOfDay
            case .lateNight:      template = activeVoice.lateNight
            }
            guard let text = template else { continue }

            persistedState.lastTimeOfDayDate[bucket.rawValue] = today
            saveState()
            let ghost: GhostState = bucket == .lateNight ? .idle : .happy
            emitNewRule(CompanionMessage(text: text, ghostState: ghost, ruleId: "timeOfDay.\(bucket.rawValue)"))
            return
        }
    }

    // MARK: - New rule: ambient (filler / bored / humor / observation)

    private func checkAmbient(_ sessions: [Session]) {
        guard !newRuleCooldownActive() else { return }
        // Need a long quiet window since the previous *any* message before
        // pulling the pet in from boredom.
        if let last = lastAnyMessageAt,
           Date().timeIntervalSince(last) < Self.ambientQuietWindow { return }

        let v = activeVoice
        var pool: [(text: String, subject: String?)] = []
        v.ambientFiller?.forEach { pool.append(($0, nil)) }
        v.ambientBored?.forEach { pool.append(($0, nil)) }
        v.ambientHumor?.forEach { pool.append(($0, nil)) }

        if let observations = v.ambientObservation {
            let count = sessions.filter { !$0.isForgotten }.count
            for line in observations {
                pool.append((line.filling(["count": "\(count)"]), nil))
            }
        }

        guard let pick = pool.randomElement() else { return }
        emitNewRule(CompanionMessage(
            text: pick.text,
            ghostState: .idle,
            ruleId: "ambient",
            subject: pick.subject
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
