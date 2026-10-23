import SwiftUI

struct TasksView: View {
    private var store = TaskStore.shared
    private var sessionStore = StatusStore.shared

    @State private var selectedTaskId: UUID?
    @State private var showingCompleted = false
    /// The task being created, if any. It already lives in the store so the
    /// whole editor works on it unchanged, but it stays out of the list and
    /// can't remind until it's confirmed.
    @State private var draftId: UUID?
    @State private var tagsText = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            detailPane
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .frame(minWidth: 620, minHeight: 440)
        .onDisappear { discardDraft() }
    }

    // MARK: - Lists

    /// Hand-dragged order. Priority and due date show up in the row but never
    /// move anything.
    private var orderedActive: [MegadeskTask] {
        store.tasks.filter { $0.isActive }.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var overdueTasks: [MegadeskTask] {
        let now = Date()
        return orderedActive.filter { $0.isOverdue(now: now) }
    }

    private var upcomingTasks: [MegadeskTask] {
        let now = Date()
        return orderedActive.filter { !$0.isOverdue(now: now) }
    }

    private var completedTasks: [MegadeskTask] {
        store.tasks.filter { $0.isCompleted }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            let _ = store.minuteTick  // regroup overdue as the clock moves

            Picker("", selection: $showingCompleted) {
                Text("Tasks").tag(false)
                Text("Completed").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .onChange(of: showingCompleted) { _, _ in selectedTaskId = nil }
            .onChange(of: selectedTaskId) { _, newValue in
                // Walking away from a half-filled new task throws it out.
                if let draftId, draftId != newValue { discardDraft() }
                syncTagsField()
            }

            if showingCompleted {
                List(selection: $selectedTaskId) {
                    ForEach(completedTasks) { task in
                        taskRow(task)
                    }
                }
                .listStyle(.sidebar)
            } else {
                List(selection: $selectedTaskId) {
                    if !overdueTasks.isEmpty {
                        Section("Overdue") {
                            ForEach(overdueTasks) { task in
                                taskRow(task)
                            }
                            .onMove { from, to in
                                store.move(within: overdueTasks, fromOffsets: from, toOffset: to)
                            }
                        }
                        Section("Tasks") {
                            ForEach(upcomingTasks) { task in
                                taskRow(task)
                            }
                            .onMove { from, to in
                                store.move(within: upcomingTasks, fromOffsets: from, toOffset: to)
                            }
                        }
                    } else {
                        ForEach(upcomingTasks) { task in
                            taskRow(task)
                        }
                        .onMove { from, to in
                            store.move(within: upcomingTasks, fromOffsets: from, toOffset: to)
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack(spacing: 12) {
                if showingCompleted {
                    Button(action: clearCompleted) {
                        Text("Clear All")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(completedTasks.isEmpty)
                } else {
                    TaskToolbarButton(icon: "plus", action: addTask)
                    TaskToolbarButton(icon: "minus", action: removeSelected)
                        .disabled(selectedTaskId == nil)
                    Text("drag to reorder")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func taskRow(_ task: MegadeskTask) -> some View {
        HStack(spacing: 8) {
            Button {
                store.setCompleted(id: task.id, !task.isCompleted)
                if task.isCompleted == false && selectedTaskId == task.id { selectedTaskId = nil }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .green : task.priority.color)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "Move back to the task list" : "Complete")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(task.isCompleted)
                HStack(spacing: 5) {
                    Text(rowSubtitle(task))
                        .font(.system(size: 10))
                        .foregroundStyle(task.isOverdue() ? AppSettings.shared.colorAlert : .secondary)
                        .lineLimit(1)
                    if task.reminder != nil {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    if task.recurrence.repeats {
                        Image(systemName: "repeat")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    if task.linkedSessionKey != nil {
                        Image(systemName: store.isLinkActive(task) ? "link" : "link.badge.plus")
                            .font(.system(size: 8))
                            .foregroundStyle(store.isLinkActive(task) ? .secondary : .tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if !task.tags.isEmpty {
                Text(task.tags.prefix(2).joined(separator: " · "))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .tag(task.id)
    }

    private func rowSubtitle(_ task: MegadeskTask) -> String {
        if task.isCompleted {
            guard let done = task.completedAt else { return "Completed" }
            return "Completed \(Self.shortFormatter.string(from: done))"
        }
        if let due = task.dueDate {
            return (task.isOverdue() ? "Overdue " : "Due ") + Self.shortFormatter.string(from: due)
        }
        if let next = task.nextReminderDate() {
            return "Reminds \(Self.shortFormatter.string(from: next))"
        }
        if task.recurrence.repeats { return task.recurrence.label }
        return task.priority == .none ? "No due date" : task.priority.label
    }

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedTaskId, let task = store.tasks.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                detailToolbar(id: id, task: task)
                Divider()
                Form {
                    Section("Task") {
                        TextField("Title", text: stringBinding(id: id, keyPath: \.title))
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                            .onSubmit { if isDraft(id) { commitDraft() } }

                        LabeledContent("Notes") {
                            TextEditor(text: stringBinding(id: id, keyPath: \.notes))
                                .font(.system(size: 12))
                                .frame(height: 64)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                )
                        }

                        Picker("Priority", selection: Binding(
                            get: { store.tasks.first(where: { $0.id == id })?.priority ?? .none },
                            set: { newValue in
                                mutate(id) { $0.priority = newValue }
                            }
                        )) {
                            ForEach(TaskPriority.allCases) { Text($0.label).tag($0) }
                        }

                        LabeledContent("Tags") {
                            TextField("comma, separated", text: $tagsText)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: tagsText) { _, newValue in commitTags(id: id, newValue) }
                        }
                    }

                    Section("Due") {
                        Toggle("Has a due date", isOn: Binding(
                            get: { task.dueDate != nil },
                            set: { on in
                                mutate(id) { $0.dueDate = on ? Self.defaultDueDate() : nil }
                            }
                        ))
                        if task.dueDate != nil {
                            DatePicker("Date & Time", selection: Binding(
                                get: { store.tasks.first(where: { $0.id == id })?.dueDate ?? Date() },
                                set: { newValue in mutate(id) { $0.dueDate = newValue } }
                            ))
                        }
                    }

                    Section("Reminder") {
                        reminderPicker(id: id, task: task)
                    }

                    Section("Repeat") {
                        recurrencePicker(id: id, task: task)
                    }

                    Section("Session") {
                        sessionPicker(id: id, task: task)
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checklist")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No task selected")
                    .foregroundStyle(.secondary)
                Button {
                    addTask()
                } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func detailToolbar(id: UUID, task: MegadeskTask) -> some View {
        if isDraft(id) {
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { discardDraft() }
                    .buttonStyle(.bordered)
                Button("Create") { commitDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommitDraft)
                    .help(canCommitDraft ? "Add this task" : "Give the task a title first")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 8) {
                Spacer()
                if task.reminder != nil {
                    Button {
                        store.fireReminderForTest(id: id)
                    } label: {
                        Label("Test", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    store.setCompleted(id: id, !task.isCompleted)
                    selectedTaskId = nil
                } label: {
                    Label(task.isCompleted ? "Reopen" : "Complete",
                          systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark")
                }
                .buttonStyle(.bordered)

                Button {
                    selectedTaskId = nil
                    store.removeTask(id: id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .help("Delete task")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Reminder

    @ViewBuilder
    private func reminderPicker(id: UUID, task: MegadeskTask) -> some View {
        Picker("Remind me", selection: Binding(
            get: { Self.reminderTag(task.reminder) },
            set: { tag in
                mutate(id) { t in
                    t.reminder = Self.reminder(fromTag: tag, current: t.reminder)
                    // A new schedule is a new round: whatever the old one had
                    // already done doesn't count against it.
                    t.reminderLastFiredAt = nil
                    t.reminderSnoozedUntil = nil
                }
            }
        )) {
            Text("Never").tag(0)
            Text("At a time").tag(1)
            Text("Every N minutes").tag(2)
            Text("Every N hours").tag(3)
        }

        switch task.reminder {
        case .at:
            DatePicker("Date & Time", selection: Binding(
                get: {
                    guard case .at(let date) = store.tasks.first(where: { $0.id == id })?.reminder else { return Date() }
                    return date
                },
                set: { newValue in
                    mutate(id) { t in
                        t.reminder = .at(date: newValue)
                        t.reminderLastFiredAt = nil
                        t.reminderSnoozedUntil = nil
                    }
                }
            ))

        case .every(let minutes, _):
            let isHours = minutes >= 60 && minutes % 60 == 0
            LabeledContent(isHours ? "Hours" : "Minutes") {
                TextField("", value: Binding(
                    get: { isHours ? minutes / 60 : minutes },
                    set: { newValue in
                        let clamped = max(1, newValue)
                        mutate(id) { t in
                            guard case .every(_, let start) = t.reminder else { return }
                            t.reminder = .every(minutes: isHours ? clamped * 60 : clamped, from: start)
                        }
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
            }

            DatePicker("Starting", selection: Binding(
                get: {
                    guard case .every(_, let start) = store.tasks.first(where: { $0.id == id })?.reminder else { return Date() }
                    return start
                },
                set: { newValue in
                    mutate(id) { t in
                        guard case .every(let m, _) = t.reminder else { return }
                        t.reminder = .every(minutes: m, from: newValue)
                        t.reminderLastFiredAt = nil
                    }
                }
            ))

            Button("Start now") {
                mutate(id) { t in
                    guard case .every(let m, _) = t.reminder else { return }
                    t.reminder = .every(minutes: m, from: Date())
                    t.reminderLastFiredAt = nil
                    t.reminderSnoozedUntil = nil
                }
            }
            .buttonStyle(.link)

            Text("Repeats until the task is completed.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .none:
            EmptyView()
        }
    }

    private static func reminderTag(_ reminder: TaskReminder?) -> Int {
        switch reminder {
        case .none: return 0
        case .at: return 1
        case .every(let m, _): return (m >= 60 && m % 60 == 0) ? 3 : 2
        }
    }

    private static func reminder(fromTag tag: Int, current: TaskReminder?) -> TaskReminder? {
        switch tag {
        case 1:
            return .at(date: defaultDueDate())
        case 2:
            if case .every(let m, let from) = current {
                return .every(minutes: m >= 60 ? m / 60 : m, from: from)
            }
            return .every(minutes: 30, from: Date())
        case 3:
            if case .every(let m, let from) = current {
                return .every(minutes: m < 60 ? 60 : max(60, (m / 60) * 60), from: from)
            }
            return .every(minutes: 60, from: Date())
        default:
            return nil
        }
    }

    // MARK: - Recurrence

    @ViewBuilder
    private func recurrencePicker(id: UUID, task: MegadeskTask) -> some View {
        // Every recurrence edit goes through `editRecurrence`, which writes it
        // across the whole series: a copy left behind with the old schedule
        // would keep generating tasks after the user switched repeating off.
        Picker("Repeats", selection: Binding(
            get: { Self.recurrenceTag(task.recurrence) },
            set: { tag in
                store.editRecurrence(taskId: id) { t in
                    t.recurrence = Self.recurrence(fromTag: tag, current: t.recurrence)
                    // Start the series from here, so switching it on doesn't
                    // instantly generate the occurrences of a past it never had.
                    t.lastSpawnedAt = Date()
                }
            }
        )) {
            Text("Never").tag(0)
            Text("Daily").tag(1)
            Text("Weekdays (Mon-Fri)").tag(2)
            Text("Weekly").tag(3)
            Text("Monthly").tag(4)
        }

        if task.recurrence.repeats {
            if case .weekly = task.recurrence {
                Picker("Day", selection: Binding(
                    get: {
                        guard case .weekly(let w) = store.tasks.first(where: { $0.id == id })?.recurrence else { return 2 }
                        return w
                    },
                    set: { newValue in store.editRecurrence(taskId: id) { $0.recurrence = .weekly(weekday: newValue) } }
                )) {
                    Text("Sunday").tag(1)
                    Text("Monday").tag(2)
                    Text("Tuesday").tag(3)
                    Text("Wednesday").tag(4)
                    Text("Thursday").tag(5)
                    Text("Friday").tag(6)
                    Text("Saturday").tag(7)
                }
            }

            if case .monthly(let day) = task.recurrence {
                Stepper("Day of month: \(day)", value: Binding(
                    get: { day },
                    set: { newValue in store.editRecurrence(taskId: id) { $0.recurrence = .monthly(day: newValue) } }
                ), in: 1...31)
            }

            DatePicker("At", selection: Binding(
                get: {
                    let t = store.tasks.first(where: { $0.id == id })
                    return Calendar.current.date(bySettingHour: t?.recurrenceHour ?? 9,
                                                 minute: t?.recurrenceMinute ?? 0,
                                                 second: 0, of: Date()) ?? Date()
                },
                set: { newValue in
                    let cal = Calendar.current
                    store.editRecurrence(taskId: id) { t in
                        t.recurrenceHour = cal.component(.hour, from: newValue)
                        t.recurrenceMinute = cal.component(.minute, from: newValue)
                    }
                }
            ), displayedComponents: .hourAndMinute)

            Text("A new copy appears at each occurrence, once the previous one is done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func recurrenceTag(_ recurrence: TaskRecurrence) -> Int {
        switch recurrence {
        case .never:    return 0
        case .daily:    return 1
        case .weekdays: return 2
        case .weekly:   return 3
        case .monthly:  return 4
        }
    }

    private static func recurrence(fromTag tag: Int, current: TaskRecurrence) -> TaskRecurrence {
        switch tag {
        case 1: return .daily
        case 2: return .weekdays
        case 3:
            if case .weekly(let w) = current { return .weekly(weekday: w) }
            return .weekly(weekday: 2)
        case 4:
            if case .monthly(let d) = current { return .monthly(day: d) }
            return .monthly(day: 1)
        default: return .never
        }
    }

    // MARK: - Session link

    @ViewBuilder
    private func sessionPicker(id: UUID, task: MegadeskTask) -> some View {
        let sessions = sessionStore.sessions
        let linkedKey = task.linkedSessionKey
        let isDangling = linkedKey != nil && !sessions.contains { $0.terminalSessionId == linkedKey }

        Picker("Linked session", selection: Binding<String>(
            get: { linkedKey ?? "" },
            set: { newKey in
                mutate(id) { t in
                    guard !newKey.isEmpty,
                          let session = sessions.first(where: { $0.terminalSessionId == newKey }) else {
                        if newKey.isEmpty {
                            t.linkedSessionKey = nil
                            t.linkedSessionLabel = nil
                            t.linkedSessionCwd = nil
                        }
                        return
                    }
                    t.linkedSessionKey = session.terminalSessionId
                    t.linkedSessionLabel = sessionStore.displayName(for: session)
                    t.linkedSessionCwd = session.cwd
                }
            }
        )) {
            Text("None").tag("")
            ForEach(sessions) { session in
                Text(sessionStore.displayName(for: session)).tag(session.terminalSessionId)
            }
            if isDangling, let key = linkedKey {
                Text("\(task.linkedSessionLabel ?? "Session") (gone)").tag(key)
            }
        }

        if isDangling {
            Text("That session isn't running. The task keeps the link and picks it up again when a session opens in the same folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private func mutate(_ id: UUID, _ change: (inout MegadeskTask) -> Void) {
        guard let i = store.tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&store.tasks[i])
        store.saveTasks()
    }

    private func stringBinding(id: UUID, keyPath: WritableKeyPath<MegadeskTask, String>) -> Binding<String> {
        Binding(
            get: { store.tasks.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in mutate(id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func commitTags(id: UUID, _ text: String) {
        let parsed = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        mutate(id) { $0.tags = parsed }
    }

    private func syncTagsField() {
        guard let id = selectedTaskId, let task = store.tasks.first(where: { $0.id == id }) else {
            tagsText = ""
            return
        }
        tagsText = task.tags.joined(separator: ", ")
    }

    // MARK: - Helpers

    private static func defaultDueDate() -> Date {
        let cal = Calendar.current
        let inAnHour = Date().addingTimeInterval(3600)
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: inAnHour)
        return cal.date(from: comps) ?? inAnHour
    }

    private func addTask() {
        discardDraft()
        showingCompleted = false
        var task = MegadeskTask(title: "", sortIndex: store.nextSortIndex())
        task.isDraft = true
        store.addTask(task)
        draftId = task.id
        selectedTaskId = task.id
        tagsText = ""
        DispatchQueue.main.async { titleFocused = true }
    }

    private func isDraft(_ id: UUID) -> Bool { draftId == id }

    private var canCommitDraft: Bool {
        guard let draftId, let task = store.tasks.first(where: { $0.id == draftId }) else { return false }
        return !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Turns the draft into a real task: it shows up in the list and its
    /// reminder starts counting down from here.
    private func commitDraft() {
        guard canCommitDraft, let id = draftId else { return }
        mutate(id) { task in
            task.isDraft = nil
            task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        draftId = nil
        titleFocused = false
        selectedTaskId = id
    }

    private func discardDraft() {
        guard let id = draftId else { return }
        draftId = nil
        titleFocused = false
        store.removeTask(id: id)
        if selectedTaskId == id { selectedTaskId = nil }
    }

    private func removeSelected() {
        guard let id = selectedTaskId else { return }
        selectedTaskId = nil
        store.removeTask(id: id)
    }

    private func clearCompleted() {
        selectedTaskId = nil
        for task in completedTasks {
            store.removeTask(id: task.id)
        }
    }
}

private struct TaskToolbarButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .onHover { isHovered = $0 }
    }
}
