import Foundation
import AppKit
import Observation
import Darwin

@Observable
final class StatusStore {
    static let shared = StatusStore()

    var sessions: [Session] = []
    var tick: Int = 0  // increments every second to force time re-renders
    var spinnerTick: Int = 0  // increments every 200ms for spinner animation
    var customNames: [String: String] = [:]  // terminalSessionId → custom display name

    // MARK: PR Tracking
    var trackedPRs: [TrackedPR] = []

    /// The tracked PRs in display order. `trackedPRs` itself stays in the order
    /// they were added, which is what gets persisted and what "As added" shows.
    var sortedTrackedPRs: [TrackedPR] {
        guard AppSettings.shared.prSortOrder == .byState else { return trackedPRs }
        // Sorting on the rank alone would reshuffle equals on every refresh, so
        // the original position breaks ties and same-state PRs keep their order.
        return trackedPRs.enumerated()
            .sorted { a, b in
                let ra = Self.stateRank(a.element), rb = Self.stateRank(b.element)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    /// Whatever needs attention first. A PR whose data hasn't arrived yet sits
    /// below the actionable ones and above the ones already settled.
    private static func stateRank(_ tracked: TrackedPR) -> Int {
        guard let pr = tracked.data else { return 6 }
        if pr.isMerged { return 7 }
        if pr.isClosed { return 8 }
        if pr.ciStatus == .failing { return 0 }
        if pr.hasConflicts { return 1 }
        // The queue kicked it back: it needs the author, like a failure does.
        if pr.isQueued && pr.isQueueBlocked { return 2 }
        if pr.ciStatus == .pending { return 3 }
        // Waiting its turn in the queue: nothing to do but let it land, so it
        // sits below what is still running and above what has not been merged.
        if pr.isQueued { return 4 }
        return 5
    }
    var prLastFetchedAt: Date?
    private var prTimer: Timer?

    // MARK: Alerts
    var alerts: [MegadeskAlert] = []
    private(set) var firedAlertIds: Set<UUID> = []
    private(set) var dismissedFiredAlertIds: Set<UUID> = []
    /// Alerts the user sent from their toast to the widget. It only covers the
    /// round the alert is in, not its settings, so "move to widget" parks this
    /// one reminder without changing where the alert shows up next time. Kept on
    /// disk so a restart can't swallow a reminder that is still waiting.
    private(set) var widgetPinnedAlertIds: Set<UUID> = []

    /// Number of fired alerts that the user hasn't dismissed yet AND that are
    /// configured to show a badge. Computed instead of stored so it can never
    /// drift out of sync with the underlying sets (e.g. when an alert is
    /// deleted while pending).
    var pendingAlertCount: Int {
        alerts.filter {
            $0.effectiveShowBadge &&
            firedAlertIds.contains($0.id) &&
            !dismissedFiredAlertIds.contains($0.id)
        }.count
    }

    /// Whether a fired alert belongs in the widget: either it's configured that
    /// way, or the user moved it there from its toast.
    func alertShowsInWidget(_ alert: MegadeskAlert) -> Bool {
        alert.effectiveShowWidget || widgetPinnedAlertIds.contains(alert.id)
    }

    /// Parks a fired alert in the widget so closing its toast doesn't lose it.
    func moveAlertToWidget(id: UUID) {
        widgetPinnedAlertIds.insert(id)
        dismissedFiredAlertIds.remove(id)
        saveWidgetPins()
    }

    private func clearWidgetPin(_ id: UUID) {
        guard widgetPinnedAlertIds.remove(id) != nil else { return }
        saveWidgetPins()
    }

    private func saveWidgetPins() {
        UserDefaults.standard.set(widgetPinnedAlertIds.map(\.uuidString),
                                  forKey: "megadesk.widgetPinnedAlerts")
    }

    private func loadWidgetPins() {
        let stored = UserDefaults.standard.stringArray(forKey: "megadesk.widgetPinnedAlerts") ?? []
        widgetPinnedAlertIds = Set(stored.compactMap(UUID.init(uuidString:)))
    }

    private let sessionsURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/megadesk/sessions")
    }()

    var activeSessionId: String? = nil

    private var watchSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var spinnerTimer: Timer?
    private var dirFD: Int32 = -1
    private var focusSessionObserver: Any?
    private var cycleSessionObserver: Any?
    private var flashTimer: Timer?
    private var lastCycleIndex: Int? = nil
    private let startupTime = Date()

    // kqueue-based process watchers: terminalSessionId → DispatchSourceProcess
    private var processSources: [String: DispatchSourceProcess] = [:]

    /// Serial queue for all AppleScript execution — NSAppleScript is not thread-safe.
    private static let appleScriptQueue = DispatchQueue(label: "com.megadesk.applescript")

    // Caches of active terminal session IDs, updated by checkOrphanedSessions every 10s.
    // Used by reapDeadSessions to avoid removing sessions whose terminal tab is still
    // alive (e.g. PID is stale after a Claude restart).
    private var lastKnownActiveItermIds: Set<String> = []
    private var lastKnownActiveGhosttyIds: Set<String> = []

    // Guards to prevent AppleScript calls from piling up when terminals are slow to respond.
    private var isSyncingActiveSession = false
    private var isCheckingOrphans = false

    // JSONL watchers: sessionId → JSONLWatcher
    var activeToolDetails: [String: String] = [:]
    private var jsonlWatchers: [String: JSONLWatcher] = [:]

    // Spinner scraping: sessionId → info (verb + timing/tokens)
    var spinnerInfos: [String: TerminalFocuser.SpinnerInfo] = [:]
    private var isScrapingSpinners = false

    // claude pid → agent CLIs running beneath it (see refreshBackgroundAgents).
    private var backgroundAgentCounts: [Int32: Int] = [:]
    private var backgroundAgentsSeenAt: [Int32: Date] = [:]

    // Sessions whose Claude transcript ends in a `continued-in` record — the
    // conversation lives under a new id now, so these are ghosts. Kept in memory
    // as well as deleted on disk: the old `claude` process may still be running
    // and writing the state file, and the card must not come back.
    private var continuedSessionIds: Set<String> = []
    // Sessions hidden by `isHeadless` — still reaped, just not shown, so the
    // daemon's state files don't pile up in ~/.claude/megadesk/sessions.
    private var hiddenSessions: [Session] = []
    // `terminal` is recomputed from the environment on every hook event and is
    // NOT preserved across writes, so a single event dispatched through Claude's
    // daemon rewrites a perfectly healthy session as `unknown` (the
    // daemon-unknown-terminal gotcha). These two say how much that field can be
    // trusted per session: what was ever seen with a real terminal, and when an
    // uninterrupted run of `unknown` started.
    // Persisted, because it has to survive a relaunch: a session flipped to
    // `unknown` while Megadesk was closed would otherwise look like it never had
    // a terminal at all, and a live card would be hidden on the first tick.
    private var everHadTerminal: Set<String> = []
    private var savedTerminalHistory: Set<String> = []
    private static let terminalHistoryKey = "megadesk.sessionsWithTerminal"
    private var unknownSince: [String: Double] = [:]
    // sessionId → size+mtime of its transcript when last probed, so multi-MB
    // JSONLs are only re-read when they actually changed.
    private var closureProbeStamps: [String: Double] = [:]
    private var isProbingClosures = false
    /// Transcript tails are read here, never on the main thread.
    private static let closureQueue = DispatchQueue(label: "com.megadesk.closure", qos: .utility)

    init() {
        loadCustomNames()
        loadTerminalHistory()
        loadSessions()
        probeContinuedSessions()
        startWatching()
        startTimer()
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.spinnerTick += 1
        }
        loadTrackedPRSlugs()
        startPRTimer()
        loadAlerts()
        setupAlertNotificationObservers()
        focusSessionObserver = NotificationCenter.default.addObserver(
            forName: .megadeskFocusSession, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let index = note.userInfo?["index"] as? Int,
                  index < self.sessions.count else { return }
            self.focusTerminal(session: self.sessions[index])
        }
        cycleSessionObserver = NotificationCenter.default.addObserver(
            forName: .megadeskCycleSession, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let forward = note.userInfo?["forward"] as? Bool ?? true
            self.cycleSession(forward: forward)
        }
    }

    deinit {
        watchSource?.cancel()
        timer?.invalidate()
        spinnerTimer?.invalidate()
        prTimer?.invalidate()
        if dirFD >= 0 { close(dirFD) }
        if let obs = focusSessionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = cycleSessionObserver  { NotificationCenter.default.removeObserver(obs) }
        flashTimer?.invalidate()
        processSources.values.forEach { $0.cancel() }
        jsonlWatchers.removeAll()
    }

    @discardableResult
    func focusTerminal(session: Session) -> Bool {
        // Unknown terminals: the hook never resolved the tab (e.g. Claude ran as
        // a daemon with no ITERM_SESSION_ID/TTY). Recover by matching an open
        // tab by working directory; if that fails, still mark it active so the
        // click is reflected in the UI.
        if session.terminal == .unknown {
            TerminalFocuser.focusByCwd(cwd: session.cwd)
            activeSessionId = session.sessionId
            return true
        }

        let found = TerminalFocuser.focus(session: session)

        // Tmux sessions may outlive their original terminal tab — don't remove the card
        if !found && session.terminal == .iterm2 && session.terminalSessionId.contains(":") {
            activeSessionId = session.sessionId
            return true
        }

        // Fallback: just activate the app if precise focus fails
        if !found && session.terminal == .ghostty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
                NSWorkspace.shared.open(url)
            }
            activeSessionId = session.sessionId
            return true
        }

        if found { activeSessionId = session.sessionId }
        return found
    }

    /// What a custom name is filed under: the tab, so the name survives a new
    /// session in it. For Ghostty that is the terminal id, because the hook
    /// sets `terminalSessionId` to the session id there, and a `/clear`, a
    /// resume or a compact would otherwise drop the name. The terminal id is
    /// also what survives the daemon's `unknown` rewrite.
    private func nameKey(for session: Session) -> String {
        session.ghosttyTerminalId.isEmpty
            ? session.terminalSessionId
            : "ghostty:\(session.ghosttyTerminalId)"
    }

    func displayName(for session: Session) -> String {
        customNames[nameKey(for: session)] ?? session.projectName
    }

    func hasCustomName(for session: Session) -> Bool {
        customNames[nameKey(for: session)] != nil
    }

    func setCustomName(session: Session, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == session.projectName {
            customNames.removeValue(forKey: nameKey(for: session))
        } else {
            customNames[nameKey(for: session)] = trimmed
        }
        saveCustomNames()
    }

    /// Names given before they were filed by tab sit under the session id;
    /// move them to the tab while that session is still around to link them.
    private func migrateCustomNames(_ list: [Session]) {
        var moved = false
        for s in list {
            let key = nameKey(for: s)
            guard key != s.terminalSessionId,
                  let name = customNames.removeValue(forKey: s.terminalSessionId) else { continue }
            if customNames[key] == nil { customNames[key] = name }
            moved = true
        }
        if moved { saveCustomNames() }
    }

    // MARK: - Private

    private func loadCustomNames() {
        guard let data = UserDefaults.standard.data(forKey: "megadesk.customNamesBySession"),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        customNames = dict
    }

    private func saveCustomNames() {
        if let data = try? JSONEncoder().encode(customNames) {
            UserDefaults.standard.set(data, forKey: "megadesk.customNamesBySession")
        }
    }

    private func loadTerminalHistory() {
        everHadTerminal = Set(UserDefaults.standard.stringArray(forKey: Self.terminalHistoryKey) ?? [])
        savedTerminalHistory = everHadTerminal
    }

    /// Only writes when the set actually moved — `loadSessions` runs every second.
    /// It is pruned to the sessions still on disk, so it can't grow without bound.
    private func saveTerminalHistoryIfChanged() {
        guard everHadTerminal != savedTerminalHistory else { return }
        savedTerminalHistory = everHadTerminal
        UserDefaults.standard.set(Array(everHadTerminal), forKey: Self.terminalHistoryKey)
    }

    func loadSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: nil
        ) else {
            sessions = []
            return
        }

        let decoder = JSONDecoder()
        var loaded: [Session] = []
        var hidden: [Session] = []
        var seenIds: Set<String> = []
        let now = Date().timeIntervalSince1970
        let staleThreshold = now - 120

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(Session.self, from: data)
            else { continue }

            // The conversation moved to another session id (its transcript ends
            // in a `continued-in` record), so this one no longer exists — even
            // though its `claude` process can linger for days and keep the card
            // looking alive. Hide it right away, and drop the state file once it
            // has stopped being written to, so a resumed-then-continued session
            // isn't reaped out from under a hook that is still updating it.
            // Deletion is by session id, never by terminal id: after a compact
            // the successor sits in the very same tab.
            if continuedSessionIds.contains(session.sessionId) {
                if session.lastUpdated < staleThreshold { try? fm.removeItem(at: file) }
                continue
            }

            // Track how long this session has been claiming to have no terminal,
            // and remember the ones that ever had a real one.
            if session.terminal == .unknown {
                unknownSince[session.sessionId] = unknownSince[session.sessionId] ?? now
            } else {
                unknownSince.removeValue(forKey: session.sessionId)
                everHadTerminal.insert(session.sessionId)
            }
            seenIds.insert(session.sessionId)

            if isHeadless(session, now: now) {
                hidden.append(session)
                continue
            }

            loaded.append(session)
        }
        hiddenSessions = hidden
        migrateCustomNames(loaded)
        // Drop bookkeeping for state files that are gone.
        unknownSince = unknownSince.filter { seenIds.contains($0.key) }
        everHadTerminal.formIntersection(seenIds)
        saveTerminalHistoryIfChanged()

        // Deduplicate — one terminal tab = one card.
        // Primary key: terminalSessionId. For Ghostty sessions whose
        // terminalSessionId was never resolved (equals sessionId), also
        // deduplicate by ghosttyTerminalId so two sessions pointing at the
        // same Ghostty tab collapse into one card.
        var seen: [String: Session] = [:]
        for s in loaded {
            let key: String
            if s.terminal == .ghostty,
               !s.ghosttyTerminalId.isEmpty,
               s.terminalSessionId == s.sessionId {
                key = "ghostty:\(s.ghosttyTerminalId)"
            } else {
                key = s.terminalSessionId
            }
            if let existing = seen[key] {
                // Two Claude processes both still running are two sessions,
                // whatever tab id they carry: the id is captured from whichever
                // Ghostty window was in front at the time, so it can name the
                // wrong tab. Collapsing them here would delete the card of a
                // session that is very much alive. Same pid, or a dead one, is
                // the case this dedup is for: a tab whose Claude was restarted.
                if existing.claudePid != s.claudePid,
                   isClaudePidAlive(existing), isClaudePidAlive(s) {
                    seen[s.terminalSessionId] = s
                    continue
                }
                if s.lastUpdated > existing.lastUpdated { seen[key] = s }
            } else {
                seen[key] = s
            }
        }
        let deduped = Array(seen.values)

        // Second pass: collapse sessions that share the same Claude PID. A PID
        // identifies a single process, so two sessions reporting the same
        // claude_pid are an artifact of Claude 2.1.x dispatching hook events
        // through a shared daemon (see the terminal=unknown gotcha): the hook
        // records the daemon pid for several logical sessions, leaving stale
        // duplicates that never reap (the daemon stays alive). Keep only the
        // most recently updated session per pid; sessions without a pid are
        // left untouched.
        var byPid: [Int32: Session] = [:]
        var pidless: [Session] = []
        for s in deduped {
            guard let pid = s.claudePid else { pidless.append(s); continue }
            if let existing = byPid[pid] {
                if s.lastUpdated > existing.lastUpdated { byPid[pid] = s }
            } else {
                byPid[pid] = s
            }
        }
        let collapsed = (pidless + Array(byPid.values)).map { s -> Session in
            var s = s
            if s.provider == .claude, let pid = s.claudePid {
                s.backgroundAgents = backgroundAgentCounts[pid] ?? 0
            }
            return s
        }

        sessions = sorted(collapsed)
        updateProcessWatchers()
        syncJSONLWatchers()
    }

    func sorted(_ list: [Session]) -> [Session] {
        switch AppSettings.shared.sortOrder {
        case .byState:
            return list.sorted {
                let p0 = urgencyPriority($0), p1 = urgencyPriority($1)
                if p0 != p1 { return p0 < p1 }
                return $0.timeInState < $1.timeInState
            }
        case .byActivity:
            return list.sorted {
                if $0.lastUpdated != $1.lastUpdated { return $0.lastUpdated > $1.lastUpdated }
                return $0.sessionId < $1.sessionId
            }
        case .byName:
            return list.sorted {
                if $0.projectName != $1.projectName { return $0.projectName < $1.projectName }
                return $0.sessionId < $1.sessionId
            }
        case .byCreation:
            return list.sorted {
                let t0 = $0.createdAt ?? $0.stateSince
                let t1 = $1.createdAt ?? $1.stateSince
                if t0 != t1 { return t0 < t1 }
                return $0.sessionId < $1.sessionId
            }
        }
    }

    private func urgencyPriority(_ s: Session) -> Int {
        if s.needsConfirmation { return 0 }
        if s.isWorking { return 1 }
        if !s.isForgotten { return 2 }  // waiting
        return 3  // forgotten
    }

    private func startWatching() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sessionsURL.path) {
            try? fm.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        }

        dirFD = open(sessionsURL.path, O_EVTONLY)
        guard dirFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.loadSessions()
        }

        source.resume()
        watchSource = source
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick += 1
            // Reload every tick as a fallback — small JSON files, negligible cost.
            // The file watcher handles instant updates; this catches any missed events.
            self?.loadSessions()
            self?.evaluateAlerts()
            // Every 10 seconds, check for orphaned sessions and reap dead ones.
            if (self?.tick ?? 0) % 10 == 0 {
                self?.reapDeadSessions()
                self?.checkOrphanedSessions()
            }
            // Every 30 seconds, look for conversations that were continued elsewhere.
            if (self?.tick ?? 0) % 30 == 0 {
                self?.probeContinuedSessions()
            }
            // Every 2 seconds, sync the active session indicator with the current terminal tab.
            if (self?.tick ?? 0) % 2 == 0 {
                self?.syncActiveSession()
                self?.scrapeSpinnerVerbs()
                self?.refreshBackgroundAgents()
            }
        }
    }

    private var hasItermSessions: Bool {
        sessions.contains { $0.terminal == .iterm2 && $0.terminalSessionId != $0.sessionId }
    }

    private var hasGhosttySessions: Bool {
        sessions.contains { $0.terminal == .ghostty }
    }

    private func syncActiveSession() {
        guard !isSyncingActiveSession else { return }
        isSyncingActiveSession = true

        // Only detect the terminal that is currently frontmost to avoid
        // one terminal's detection overwriting a session the user just clicked in another.
        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let syncIterm = hasItermSessions && frontBundleId == "com.googlecode.iterm2"
        let syncGhostty = hasGhosttySessions && frontBundleId == "com.mitchellh.ghostty"

        let group = DispatchGroup()

        if syncIterm {
            group.enter()
            detectCurrentItermSession { [weak self] currentId in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self, let currentId else { return }
                    guard let match = self.sessions.first(where: {
                        $0.terminalSessionId.components(separatedBy: ":").first == currentId
                    }) else { return }
                    if self.activeSessionId != match.sessionId {
                        self.activeSessionId = match.sessionId
                    }
                }
            }
        }

        if syncGhostty {
            group.enter()
            detectCurrentGhosttySession { [weak self] terminalId in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self, let terminalId else { return }
                    guard let match = self.sessions.first(where: {
                        $0.terminal == .ghostty && $0.ghosttyTerminalId == terminalId
                    }) else { return }
                    if self.activeSessionId != match.sessionId {
                        self.activeSessionId = match.sessionId
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.isSyncingActiveSession = false
        }
    }

    func toolDetail(for session: Session) -> String? {
        activeToolDetails[session.sessionId]
    }

    func spinnerInfo(for session: Session) -> TerminalFocuser.SpinnerInfo? {
        // The session's own turn is over; whatever verb is left is stale.
        if session.isWorkingInBackground { return nil }
        if let scraped = spinnerInfos[session.sessionId] { return scraped }
        // For non-iTerm2 sessions, derive from JSONL tool detail reactively
        // (no polling delay — updates as soon as the watcher fires).
        if session.terminal != .iterm2,
           let detail = activeToolDetails[session.sessionId] {
            return Self.spinnerInfoFromToolDetail(detail)
        }
        return nil
    }

    private func scrapeSpinnerVerbs() {
        guard AppSettings.shared.showSpinnerVerb else {
            spinnerInfos.removeAll()
            return
        }

        // iTerm2 sessions: scrape the terminal via AppleScript.
        // Non-iTerm2 (Ghostty, etc.) are handled reactively in spinnerInfo(for:).
        let itermCandidates = sessions.filter {
            $0.isWorking && !$0.isWorkingInBackground && !$0.needsConfirmation && $0.terminal == .iterm2
        }

        // Clean up stale entries
        let itermIds = Set(itermCandidates.map(\.sessionId))
        for id in spinnerInfos.keys where !itermIds.contains(id) {
            spinnerInfos.removeValue(forKey: id)
        }
        guard !isScrapingSpinners, !itermCandidates.isEmpty else { return }

        isScrapingSpinners = true
        let sessionsToScrape = itermCandidates.map { ($0.sessionId, $0.terminalSessionId) }

        StatusStore.appleScriptQueue.async { [weak self] in
            // NSAppleScript is not thread-safe — run all scrapes serially on the dedicated queue.
            var results: [(String, TerminalFocuser.SpinnerInfo?)] = []
            for (sessId, termId) in sessionsToScrape {
                let info = TerminalFocuser.readiTerm2SpinnerInfo(terminalSessionId: termId)
                results.append((sessId, info))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isScrapingSpinners = false
                for (sessionId, info) in results {
                    if let info {
                        self.spinnerInfos[sessionId] = info
                    } else {
                        self.spinnerInfos.removeValue(forKey: sessionId)
                    }
                }
            }
        }
    }

    /// Derives a SpinnerInfo from a JSONL tool detail string (e.g. "Reading file.swift").
    /// Used for terminals that don't support screen scraping (Ghostty, etc.).
    private static func spinnerInfoFromToolDetail(_ detail: String) -> TerminalFocuser.SpinnerInfo {
        let verb: String
        if detail.hasPrefix("Reading ")   { verb = "Reading" }
        else if detail.hasPrefix("Editing ")   { verb = "Editing" }
        else if detail.hasPrefix("Writing ")   { verb = "Writing" }
        else if detail.hasPrefix("$ ")         { verb = "Running" }
        else if detail.hasPrefix("Glob ")      { verb = "Searching" }
        else if detail.hasPrefix("Grep ")      { verb = "Searching" }
        else if detail.hasPrefix("Search: ")   { verb = "Searching" }
        else if detail.hasPrefix("Fetching ")  { verb = "Fetching" }
        else if detail.hasPrefix("Task: ")     { verb = "Working" }
        else if detail.hasPrefix("Updating ")  { verb = "Updating" }
        else { verb = "Working" }
        return TerminalFocuser.SpinnerInfo(verb: verb, detail: detail, isHighEffort: false)
    }

    private func syncJSONLWatchers() {
        let activeIds = Set(sessions.map(\.sessionId))

        // Cancel watchers for sessions that are gone
        for id in Set(jsonlWatchers.keys).subtracting(activeIds) {
            jsonlWatchers.removeValue(forKey: id)
            activeToolDetails.removeValue(forKey: id)
            spinnerInfos.removeValue(forKey: id)
        }

        // Start watchers for new sessions
        for session in sessions where jsonlWatchers[session.sessionId] == nil {
            let sessionId = session.sessionId
            let watcher = JSONLWatcher(sessionId: sessionId)
            watcher.onUpdate = { [weak self] detail in
                guard let self else { return }
                if let detail {
                    self.activeToolDetails[sessionId] = detail
                } else {
                    self.activeToolDetails.removeValue(forKey: sessionId)
                }
            }
            jsonlWatchers[sessionId] = watcher
        }
    }

    /// Registers kqueue watchers for any new sessions that have a claudePid,
    /// and cancels watchers for sessions that are no longer in the list.
    /// When a watched process exits, the card is removed instantly via kqueue notification.
    private func updateProcessWatchers() {
        let activeIds = Set(sessions.compactMap { $0.claudePid != nil ? $0.terminalSessionId : nil })

        // Cancel watchers for sessions no longer loaded
        for id in Set(processSources.keys).subtracting(activeIds) {
            processSources[id]?.cancel()
            processSources.removeValue(forKey: id)
        }

        // Register watchers for new sessions
        for session in sessions {
            guard let pid = session.claudePid,
                  processSources[session.terminalSessionId] == nil else { continue }

            // If already dead, skip — reapDeadSessions or checkOrphanedSessions will
            // handle cleanup with proper terminal tab checks to avoid false removals.
            guard kill(pid_t(pid), 0) == 0 || errno == EPERM else { continue }

            let terminalId = session.terminalSessionId
            let source = DispatchSource.makeProcessSource(
                identifier: pid_t(pid),
                eventMask: .exit,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                // The watched PID exited, but some CLIs recycle the process the
                // hook recorded while the session and its terminal tab live on
                // (Kimi during long auto-mode runs, and Claude's 2.1.x daemon).
                // Deleting blindly makes the card vanish mid-session and reappear
                // on the next hook event. Delegate to reapDeadSessions, which only
                // removes when the terminal tab is actually gone.
                print("[Megadesk] kqueue: PID \(pid) exited for \(terminalId) — re-evaluating with tab check")
                self?.processSources[terminalId]?.cancel()
                self?.processSources.removeValue(forKey: terminalId)
                self?.reapDeadSessions()
            }
            source.resume()
            processSources[terminalId] = source
        }
    }

    /// Safety net: removes sessions whose Claude process is dead or unknown.
    /// Catches: kqueue failures, PID recycling, missing claudePid (old hook),
    /// and fallback sessions that the orphan checker skips.
    /// A dead stored PID whose terminal tab is still open is kept only briefly —
    /// a restart fires its hook within seconds — then reaped, so closing Claude
    /// but leaving the terminal open doesn't orphan the card forever.
    private func reapDeadSessions() {
        let now = Date().timeIntervalSince1970
        let staleThreshold = now - 120
        let codexStaleThreshold = now - 600
        var deadIds: [String] = []
        var deadCodexIds: [String] = []
        // Looked up at most once per pass, and only if a Codex session needs it.
        var codexTUIDirs: Set<String>?
        // Hidden sessions are still reaped: they were only taken off the board,
        // and without this their state files would accumulate forever.
        for session in sessions + hiddenSessions {
            // Codex only reports when a turn completes, so a live session can go
            // a long while without an update; hence the longer window. A dead pid
            // after that much silence means the run is over: a TUI that was
            // closed, or a `codex exec` from before the hook skipped them.
            if session.provider == .codex {
                guard session.lastUpdated < codexStaleThreshold else { continue }
                if !isCodexAlive(session, tuiDirs: &codexTUIDirs) {
                    print("[Megadesk] reapDeadSessions: removing Codex \(session.projectName) (not running, silent 10 min)")
                    deadCodexIds.append(session.sessionId)
                }
                continue
            }
            if let pid = session.claudePid {
                // Has a PID — check if the process is still alive.
                if kill(pid_t(pid), 0) != 0 && errno != EPERM {
                    // PID is dead. If the tab is still open, Claude may have just
                    // restarted in it and the hook hasn't fired yet, so keep the
                    // card during a grace window. But once it goes stale, Claude is
                    // gone for good (closed while the terminal stayed open), so reap
                    // it instead of orphaning the card forever.
                    if isTerminalTabAlive(session) && session.lastUpdated >= staleThreshold {
                        print("[Megadesk] reapDeadSessions: PID \(pid) dead for \(session.projectName) but tab alive and recently updated — skipping")
                        continue
                    }
                    print("[Megadesk] reapDeadSessions: removing \(session.projectName) (PID \(pid) dead)")
                    processSources[session.terminalSessionId]?.cancel()
                    processSources.removeValue(forKey: session.terminalSessionId)
                    deadIds.append(session.terminalSessionId)
                }
            } else if session.lastUpdated < staleThreshold {
                // No PID at all (old hook version) — remove if stale.
                if isTerminalTabAlive(session) { continue }
                print("[Megadesk] reapDeadSessions: removing \(session.projectName) (no PID, stale)")
                deadIds.append(session.terminalSessionId)
            }
        }
        for id in deadIds {
            removeSessionFiles(withTerminalId: id)
        }
        // By session id, not terminal id: a Codex run started from another
        // agent's tab carries that tab's id, and deleting by it would take the
        // live session's card along.
        if !deadCodexIds.isEmpty {
            for id in deadCodexIds {
                try? FileManager.default.removeItem(at: sessionsURL.appendingPathComponent("\(id).json"))
            }
            loadSessions()
        }
    }

    /// True for a session that has no terminal of its own to jump to: Claude
    /// running under the 2.1.x daemon, in a pty of the bg-pty-host that is not a
    /// pane of anything. Clicking the card can't take you anywhere, it just
    /// lands on some pane that happens to share the cwd.
    ///
    /// `terminal` alone is not enough to conclude that. The hook recomputes it
    /// from the environment on every event and doesn't preserve it, so one event
    /// dispatched through the daemon flips a live iTerm2/Ghostty session to
    /// `unknown` until its next ordinary event — and the same write moves its
    /// `terminal_session_id` to the session id, which is why a custom name can't
    /// be relied on to protect it either. Hence the guards: Ghostty is
    /// recognised by the terminal id the hook *does* preserve, anything ever
    /// seen with a real terminal is trusted to still have one (persisted, so a
    /// relaunch doesn't forget), and the card only goes once we have watched it
    /// claim `unknown` for an uninterrupted 120s — the same window the other
    /// reapers wait before believing what they see. What the file says on its
    /// own, without having been observed, is never enough.
    private func isHeadless(_ session: Session, now: Double) -> Bool {
        guard session.terminal == .unknown else { return false }
        // The daemon flip loses `terminal`, but never `ghostty_terminal_id`.
        guard session.ghosttyTerminalId.isEmpty else { return false }
        // Only Claude has this daemon. Codex and Kimi keep their cards.
        guard session.provider == .claude else { return false }
        // A name means the card was adopted on purpose — that one stays.
        guard customNames[nameKey(for: session)] == nil else { return false }
        guard !everHadTerminal.contains(session.sessionId) else { return false }
        // A flip that a later event undoes never reaches 120s: the good event
        // clears `unknownSince` and files the session under `everHadTerminal`
        // for good. Trusting `lastUpdated` here instead would skip the waiting
        // entirely on a cold start and hide a live card on the first tick.
        return now - (unknownSince[session.sessionId] ?? now) >= 120
    }

    /// Returns true if the session's terminal tab is still open, based on the
    /// cached active IDs from the last checkOrphanedSessions() run.
    private func isTerminalTabAlive(_ session: Session) -> Bool {
        switch session.terminal {
        case .iterm2:
            let bareId = session.terminalSessionId.components(separatedBy: ":").first ?? session.terminalSessionId
            return !lastKnownActiveItermIds.isEmpty && lastKnownActiveItermIds.contains(bareId)
        case .ghostty:
            return !lastKnownActiveGhosttyIds.isEmpty && lastKnownActiveGhosttyIds.contains(session.ghosttyTerminalId)
        case .unknown:
            return false
        }
    }

    // MARK: - Continued conversations

    /// Finds the sessions whose Claude transcript ends in a `continued-in`
    /// record: the conversation was continued under a new session id (a compact,
    /// a `--resume`), so the old one is gone. Its `claude` process can outlive it
    /// by days, which is why the PID reaper never catches these.
    ///
    /// Transcripts are multi-MB and there are dozens, so only the tail is read,
    /// only for Claude sessions (Codex and Kimi have no transcript in this
    /// format), only when the file changed since the last probe, and always off
    /// the main thread. A session that is already flagged is never probed again.
    private func probeContinuedSessions() {
        guard !isProbingClosures else { return }
        let candidates = sessions
            .filter { $0.provider == .claude && !continuedSessionIds.contains($0.sessionId) }
            .map { (id: $0.sessionId, cwd: $0.cwd) }
        guard !candidates.isEmpty else { return }

        isProbingClosures = true
        let stamps = closureProbeStamps
        Self.closureQueue.async { [weak self] in
            var continued: Set<String> = []
            var newStamps: [String: Double] = [:]
            for candidate in candidates {
                guard let url = Self.transcriptURL(cwd: candidate.cwd, sessionId: candidate.id),
                      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                else { continue }
                let size = (attrs[.size] as? NSNumber)?.doubleValue ?? 0
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let stamp = size + mtime
                newStamps[candidate.id] = stamp
                // Unchanged since the last look, and it wasn't closed then either.
                if stamps[candidate.id] == stamp { continue }
                if Self.transcriptEndsContinued(url) { continued.insert(candidate.id) }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isProbingClosures = false
                self.closureProbeStamps = newStamps
                guard !continued.isEmpty else { return }
                for id in continued {
                    print("[Megadesk] probeContinuedSessions: \(id) was continued elsewhere — dropping card")
                }
                self.continuedSessionIds.formUnion(continued)
                self.loadSessions()
            }
        }
    }

    /// Locates a session's transcript. Claude names the folder after the cwd with
    /// every non-alphanumeric character turned into a dash; the scan is the
    /// fallback for anything that doesn't map cleanly.
    private static func transcriptURL(cwd: String, sessionId: String) -> URL? {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let slug = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let direct = projects.appendingPathComponent(slug).appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// True when the transcript closed with a `continued-in` record. It is not
    /// always the very last line — Claude usually appends bookkeeping after it
    /// (`cost-state`, `file-history-snapshot`, `system`), so the tail is walked
    /// backwards and the first thing that settles the question wins: a
    /// `continued-in` means the conversation moved on, a `user` or `assistant`
    /// turn means it was still being used and nothing was continued.
    ///
    /// Anything unreadable, truncated, or merely inconclusive returns false: a
    /// card is only ever dropped on a positive, unambiguous reading.
    private static func transcriptEndsContinued(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return false }
        let window: UInt64 = 64 * 1024
        let start = size > window ? size - window : 0
        guard (try? fh.seek(toOffset: start)) != nil,
              let data = try? fh.readToEnd(), !data.isEmpty
        else { return false }

        // Lossy on purpose: the window can start mid-character, and that first
        // partial line is discarded below anyway.
        let text = String(decoding: data, as: UTF8.self)
        var inspected = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // A line the window cut in half, or anything else unparseable: stop
            // rather than guess.
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return false }
            switch json["type"] as? String {
            case "continued-in": return true
            case "user", "assistant": return false
            default: break  // trailing bookkeeping — keep walking back
            }
            inspected += 1
            if inspected >= 50 { return false }
        }
        return false
    }

    /// Returns true if the session's Claude process is still running.
    private func isClaudePidAlive(_ session: Session) -> Bool {
        guard let pid = session.claudePid else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Whether a Codex session is still running. Recent Codex builds hand TUI
    /// sessions to a shared `codex app-server` daemon and fire notify from
    /// there, so the pid the hook records is the daemon's, alive for as long
    /// as any Codex is. For those, the session counts as running while a Codex
    /// TUI sits in its directory. `tuiDirs` caches that lookup for the caller.
    private func isCodexAlive(_ session: Session, tuiDirs: inout Set<String>?) -> Bool {
        guard let pid = session.claudePid, isClaudePidAlive(session) else { return false }
        guard Self.executablePath(of: pid_t(pid))?.contains("/app-server") == true else { return true }
        if tuiDirs == nil { tuiDirs = Self.codexTUIDirectories() }
        return tuiDirs?.contains((session.cwd as NSString).standardizingPath) ?? false
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Working directories of the running Codex TUIs (any `codex` executable
    /// that isn't part of the app-server).
    private static func codexTUIDirectories() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var dirs: Set<String> = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let path = executablePath(of: pid),
                  path.hasSuffix("/codex"), !path.contains("/app-server") else { continue }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let cwd = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if !cwd.isEmpty { dirs.insert((cwd as NSString).standardizingPath) }
        }
        return dirs
    }

    // MARK: - Background agents

    /// Counts the agent CLIs running under each Claude session, so a session
    /// whose turn ended while it left agents working (a background shell
    /// driving `claude -p` or `codex exec`) still reads as working. Those
    /// agents get no card of their own, so without this the board shows the
    /// session waiting for input while its work is still going.
    private func refreshBackgroundAgents() {
        let roots = Set(sessions.compactMap { $0.provider == .claude ? $0.claudePid : nil })
        var counts = roots.isEmpty ? [:] : Self.agentCounts(under: roots)
        // A driver script runs its agents one after another, with git and gh
        // calls in between; hold the last count briefly so the card doesn't
        // flicker to waiting in every gap.
        let now = Date()
        for pid in counts.keys { backgroundAgentsSeenAt[pid] = now }
        for (pid, seen) in backgroundAgentsSeenAt where counts[pid] == nil {
            if now.timeIntervalSince(seen) < 10, roots.contains(pid), let last = backgroundAgentCounts[pid] {
                counts[pid] = last
            } else if now.timeIntervalSince(seen) >= 10 {
                backgroundAgentsSeenAt.removeValue(forKey: pid)
            }
        }
        guard counts != backgroundAgentCounts else { return }
        backgroundAgentCounts = counts
        loadSessions()
    }

    /// For each root pid, how many `claude`/`codex` processes descend from it.
    /// MCP servers and Codex's app-server are long-running children of the
    /// session itself, not work it handed off, so they don't count.
    private static func agentCounts(under roots: Set<Int32>) -> [Int32: Int] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [:] }

        var parent: [pid_t: pid_t] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { continue }
            parent[pid] = pid_t(info.pbsi_ppid)
        }

        var counts: [Int32: Int] = [:]
        for pid in parent.keys where !roots.contains(Int32(pid)) {
            // Walk up to the session that owns it, if any.
            var ancestor = parent[pid] ?? 0
            var depth = 0
            while ancestor > 1, !roots.contains(Int32(ancestor)), depth < 32 {
                ancestor = parent[ancestor] ?? 0
                depth += 1
            }
            guard ancestor > 1, roots.contains(Int32(ancestor)) else { continue }
            // The process name is the binary's (Claude's is its version
            // number), so go by argv[0], the name it was launched under.
            let args = arguments(of: pid)
            guard let launched = args.first.map({ ($0 as NSString).lastPathComponent }),
                  launched == "claude" || launched == "codex",
                  !args.contains(where: { $0.contains("mcp") || $0 == "app-server" }) else { continue }
            counts[Int32(ancestor), default: 0] += 1
        }
        return counts
    }

    /// A process's argv, read with KERN_PROCARGS2: an argc, the executable
    /// path, padding, then the arguments, all NUL-separated.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the NULs padding it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    /// Queries iTerm2 and Ghostty for active terminal sessions and removes
    /// session files whose terminal tab no longer exists.
    private func checkOrphanedSessions() {
        // Skip for the first 30s after launch — terminals may return an incomplete
        // session list immediately after Megadesk restarts, causing false deletions.
        guard Date().timeIntervalSince(startupTime) > 30 else { return }
        guard hasItermSessions || hasGhosttySessions else { return }
        guard !isCheckingOrphans else { return }
        isCheckingOrphans = true

        let checkIterm = hasItermSessions
        let checkGhostty = hasGhosttySessions
        Self.appleScriptQueue.async { [weak self] in
            let itermIds = checkIterm ? Self.queryItermSessionIds() : []
            let ghosttyIds = checkGhostty ? Self.queryGhosttyTerminalIds() : []

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isCheckingOrphans = false
                self.lastKnownActiveItermIds = itermIds
                self.lastKnownActiveGhosttyIds = ghosttyIds
                self.removeOrphanedSessions(activeItermIds: itermIds, activeGhosttyIds: ghosttyIds)
            }
        }
    }

    private static func queryItermSessionIds() -> Set<String> {
        let script = """
        if application "iTerm2" is not running then return {}
        tell application "iTerm2"
            set ids to {}
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set end of ids to (unique id of s)
                    end repeat
                end repeat
            end repeat
            return ids
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            if let error { print("[Megadesk] queryItermSessionIds AppleScript error: \(error)") }
            return []
        }
        var ids: Set<String> = []
        let count = result.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let val = result.atIndex(i)?.stringValue { ids.insert(val) }
            }
        }
        return ids
    }

    private static func queryGhosttyTerminalIds() -> Set<String> {
        let script = """
        if application "Ghostty" is not running then return {}
        tell application "Ghostty"
            set ids to {}
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        set end of ids to (id of term)
                    end repeat
                end repeat
            end repeat
            return ids
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            if let error { print("[Megadesk] queryGhosttyTerminalIds AppleScript error: \(error)") }
            return []
        }
        var ids: Set<String> = []
        let count = result.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let val = result.atIndex(i)?.stringValue { ids.insert(val) }
            }
        }
        return ids
    }

    private func removeOrphanedSessions(activeItermIds: Set<String>, activeGhosttyIds: Set<String>) {
        let staleThreshold = Date().timeIntervalSince1970 - 120

        let orphanedIds = sessions
            .filter { s in
                // Codex sessions don't report PIDs and update infrequently — skip orphan cleanup
                guard s.provider != .codex else { return false }
                guard s.lastUpdated < staleThreshold && !isClaudePidAlive(s) else { return false }
                switch s.terminal {
                case .iterm2:
                    let bareId = s.terminalSessionId.components(separatedBy: ":").first ?? s.terminalSessionId
                    return s.terminalSessionId != s.sessionId && !activeItermIds.contains(bareId)
                case .ghostty:
                    guard !s.ghosttyTerminalId.isEmpty else { return false }
                    return !activeGhosttyIds.contains(s.ghosttyTerminalId)
                case .unknown:
                    return false
                }
            }
            .map(\.terminalSessionId)

        for id in orphanedIds {
            print("[Megadesk] checkOrphanedSessions: removing \(id) (tab gone, stale, PID dead)")
            removeSessionFiles(withTerminalId: id)
        }
    }

    /// Deletes all session JSON files that belong to the given terminal session ID,
    /// then reloads the session list.
    private func removeSessionFiles(withTerminalId terminalId: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        var removed = false
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(Session.self, from: data),
                  session.terminalSessionId == terminalId
            else { continue }
            try? fm.removeItem(at: file)
            removed = true
        }
        if removed { loadSessions() }
    }

    // MARK: - Session cycling

    private func cycleSession(forward: Bool) {
        guard !sessions.isEmpty else { return }
        // Seed lastCycleIndex from the already-tracked activeSessionId
        // (kept up to date by syncActiveSession every 2s).
        if lastCycleIndex == nil, let activeId = activeSessionId,
           let idx = sessions.firstIndex(where: { $0.sessionId == activeId }) {
            lastCycleIndex = idx
        }
        performCycle(forward: forward)
    }

    private func performCycle(forward: Bool) {
        let count = sessions.count
        let next: Int
        if let current = lastCycleIndex, current < count {
            next = forward ? (current + 1) % count : (current - 1 + count) % count
        } else {
            next = forward ? 0 : count - 1
        }
        lastCycleIndex = next
        let session = sessions[next]
        focusTerminal(session: session)
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.lastCycleIndex = nil
        }
    }

    private func detectCurrentItermSession(completion: @escaping (String?) -> Void) {
        let script = """
        tell application "iTerm2"
            return unique id of current session of current window
        end tell
        """
        Self.appleScriptQueue.async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            let result = appleScript?.executeAndReturnError(&error)
            completion(result?.stringValue)
        }
    }

    private func detectCurrentGhosttySession(completion: @escaping (String?) -> Void) {
        let script = """
        tell application "Ghostty"
            return id of focused terminal of selected tab of front window
        end tell
        """
        Self.appleScriptQueue.async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            let result = appleScript?.executeAndReturnError(&error)
            completion(error == nil ? result?.stringValue : nil)
        }
    }

    // MARK: - PR Tracking

    func addTrackedPR(repo: String, number: Int) {
        let id = "\(repo)#\(number)"
        guard !trackedPRs.contains(where: { $0.id == id }) else { return }
        trackedPRs.append(TrackedPR(repo: repo, number: number))
        saveTrackedPRSlugs()
        fetchPR(repo: repo, number: number)
    }

    func removeTrackedPR(id: String) {
        trackedPRs.removeAll { $0.id == id }
        saveTrackedPRSlugs()
    }

    private func loadTrackedPRSlugs() {
        guard let slugs = UserDefaults.standard.stringArray(forKey: "megadesk.trackedPRs") else { return }
        trackedPRs = slugs.compactMap { slug in
            guard let (repo, number) = TrackedPR.parse(slug) else { return nil }
            return TrackedPR(repo: repo, number: number)
        }
    }

    private func saveTrackedPRSlugs() {
        UserDefaults.standard.set(trackedPRs.map(\.id), forKey: "megadesk.trackedPRs")
    }

    func fetchAllPRs() {
        prLastFetchedAt = Date()
        for pr in trackedPRs {
            fetchPR(repo: pr.repo, number: pr.number)
        }
    }

    /// One PR with everything the card shows. `contexts` is capped at 100, which
    /// is plenty: the rollup only needs to know if anything is failing or still
    /// running, and both survive truncation on any realistic check count.
    private static let prGraphQLQuery = """
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$number){
          number title url updatedAt headRefName state mergeable mergeStateStatus
          isInMergeQueue
          author{ login }
          mergeQueueEntry{ state position }
          commits(last:1){ nodes{ commit{ statusCheckRollup{ contexts(first:100){ nodes{
            __typename
            ... on CheckRun{ status conclusion }
            ... on StatusContext{ state }
          } } } } } }
        }
      }
    }
    """

    func fetchPR(repo: String, number: Int) {
        let id = "\(repo)#\(number)"
        guard let idx = trackedPRs.firstIndex(where: { $0.id == id }) else { return }
        trackedPRs[idx].fetchState = .loading

        let ghPaths = ["/usr/local/bin/gh", "/opt/homebrew/bin/gh"]
        guard let ghPath = ghPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            trackedPRs[idx].fetchState = .error("gh not found")
            return
        }

        // owner/repo — GraphQL wants the two halves separately.
        let repoParts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard repoParts.count == 2 else {
            trackedPRs[idx].fetchState = .error("bad repo")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        // GraphQL rather than `gh pr view --json`: the CLI has no merge queue
        // fields, and the queue is what tells a PR that is waiting its turn from
        // one that needs somebody to do something.
        process.arguments = [
            "api", "graphql",
            "-f", "owner=\(repoParts[0])",
            "-f", "repo=\(repoParts[1])",
            "-F", "number=\(number)",
            "-f", "query=\(Self.prGraphQLQuery)"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // Watchdog: terminate after 15 seconds.
        // Guard against racing with normal completion — terminate() on an
        // already-finished Process throws NSInvalidArgumentException.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: watchdog)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try process.run()
                process.waitUntilExit()
                watchdog.cancel()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()

                DispatchQueue.main.async {
                    guard let self, let i = self.trackedPRs.firstIndex(where: { $0.id == id }) else { return }

                    guard process.terminationStatus == 0 else {
                        self.trackedPRs[i].fetchState = .error("not found or no auth")
                        return
                    }

                    do {
                        let response = try JSONDecoder().decode(PRGraphQLResponse.self, from: data)
                        guard let node = response.data?.repository?.pullRequest else {
                            self.trackedPRs[i].fetchState = .error("not found or no auth")
                            return
                        }
                        self.trackedPRs[i].data = node.toPullRequest()
                        self.trackedPRs[i].fetchState = .loaded
                    } catch {
                        self.trackedPRs[i].fetchState = .error("parse error")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, let i = self.trackedPRs.firstIndex(where: { $0.id == id }) else { return }
                    self.trackedPRs[i].fetchState = .error("gh not found")
                }
            }
        }
    }

    private func startPRTimer() {
        fetchAllPRs()
        prTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.fetchAllPRs()
        }
    }

    // MARK: - Alerts CRUD

    func addAlert(_ alert: MegadeskAlert) {
        alerts.append(alert)
        saveAlerts()
        // Request notification permission on first alert
        if alerts.count == 1 {
            AlertNotificationService.shared.requestAuthorization()
        }
    }

    func updateAlert(_ alert: MegadeskAlert) {
        guard let i = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[i] = alert
        saveAlerts()
    }

    func toggleAlert(id: UUID, enabled: Bool) {
        guard let i = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts[i].isEnabled = enabled
        // Flipping the switch either way settles the alert's fate by hand, so a
        // snooze waiting to go off is no longer wanted.
        alerts[i].snoozedUntil = nil
        if enabled {
            // Reset so recurring/interval alerts don't fire instantly from a stale lastFiredAt.
            // For .once, clear lastFiredAt so it can fire again.
            if case .once = alerts[i].recurrence {
                alerts[i].lastFiredAt = nil
            } else {
                alerts[i].lastFiredAt = Date()
            }
            firedAlertIds.remove(id)
        }
        saveAlerts()
    }

    func removeAlert(id: UUID) {
        alerts.removeAll { $0.id == id }
        firedAlertIds.remove(id)
        dismissedFiredAlertIds.remove(id)
        clearWidgetPin(id)
        ToastWindowController.shared.dismissToast(alertId: id)
        saveAlerts()
    }

    func loadAlerts() {
        guard let data = UserDefaults.standard.data(forKey: "megadesk.alerts"),
              let decoded = try? JSONDecoder().decode([MegadeskAlert].self, from: data)
        else { return }
        // Drafts belong to an editing session that is over: if one survived, the
        // window (or the app) went away before it was confirmed.
        alerts = decoded.filter { $0.isDraft != true }
        if alerts.count != decoded.count { saveAlerts() }

        loadWidgetPins()
        // Pins for alerts that no longer exist are dead weight.
        let liveIds = Set(alerts.map(\.id))
        if !widgetPinnedAlertIds.isSubset(of: liveIds) {
            widgetPinnedAlertIds.formIntersection(liveIds)
            saveWidgetPins()
        }

        // Restore firedAlertIds for .once alerts that fired but weren't dismissed/completed
        for alert in alerts {
            if case .once = alert.recurrence,
               alert.lastFiredAt != nil, !alert.isEnabled, alert.isCompleted != true {
                firedAlertIds.insert(alert.id)
            }
        }

        // A one-off alert that has had its turn and isn't waiting to be
        // dismissed is done, so file it under Completed. Firing one disables it,
        // which used to leave it in the list reading "Disabled" as if the user
        // had switched it off, with no way back now that one-offs have no
        // switch. Off without ever firing counts too: that's the same dead end,
        // reached by hand.
        var archived = false
        for i in alerts.indices {
            guard case .once = alerts[i].recurrence else { continue }
            guard alerts[i].isCompleted != true,
                  !firedAlertIds.contains(alerts[i].id),
                  alerts[i].lastFiredAt != nil || !alerts[i].isEnabled else { continue }
            alerts[i].isCompleted = true
            archived = true
        }
        if archived { saveAlerts() }
    }

    func saveAlerts() {
        if let data = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(data, forKey: "megadesk.alerts")
        }
    }

    func fireAlertForTest(id: UUID) {
        guard let alert = alerts.first(where: { $0.id == id }) else { return }
        firedAlertIds.insert(id)
        dismissedFiredAlertIds.remove(id)
        dispatchAlertDisplay(alert)
    }

    func dismissFiredAlert(id: UUID) {
        // Guard against re-inserting from multiple dismiss paths
        guard !dismissedFiredAlertIds.contains(id) else { return }
        dismissedFiredAlertIds.insert(id)

        clearWidgetPin(id)

        // Dismissing settles the alert, so drop any snooze still waiting to
        // bring it back.
        if let i = alerts.firstIndex(where: { $0.id == id }), alerts[i].snoozedUntil != nil {
            alerts[i].snoozedUntil = nil
            saveAlerts()
        }

        // Mark non-recurring alerts as completed
        if let i = alerts.firstIndex(where: { $0.id == id }),
           case .once = alerts[i].recurrence {
            alerts[i].isCompleted = true
            saveAlerts()
        }
    }

    // MARK: - Alert Evaluation

    private func evaluateAlerts() {
        let now = Date()
        // Work on a snapshot so we don't trigger @Observable mutations until we're done.
        var snapshot = alerts
        var toFire: [MegadeskAlert] = []

        for i in snapshot.indices {
            guard snapshot[i].isDraft != true else { continue }
            guard snapshot[i].isEnabled else { continue }
            guard !firedAlertIds.contains(snapshot[i].id) else { continue }

            // A snooze fires on its own terms: the alert it belongs to has
            // already had its turn, so its schedule has nothing left to offer
            // and the checks below would never let it through.
            if let until = snapshot[i].snoozedUntil {
                guard until <= now else { continue }
                snapshot[i].snoozedUntil = nil
                snapshot[i].lastFiredAt = now
                firedAlertIds.insert(snapshot[i].id)
                toFire.append(snapshot[i])
                if case .once = snapshot[i].recurrence {
                    snapshot[i].isEnabled = false
                }
                continue
            }

            if let last = snapshot[i].lastFiredAt, last > now { continue }

            if let nextFire = snapshot[i].nextFireDate(after: now), nextFire <= now {
                snapshot[i].lastFiredAt = now
                firedAlertIds.insert(snapshot[i].id)
                toFire.append(snapshot[i])

                if case .once = snapshot[i].recurrence {
                    snapshot[i].isEnabled = false
                }
            }
        }

        guard !toFire.isEmpty else { return }

        // Single write back — triggers observation exactly once.
        alerts = snapshot
        saveAlerts()

        for alert in toFire {
            dispatchAlertDisplay(alert)
        }

        // Clear firedAlertIds for recurring alerts after a cooldown so they can fire again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            for alert in self.alerts where self.firedAlertIds.contains(alert.id) {
                if case .once = alert.recurrence { continue }
                self.firedAlertIds.remove(alert.id)
                self.dismissedFiredAlertIds.remove(alert.id)
            }
        }
    }

    private func dispatchAlertDisplay(_ alert: MegadeskAlert) {
        if alert.effectiveShowToast {
            ToastWindowController.shared.showToast(for: alert)
        }

        if alert.effectiveShowNotification {
            AlertNotificationService.shared.postNotification(for: alert)
        }

        if alert.effectiveShowBadge {
            NotificationCenter.default.post(name: .megadeskAlertFired, object: nil,
                                            userInfo: ["alert": alert])
        }

        if alert.effectivePlaySound {
            NSSound(named: "Pop")?.play()
        }
    }

    private func setupAlertNotificationObservers() {
        NotificationCenter.default.addObserver(forName: .megadeskSnoozeAlert, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let alertId = note.userInfo?["alertId"] as? UUID,
                  let minutes = note.userInfo?["minutes"] as? Int,
                  let i = self.alerts.firstIndex(where: { $0.id == alertId }) else { return }
            // Snooze gets its own field. Pushing lastFiredAt into the future
            // instead used to bury the alert: nextFireDate reads lastFiredAt to
            // decide a .once alert is done and returns nil, and a recurring one
            // just skipped to its next natural occurrence.
            self.alerts[i].snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            // Firing a .once alert disables it and dismissing it completes it.
            // Snoozing means it still owes us a visit, so undo both.
            self.alerts[i].isEnabled = true
            self.alerts[i].isCompleted = false
            self.firedAlertIds.remove(alertId)
            self.dismissedFiredAlertIds.remove(alertId)
            self.clearWidgetPin(alertId)
            self.saveAlerts()
        }

        NotificationCenter.default.addObserver(forName: .megadeskDismissAlert, object: nil, queue: .main) { [weak self] note in
            guard let self, let alertId = note.userInfo?["alertId"] as? UUID else { return }
            self.dismissFiredAlert(id: alertId)
        }
    }
}
