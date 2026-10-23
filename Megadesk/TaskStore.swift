import Foundation
import AppKit
import Observation

extension Notification.Name {
    static let megadeskShowTasks          = Notification.Name("megadesk.showTasks")
    static let megadeskCloseTasks         = Notification.Name("megadesk.closeTasks")
    static let megadeskSnoozeTaskReminder = Notification.Name("megadesk.snoozeTaskReminder")
    static let megadeskDismissTaskReminder = Notification.Name("megadesk.dismissTaskReminder")
}

/// Source of truth for the task module. Mirrors how `StatusStore` handles
/// alerts: an @Observable singleton, JSON in UserDefaults, a one-second timer
/// that decides what fires, and the same toast/snooze/settle round-trip.
@Observable
final class TaskStore {
    static let shared = TaskStore()

    var tasks: [MegadeskTask] = []

    /// Bumped once a minute so anything derived from the clock (the overdue
    /// group, the widget counters) re-renders on its own — including across
    /// midnight, when "today" changes without a single task being touched.
    var minuteTick: Int = 0

    /// Reminders that have gone off and haven't been settled yet. Same role as
    /// `StatusStore.firedAlertIds`: it keeps one round from firing twice.
    ///
    /// There is no companion "dismissed" set the way alerts have one: that set
    /// exists to pull an alert's card out of the widget and its dot off the
    /// menu bar, and a task reminder has neither. What a task leaves behind
    /// after its reminder is the task itself, in the list and in the counters.
    private(set) var firedReminderIds: Set<UUID> = []

    private var timer: Timer?
    private var lastMinute: Int = -1
    /// Tasks whose linked session went missing, and since when. A rebind waits
    /// for the session to stay gone: two tabs sharing a pid trade places in
    /// `StatusStore.sessions` from one second to the next, and rebinding on
    /// that would rewrite (and re-save) the link every tick.
    private var danglingSince: [UUID: Date] = [:]
    private static let relinkGracePeriod: TimeInterval = 30

    private init() {
        loadTasks()
        setupReminderObservers()
        observeEnabledSetting()
        startTimer()
    }

    // MARK: - Counters

    private var activeTasks: [MegadeskTask] { tasks.filter { $0.isActive } }

    var openCount: Int { activeTasks.count }

    var overdueCount: Int {
        let now = Date()
        return activeTasks.filter { $0.isOverdue(now: now) }.count
    }

    var todayCount: Int {
        let now = Date()
        return activeTasks.filter { $0.isDueToday(now: now) }.count
    }

    /// How many open tasks point at a given session, for the card indicator.
    /// Zero while the module is off, so the indicator leaves the cards with it.
    func activeTaskCount(forSessionKey key: String) -> Int {
        guard AppSettings.shared.tasksEnabled else { return 0 }
        return tasks.filter { $0.isActive && $0.linkedSessionKey == key }.count
    }

    // MARK: - CRUD

    func addTask(_ task: MegadeskTask) {
        tasks.append(task)
        saveTasks()
    }

    func updateTask(_ task: MegadeskTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
        saveTasks()
    }

    func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        settleReminder(id: id)
        saveTasks()
    }

    /// Completing takes the task out of the active list and, with it, silences
    /// a reminder that would otherwise keep going off forever.
    func setCompleted(id: UUID, _ completed: Bool) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isCompleted = completed
        tasks[i].completedAt = completed ? Date() : nil
        tasks[i].reminderSnoozedUntil = nil
        if completed {
            settleReminder(id: id)
        } else if let next = tasks[i].nextReminderDate(after: Date()), next <= Date() {
            // Back in the list, with a reminder whose moment has already gone
            // by: the clock restarts here instead of going off the instant the
            // task reappears. A reminder still in the future is left alone.
            tasks[i].reminderLastFiredAt = Date()
        }
        saveTasks()
    }

    /// Applies a recurrence edit to the whole series, not just to the copy the
    /// user has in front of them. The schedule belongs to the series: leaving
    /// an older completed instance with the old recurrence would let it take
    /// over as the series head and keep generating tasks after the user
    /// switched repeating off.
    func editRecurrence(taskId: UUID, _ change: (inout MegadeskTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let seriesId = tasks[i].seriesId
        for j in tasks.indices where tasks[j].seriesId == seriesId {
            change(&tasks[j])
        }
        saveTasks()
    }

    /// Next free slot at the end of the hand-dragged order.
    func nextSortIndex() -> Int {
        (tasks.map(\.sortIndex).max() ?? -1) + 1
    }

    /// Reorders a visible slice of the list. The slice carries its own global
    /// positions, so dragging inside one group can't disturb the other.
    func move(within visible: [MegadeskTask], fromOffsets: IndexSet, toOffset: Int) {
        var reordered = visible
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // The slots the slice occupied stay put; only who sits in them changes.
        let slots = visible.compactMap { task in tasks.firstIndex(where: { $0.id == task.id }) }
            .map { tasks[$0].sortIndex }
            .sorted()
        guard slots.count == reordered.count else { return }
        for (slot, task) in zip(slots, reordered) {
            guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            tasks[i].sortIndex = slot
        }
        saveTasks()
    }

    // MARK: - Persistence

    func loadTasks() {
        guard let data = UserDefaults.standard.data(forKey: "megadesk.tasks"),
              let decoded = try? JSONDecoder().decode([MegadeskTask].self, from: data)
        else { return }
        // Drafts belong to an editing session that is over: if one survived,
        // the window (or the app) went away before it was confirmed.
        tasks = decoded.filter { $0.isDraft != true }
        // No pending-reminder state is restored here, unlike `loadAlerts`: an
        // alert that fired and wasn't acknowledged has nothing left to show for
        // it, so it has to be put back. A task that already interrupted once is
        // still in the list, still counted, and still overdue if it was — it
        // doesn't get to interrupt again for the same round.
        if tasks.count != decoded.count { saveTasks() }
    }

    func saveTasks() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: "megadesk.tasks")
        }
    }

    // MARK: - Evaluation loop

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func evaluate() {
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        if minute != lastMinute {
            lastMinute = minute
            minuteTick &+= 1
        }
        // Off means off: nothing fires, nothing is generated, and nothing
        // re-links. The tasks themselves are untouched and come back as they
        // were when the module is switched on again.
        guard AppSettings.shared.tasksEnabled else { return }
        relinkSessions()
        spawnRecurringInstances()
        evaluateReminders()
    }

    // MARK: - Reminders

    private func evaluateReminders() {
        let now = Date()
        // Work on a snapshot so we don't trigger @Observable mutations until
        // we're done.
        var snapshot = tasks
        var toFire: [MegadeskTask] = []

        for i in snapshot.indices {
            guard snapshot[i].isActive, snapshot[i].reminder != nil else { continue }
            guard !firedReminderIds.contains(snapshot[i].id) else { continue }

            // A snooze fires on its own terms: the reminder it belongs to has
            // already had its turn, so its schedule has nothing left to offer
            // and the check below would never let it through.
            if let until = snapshot[i].reminderSnoozedUntil {
                guard until <= now else { continue }
                snapshot[i].reminderSnoozedUntil = nil
                snapshot[i].reminderLastFiredAt = now
                firedReminderIds.insert(snapshot[i].id)
                toFire.append(snapshot[i])
                continue
            }

            if let last = snapshot[i].reminderLastFiredAt, last > now { continue }

            if let next = snapshot[i].nextReminderDate(after: now), next <= now {
                snapshot[i].reminderLastFiredAt = now
                firedReminderIds.insert(snapshot[i].id)
                toFire.append(snapshot[i])
            }
        }

        guard !toFire.isEmpty else { return }

        // Single write back — triggers observation exactly once.
        tasks = snapshot
        saveTasks()

        for task in toFire {
            dispatchReminder(task)
        }

        // Clear the fired flag for repeating reminders after a cooldown so they
        // can come back around. One-shot reminders stay settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            for task in self.tasks where self.firedReminderIds.contains(task.id) {
                guard case .every = task.reminder else { continue }
                self.firedReminderIds.remove(task.id)
            }
        }
    }

    private func dispatchReminder(_ task: MegadeskTask) {
        switch AppSettings.shared.taskReminderStyle {
        case .toast:
            ToastWindowController.shared.showToast(for: task)
        case .companion:
            TaskReminderCompanionController.shared.show(for: task)
        }
    }

    /// Fires a reminder by hand, from the Test button in the tasks window.
    /// A test is a preview, not a round: it deliberately leaves the fired set
    /// alone, so trying a one-shot reminder can't eat the real one.
    func fireReminderForTest(id: UUID) {
        guard AppSettings.shared.tasksEnabled,
              let task = tasks.first(where: { $0.id == id }) else { return }
        dispatchReminder(task)
    }

    /// Settles the round the reminder is in. A one-shot is done for good; a
    /// repeating one comes back at its next interval, which is what "repeats
    /// until the task is completed" means.
    func dismissFiredReminder(id: UUID) {
        // Dismissing settles the round, so drop any snooze still waiting to
        // bring it back.
        if let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].reminderSnoozedUntil != nil {
            tasks[i].reminderSnoozedUntil = nil
            saveTasks()
        }
    }

    /// Takes a reminder off the screen and out of the pending sets. Used when
    /// the task it belongs to is completed, deleted, or switched off with the
    /// module.
    private func settleReminder(id: UUID) {
        firedReminderIds.remove(id)
        ToastWindowController.shared.dismissToast(taskId: id)
        TaskReminderCompanionController.shared.dismiss(taskId: id)
    }

    private func setupReminderObservers() {
        NotificationCenter.default.addObserver(forName: .megadeskSnoozeTaskReminder, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let taskId = note.userInfo?["taskId"] as? UUID,
                  let minutes = note.userInfo?["minutes"] as? Int,
                  let i = self.tasks.firstIndex(where: { $0.id == taskId }) else { return }
            // Snooze gets its own field: pushing `reminderLastFiredAt` into the
            // future instead would bury the reminder, since that field is what
            // tells a one-shot it is done.
            self.tasks[i].reminderSnoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            self.firedReminderIds.remove(taskId)
            self.saveTasks()
        }

        NotificationCenter.default.addObserver(forName: .megadeskDismissTaskReminder, object: nil, queue: .main) { [weak self] note in
            guard let self, let taskId = note.userInfo?["taskId"] as? UUID else { return }
            self.dismissFiredReminder(id: taskId)
        }
    }

    // MARK: - Recurrence

    /// Generates the instance a recurring task owes, at most one per series per
    /// pass. A series with an instance still open skips its turn rather than
    /// stacking duplicates on top of work that isn't done.
    private func spawnRecurringInstances() {
        let now = Date()
        var changed = false

        // The head of a series is its newest task — the one carrying the
        // series' schedule forward.
        var heads: [UUID: Int] = [:]
        for (i, task) in tasks.enumerated() {
            guard task.isDraft != true, task.recurrence.repeats else { continue }
            if let existing = heads[task.seriesId] {
                if task.createdAt > tasks[existing].createdAt { heads[task.seriesId] = i }
            } else {
                heads[task.seriesId] = i
            }
        }

        for (seriesId, index) in heads {
            let head = tasks[index]
            var anchor = head.lastSpawnedAt ?? head.createdAt
            var missed: Date?
            // Every occurrence that went by while the app was closed or the
            // module was off collapses into the latest one.
            var steps = 0
            while steps < 500, let next = head.nextOccurrence(after: anchor), next <= now {
                missed = next
                anchor = next
                steps += 1
            }
            guard let occurrence = missed else { continue }

            tasks[index].lastSpawnedAt = occurrence
            changed = true

            let hasOpenInstance = tasks.contains {
                $0.seriesId == seriesId && $0.isActive
            }
            guard !hasOpenInstance else { continue }

            tasks.append(instance(of: head, at: occurrence))
        }

        if changed { saveTasks() }
    }

    /// A fresh copy of a recurring task, due at the occurrence that called it
    /// up and with its reminder rebased onto that same moment.
    private func instance(of head: MegadeskTask, at occurrence: Date) -> MegadeskTask {
        let now = Date()
        // An instance generated late — the app was closed, or the module was
        // off — is already past the moment it would have spoken up. It arrives
        // overdue in the list instead of interrupting for a time that has gone
        // by, so a stretch away can't turn into a pile of reminders at once.
        let isLate = occurrence < now.addingTimeInterval(-60)

        let rebasedReminder: TaskReminder? = {
            switch head.reminder {
            case .none:                    return nil
            case .at:                      return .at(date: occurrence)
            case .every(let minutes, _):   return .every(minutes: minutes, from: isLate ? now : occurrence)
            }
        }()

        return MegadeskTask(
            title: head.title,
            notes: head.notes,
            priority: head.priority,
            tags: head.tags,
            dueDate: occurrence,
            createdAt: Date(),
            sortIndex: nextSortIndex(),
            linkedSessionKey: head.linkedSessionKey,
            linkedSessionLabel: head.linkedSessionLabel,
            linkedSessionCwd: head.linkedSessionCwd,
            reminder: rebasedReminder,
            reminderLastFiredAt: isLate ? now : nil,
            recurrence: head.recurrence,
            recurrenceHour: head.recurrenceHour,
            recurrenceMinute: head.recurrenceMinute,
            lastSpawnedAt: occurrence,
            seriesId: head.seriesId
        )
    }

    // MARK: - Session links

    /// Sessions die and are reaped, and a tab that comes back gets a new
    /// terminal id. A task whose session is gone keeps its link and rebinds
    /// itself when an equivalent session (same working directory) shows up.
    /// Only the key is rewritten — no task is created or dropped here.
    private func relinkSessions() {
        let sessions = StatusStore.shared.sessions
        guard !sessions.isEmpty else { return }
        let liveKeys = Set(sessions.map(\.terminalSessionId))
        let now = Date()
        var changed = false

        for i in tasks.indices {
            guard let key = tasks[i].linkedSessionKey else { continue }
            let id = tasks[i].id
            guard !liveKeys.contains(key) else {
                // It's back on its own — nothing to rebind.
                danglingSince.removeValue(forKey: id)
                continue
            }
            guard let cwd = tasks[i].linkedSessionCwd,
                  let match = sessions.first(where: { $0.cwd == cwd })
            else { continue }

            // Wait out the grace period before rewriting anything: sessions
            // that share a pid swap places from one tick to the next, and
            // rebinding on that flicker would rewrite the link (and hit the
            // disk) every second, with the card indicator hopping along.
            let since = danglingSince[id] ?? now
            danglingSince[id] = since
            guard now.timeIntervalSince(since) >= Self.relinkGracePeriod else { continue }

            danglingSince.removeValue(forKey: id)
            tasks[i].linkedSessionKey = match.terminalSessionId
            tasks[i].linkedSessionLabel = StatusStore.shared.displayName(for: match)
            changed = true
        }

        // Tasks that went away take their bookkeeping with them.
        let liveTaskIds = Set(tasks.map(\.id))
        danglingSince = danglingSince.filter { liveTaskIds.contains($0.key) }

        if changed { saveTasks() }
    }

    /// Whether the session a task points at is on screen right now. A dead link
    /// still says what it pointed at, it just can't be clicked through.
    func isLinkActive(_ task: MegadeskTask) -> Bool {
        guard let key = task.linkedSessionKey else { return false }
        return StatusStore.shared.sessions.contains { $0.terminalSessionId == key }
    }

    // MARK: - Module toggle

    private func observeEnabledSetting() {
        withObservationTracking {
            _ = AppSettings.shared.tasksEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AppSettings.shared.tasksEnabled {
                    self.resumeModule()
                } else {
                    self.suspendModule()
                }
                self.observeEnabledSetting()
            }
        }
    }

    /// Coming back on doesn't replay the time it spent off: every reminder
    /// that came due in the meantime is marked as gone by, so switching the
    /// module on can't dump a stack of backdated reminders on the screen at
    /// once. The tasks are untouched — the ones that are late still read as
    /// overdue in the window and in the widget's counters.
    private func resumeModule() {
        let now = Date()
        var changed = false
        for i in tasks.indices {
            guard tasks[i].isActive, tasks[i].reminder != nil else { continue }
            if let snoozed = tasks[i].reminderSnoozedUntil, snoozed <= now {
                tasks[i].reminderSnoozedUntil = nil
                changed = true
            }
            guard let next = tasks[i].nextReminderDate(after: now), next <= now else { continue }
            tasks[i].reminderLastFiredAt = now
            changed = true
        }
        if changed { saveTasks() }
    }

    /// Switching the module off clears whatever it had on screen. The tasks
    /// stay on disk exactly as they are.
    private func suspendModule() {
        firedReminderIds.removeAll()
        ToastWindowController.shared.dismissAllTaskToasts()
        TaskReminderCompanionController.shared.dismissAll()
        NotificationCenter.default.post(name: .megadeskCloseTasks, object: nil)
    }
}
