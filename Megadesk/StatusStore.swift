import Foundation
import AppKit
import Observation
import Darwin

@Observable
final class StatusStore {
    static let shared = StatusStore()

    var sessions: [Session] = []
    var tick: Int = 0  // increments every second to force time re-renders
    var customNames: [String: String] = [:]  // terminalSessionId → custom display name

    // MARK: PR Tracking
    var trackedPRs: [TrackedPR] = []
    var prLastFetchedAt: Date?
    private var prTimer: Timer?

    // MARK: Alerts
    var alerts: [MegadeskAlert] = []
    var pendingAlertCount: Int = 0
    private(set) var firedAlertIds: Set<UUID> = []
    private(set) var dismissedFiredAlertIds: Set<UUID> = []

    private let sessionsURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/megadesk/sessions")
    }()

    var activeSessionId: String? = nil

    private var watchSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
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

    init() {
        loadCustomNames()
        loadSessions()
        startWatching()
        startTimer()
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
        // Unknown terminals without a real session ID can't be focused
        if session.terminalSessionId == session.sessionId && session.terminal == .unknown {
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

    func displayName(for session: Session) -> String {
        customNames[session.terminalSessionId] ?? session.projectName
    }

    func hasCustomName(for session: Session) -> Bool {
        customNames[session.terminalSessionId] != nil
    }

    func setCustomName(session: Session, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == session.projectName {
            customNames.removeValue(forKey: session.terminalSessionId)
        } else {
            customNames[session.terminalSessionId] = trimmed
        }
        saveCustomNames()
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

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(Session.self, from: data)
            else { continue }

            loaded.append(session)
        }

        // Deduplicate by terminal session ID — one terminal tab = one card
        var seen: [String: Session] = [:]
        for s in loaded {
            if let existing = seen[s.terminalSessionId] {
                if s.lastUpdated > existing.lastUpdated { seen[s.terminalSessionId] = s }
            } else {
                seen[s.terminalSessionId] = s
            }
        }
        let deduped = Array(seen.values)

        sessions = sorted(deduped)
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
            // Every 2 seconds, sync the active session indicator with the current terminal tab.
            if (self?.tick ?? 0) % 2 == 0 { self?.syncActiveSession() }
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

        let group = DispatchGroup()

        if hasItermSessions {
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

        if hasGhosttySessions {
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

    private func syncJSONLWatchers() {
        let activeIds = Set(sessions.map(\.sessionId))

        // Cancel watchers for sessions that are gone
        for id in Set(jsonlWatchers.keys).subtracting(activeIds) {
            jsonlWatchers.removeValue(forKey: id)
            activeToolDetails.removeValue(forKey: id)
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
                print("[Megadesk] kqueue: PID \(pid) exited for \(terminalId) — removing session")
                self?.processSources.removeValue(forKey: terminalId)
                self?.removeSessionFiles(withTerminalId: terminalId)
            }
            source.resume()
            processSources[terminalId] = source
        }
    }

    /// Safety net: removes sessions whose Claude process is dead or unknown.
    /// Catches: kqueue failures, PID recycling, missing claudePid (old hook),
    /// and fallback sessions that the orphan checker skips.
    /// Skips sessions whose terminal tab is still alive — a dead stored PID may
    /// just mean Claude was restarted and the hook hasn't fired yet.
    private func reapDeadSessions() {
        let staleThreshold = Date().timeIntervalSince1970 - 120
        var deadIds: [String] = []
        for session in sessions {
            // Codex sessions don't report PIDs and update infrequently — skip reaping
            if session.provider == .codex { continue }
            if let pid = session.claudePid {
                // Has a PID — check if the process is still alive.
                if kill(pid_t(pid), 0) != 0 && errno != EPERM {
                    // PID is dead, but don't remove if the terminal tab is still open —
                    // a new Claude process may have started that hasn't fired hooks yet.
                    if isTerminalTabAlive(session) {
                        print("[Megadesk] reapDeadSessions: PID \(pid) dead for \(session.projectName) but terminal tab still alive — skipping")
                        continue
                    }
                    print("[Megadesk] reapDeadSessions: removing \(session.projectName) (PID \(pid) dead, tab gone)")
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

    /// Returns true if the session's Claude process is still running.
    private func isClaudePidAlive(_ session: Session) -> Bool {
        guard let pid = session.claudePid else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
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

    func fetchPR(repo: String, number: Int) {
        let id = "\(repo)#\(number)"
        guard let idx = trackedPRs.firstIndex(where: { $0.id == id }) else { return }
        trackedPRs[idx].fetchState = .loading

        let ghPaths = ["/usr/local/bin/gh", "/opt/homebrew/bin/gh"]
        guard let ghPath = ghPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            trackedPRs[idx].fetchState = .error("gh not found")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = [
            "pr", "view", "\(number)",
            "--repo", repo,
            "--json", "number,title,author,headRefName,state,mergeable,mergeStateStatus,statusCheckRollup,url,updatedAt"
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
                        let pr = try JSONDecoder().decode(PullRequest.self, from: data)
                        self.trackedPRs[i].data = pr
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
        ToastWindowController.shared.dismissToast(alertId: id)
        saveAlerts()
    }

    func loadAlerts() {
        guard let data = UserDefaults.standard.data(forKey: "megadesk.alerts"),
              let decoded = try? JSONDecoder().decode([MegadeskAlert].self, from: data)
        else { return }
        alerts = decoded

        // Restore firedAlertIds for .once alerts that fired but weren't dismissed/completed
        for alert in alerts {
            if case .once = alert.recurrence,
               alert.lastFiredAt != nil, !alert.isEnabled, alert.isCompleted != true {
                firedAlertIds.insert(alert.id)
            }
        }
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
        // Guard against double-decrement from multiple dismiss paths
        guard !dismissedFiredAlertIds.contains(id) else { return }
        dismissedFiredAlertIds.insert(id)
        if pendingAlertCount > 0 { pendingAlertCount -= 1 }

        // Mark non-recurring alerts as completed
        if let i = alerts.firstIndex(where: { $0.id == id }),
           case .once = alerts[i].recurrence {
            alerts[i].isCompleted = true
            saveAlerts()
        }
    }

    func clearAlertBadge() {
        pendingAlertCount = 0
    }

    // MARK: - Alert Evaluation

    private func evaluateAlerts() {
        let now = Date()
        // Work on a snapshot so we don't trigger @Observable mutations until we're done.
        var snapshot = alerts
        var toFire: [MegadeskAlert] = []

        for i in snapshot.indices {
            guard snapshot[i].isEnabled else { continue }
            guard !firedAlertIds.contains(snapshot[i].id) else { continue }
            // Skip if snoozed (lastFiredAt set to a future time)
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
            pendingAlertCount += 1
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
            // Snooze: set lastFiredAt forward so nextFireDate returns now+snooze
            self.alerts[i].lastFiredAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
            self.firedAlertIds.remove(alertId)
            self.dismissedFiredAlertIds.remove(alertId)
            if self.pendingAlertCount > 0 { self.pendingAlertCount -= 1 }
            self.saveAlerts()
        }

        NotificationCenter.default.addObserver(forName: .megadeskDismissAlert, object: nil, queue: .main) { [weak self] note in
            guard let self, let alertId = note.userInfo?["alertId"] as? UUID else { return }
            self.dismissFiredAlert(id: alertId)
        }
    }
}
