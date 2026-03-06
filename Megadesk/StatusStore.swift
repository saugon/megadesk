import Foundation
import AppKit
import Observation
import Darwin

@Observable
final class StatusStore {
    var sessions: [Session] = []
    var tick: Int = 0  // increments every second to force time re-renders
    var customNames: [String: String] = [:]  // itermSessionId → custom display name

    // MARK: PR Tracking
    var trackedPRs: [TrackedPR] = []
    var prLastFetchedAt: Date?
    private var prTimer: Timer?

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

    // kqueue-based process watchers: itermSessionId → DispatchSourceProcess
    private var processSources: [String: DispatchSourceProcess] = [:]

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
        // Fallback sessions (itermSessionId == sessionId) have no associated iTerm2 tab —
        // $ITERM_SESSION_ID wasn't available (e.g. tmux without the env var, or non-iTerm2
        // terminal). We can't focus them but they're not "not found" either.
        guard session.itermSessionId != session.sessionId else {
            activeSessionId = session.sessionId
            return true
        }

        let found = TerminalFocuser.focusiTerm2(sessionId: session.itermSessionId)

        // For tmux sessions the stored iterm_session_id is "{UUID}:{tmux_pane}".
        // If focus fails it means the *original* iTerm2 tab was closed (e.g. after
        // detach/reattach), but Claude is still running inside tmux — don't delete the card.
        if !found && session.itermSessionId.contains(":") {
            activeSessionId = session.sessionId
            return true
        }

        if found { activeSessionId = session.sessionId }
        return found
    }

    func displayName(for session: Session) -> String {
        customNames[session.itermSessionId] ?? session.projectName
    }

    func hasCustomName(for session: Session) -> Bool {
        customNames[session.itermSessionId] != nil
    }

    func setCustomName(session: Session, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == session.projectName {
            customNames.removeValue(forKey: session.itermSessionId)
        } else {
            customNames[session.itermSessionId] = trimmed
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

        // Deduplicate by iTerm session ID — one terminal tab = one card
        var seen: [String: Session] = [:]
        for s in loaded {
            if let existing = seen[s.itermSessionId] {
                if s.lastUpdated > existing.lastUpdated { seen[s.itermSessionId] = s }
            } else {
                seen[s.itermSessionId] = s
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
                if p0 == 3 { return $0.timeInState < $1.timeInState }
                return $0.projectName < $1.projectName
            }
        case .byActivity:
            return list.sorted { $0.lastUpdated > $1.lastUpdated }
        case .byName:
            return list.sorted { $0.projectName < $1.projectName }
        case .byCreation:
            return list.sorted {
                ($0.createdAt ?? $0.stateSince) < ($1.createdAt ?? $1.stateSince)
            }
        }
    }

    private func urgencyPriority(_ s: Session) -> Int {
        if s.needsConfirmation { return 0 }
        if !s.isWorking && !s.isForgotten { return 1 }  // fresh waiting
        if s.isWorking { return 2 }
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
            // Every 10 seconds, ask iTerm2 which tabs are still alive and remove orphaned cards.
            if (self?.tick ?? 0) % 10 == 0 {
                self?.checkOrphanedSessions()
            }
            // Every 2 seconds, sync the active session indicator with iTerm2's current tab.
            if (self?.tick ?? 0) % 2 == 0 {
                self?.syncActiveSession()
            }
        }
    }

    private func syncActiveSession() {
        detectCurrentItermSession { [weak self] currentId in
            DispatchQueue.main.async {
                guard let self, let currentId else { return }
                guard let match = self.sessions.first(where: {
                    $0.itermSessionId.components(separatedBy: ":").first == currentId
                }) else { return }
                if self.activeSessionId != match.sessionId {
                    self.activeSessionId = match.sessionId
                }
            }
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
        let activeIds = Set(sessions.compactMap { $0.claudePid != nil ? $0.itermSessionId : nil })

        // Cancel watchers for sessions no longer loaded
        for id in Set(processSources.keys).subtracting(activeIds) {
            processSources[id]?.cancel()
            processSources.removeValue(forKey: id)
        }

        // Register watchers for new sessions
        for session in sessions {
            guard let pid = session.claudePid,
                  processSources[session.itermSessionId] == nil else { continue }

            // If already dead, remove immediately
            guard kill(pid_t(pid), 0) == 0 || errno == EPERM else {
                removeSessionFiles(withItermId: session.itermSessionId)
                continue
            }

            let itermId = session.itermSessionId
            let source = DispatchSource.makeProcessSource(
                identifier: pid_t(pid),
                eventMask: .exit,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.processSources.removeValue(forKey: itermId)
                self?.removeSessionFiles(withItermId: itermId)
            }
            source.resume()
            processSources[itermId] = source
        }
    }

    /// Queries iTerm2 for all active session IDs and removes session files whose
    /// iTerm2 tab no longer exists (e.g. the user closed the terminal tab).
    private func checkOrphanedSessions() {
        // Skip for the first 30s after launch — iTerm2 may return an incomplete
        // session list immediately after Megadesk restarts, causing false deletions.
        guard Date().timeIntervalSince(startupTime) > 30 else { return }
        let script = """
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

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            guard let result = appleScript?.executeAndReturnError(&error) else { return }

            var activeIds: Set<String> = []
            let count = result.numberOfItems
            if count > 0 {
                for i in 1...count {
                    if let val = result.atIndex(i)?.stringValue {
                        activeIds.insert(val)
                    }
                }
            }

            // If we got no IDs back, play it safe — iTerm2 might have no windows open
            // or returned an unexpected result. Don't wipe everything.
            guard !activeIds.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Collect iTerm session IDs that are no longer present in iTerm2.
                // Skip fallback sessions (itermSessionId == sessionId) — those aren't iTerm2 sessions.
                // Also skip recently-updated sessions: inside tmux $ITERM_SESSION_ID can be stale
                // (e.g. after detach/reattach), but Claude is still actively writing hook events.
                let staleThreshold = Date().timeIntervalSince1970 - 120
                let orphanedItermIds = self.sessions
                    .filter { s in
                        // Strip tmux pane suffix (format: "{iterm_uuid}:{tmux_pane}") before
                        // comparing against iTerm2 active IDs, which only know the bare UUID.
                        let bareId = s.itermSessionId.components(separatedBy: ":").first ?? s.itermSessionId
                        return s.itermSessionId != s.sessionId &&
                            !activeIds.contains(bareId) &&
                            s.lastUpdated < staleThreshold
                    }
                    .map(\.itermSessionId)

                for itermId in orphanedItermIds {
                    self.removeSessionFiles(withItermId: itermId)
                }
            }
        }
    }

    /// Deletes all session JSON files that belong to the given iTerm2 session ID,
    /// then reloads the session list.
    private func removeSessionFiles(withItermId itermId: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        var removed = false
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(Session.self, from: data),
                  session.itermSessionId == itermId
            else { continue }
            try? fm.removeItem(at: file)
            removed = true
        }
        if removed { loadSessions() }
    }

    // MARK: - Session cycling

    private func cycleSession(forward: Bool) {
        guard !sessions.isEmpty else { return }
        // If starting a new cycle, seed lastCycleIndex from the already-tracked activeSessionId
        // (kept up to date by syncActiveSession every 2s) — no async call needed.
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
        focusTerminal(session: session)  // also sets activeSessionId
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
        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            let result = appleScript?.executeAndReturnError(&error)
            completion(result?.stringValue)
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

        // Watchdog: terminate after 15 seconds
        let watchdog = DispatchWorkItem { process.terminate() }
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
}
