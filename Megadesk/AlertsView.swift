import SwiftUI

struct AlertsView: View {
    private var store = StatusStore.shared
    @Bindable private var settings = AppSettings.shared
    @State private var selectedAlertId: UUID?
    @State private var showingCompleted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 170)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 240)

            Divider()

            notificationSettings
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    // MARK: - Sidebar

    private var activeAlerts: [MegadeskAlert] {
        store.alerts.filter { $0.isCompleted != true }
    }

    private var completedAlerts: [MegadeskAlert] {
        store.alerts.filter { $0.isCompleted == true }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showingCompleted) {
                Text("Alerts").tag(false)
                Text("Completed").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .onChange(of: showingCompleted) { _, _ in selectedAlertId = nil }

            if showingCompleted {
                List(completedAlerts, selection: $selectedAlertId) { alert in
                    alertRow(alert)
                }
                .listStyle(.sidebar)
            } else {
                List(activeAlerts, selection: $selectedAlertId) { alert in
                    alertRow(alert)
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
                    .disabled(completedAlerts.isEmpty)
                } else {
                    ToolbarButton(icon: "plus", action: addAlert)
                    ToolbarButton(icon: "minus", action: removeSelected)
                        .disabled(selectedAlertId == nil)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func alertRow(_ alert: MegadeskAlert) -> some View {
        HStack(spacing: 6) {
            if alert.isCompleted == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 10))
            } else {
                Circle()
                    .fill(alert.isEnabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(alert.isCompleted == true ? completedTimeString(alert) : nextFireSummary(alert))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .tag(alert.id)
    }

    private func completedTimeString(_ alert: MegadeskAlert) -> String {
        guard let fired = alert.lastFiredAt else { return "Completed" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: fired)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedAlertId, let alert = store.alerts.first(where: { $0.id == id }) {
            ScrollView {
                Form {
                    Section("Alert") {
                        TextField("Title", text: stringBinding(id: id, keyPath: \.title))
                            .textFieldStyle(.roundedBorder)

                        Toggle("Enabled", isOn: Binding(
                            get: { store.alerts.first(where: { $0.id == id })?.isEnabled ?? false },
                            set: { store.toggleAlert(id: id, enabled: $0) }
                        ))

                        recurrencePicker(id: id)

                        dateTimePicker(id: id, recurrence: alert.recurrence)
                    }

                    Section("Notification Overrides") {
                        displayOverridePicker(id: id)
                        overrideToggle("Notification", id: id, keyPath: \.overrideShowNotification, globalDefault: settings.alertShowNotification)
                        overrideToggle("Badge", id: id, keyPath: \.overrideShowBadge, globalDefault: settings.alertShowBadge)
                        overrideToggle("Sound", id: id, keyPath: \.overridePlaySound, globalDefault: settings.alertPlaySound)
                    }

                    Section {
                        HStack {
                            Button("Test Alert") {
                                store.fireAlertForTest(id: id)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                selectedAlertId = nil
                                store.removeAlert(id: id)
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            VStack {
                Spacer()
                Text("Select an alert")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Recurrence Picker

    @ViewBuilder
    private func recurrencePicker(id: UUID) -> some View {
        let recurrence = store.alerts.first(where: { $0.id == id })?.recurrence ?? .once

        Picker("Repeat", selection: Binding(
            get: {
                guard let r = store.alerts.first(where: { $0.id == id })?.recurrence else { return 0 }
                return recurrenceTag(r)
            },
            set: { newTag in
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                store.alerts[i].recurrence = recurrenceFromTag(newTag, current: store.alerts[i].recurrence)
                store.saveAlerts()
            }
        )) {
            Text("Once").tag(0)
            Text("Daily").tag(1)
            Text("Weekdays (Mon-Fri)").tag(2)
            Text("Weekly").tag(3)
            Text("Monthly").tag(4)
            Text("Every N minutes").tag(5)
            Text("Every N hours").tag(6)
        }

        switch recurrence {
        case .weekly:
            Picker("Day", selection: Binding(
                get: {
                    guard case .weekly(let w) = store.alerts.first(where: { $0.id == id })?.recurrence else { return 2 }
                    return w
                },
                set: {
                    guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                    store.alerts[i].recurrence = .weekly(weekday: $0)
                    store.saveAlerts()
                }
            )) {
                Text("Sunday").tag(1)
                Text("Monday").tag(2)
                Text("Tuesday").tag(3)
                Text("Wednesday").tag(4)
                Text("Thursday").tag(5)
                Text("Friday").tag(6)
                Text("Saturday").tag(7)
            }

        case .monthly:
            Stepper("Day of month: \(monthDay(id: id))", value: Binding(
                get: { monthDay(id: id) },
                set: {
                    guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                    store.alerts[i].recurrence = .monthly(day: $0)
                    store.saveAlerts()
                }
            ), in: 1...31)

        case .interval:
            intervalValueField(id: id)
            intervalConstraints(id: id)

        default:
            EmptyView()
        }
    }

    private func monthDay(id: UUID) -> Int {
        guard case .monthly(let d) = store.alerts.first(where: { $0.id == id })?.recurrence else { return 1 }
        return d
    }

    // MARK: - Interval Value Field

    @ViewBuilder
    private func intervalValueField(id: UUID) -> some View {
        let recurrence = store.alerts.first(where: { $0.id == id })?.recurrence ?? .interval(minutes: 1)
        let isHours = recurrenceTag(recurrence) == 6

        LabeledContent(isHours ? "Hours" : "Minutes") {
            TextField("", value: Binding(
                get: {
                    guard case .interval(let m) = store.alerts.first(where: { $0.id == id })?.recurrence else { return 1 }
                    return isHours ? m / 60 : m
                },
                set: { newVal in
                    guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                    let clamped = max(1, newVal)
                    store.alerts[i].recurrence = .interval(minutes: isHours ? clamped * 60 : clamped)
                    store.saveAlerts()
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 60)
            .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Interval Constraints (days + time range)

    private static let dayLabels: [(Int, String)] = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")
    ]

    @ViewBuilder
    private func intervalConstraints(id: UUID) -> some View {
        let alert = store.alerts.first(where: { $0.id == id })
        let hasDays = alert?.activeDays != nil
        let hasTime = alert?.activeStartHour != nil

        Toggle("Only on certain days", isOn: Binding(
            get: { hasDays },
            set: { on in
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                store.alerts[i].activeDays = on ? [2, 3, 4, 5, 6] : nil  // default: weekdays
                store.saveAlerts()
            }
        ))

        if hasDays {
            HStack(spacing: 4) {
                ForEach(Self.dayLabels, id: \.0) { weekday, label in
                    let isOn = alert?.activeDays?.contains(weekday) ?? false
                    Button(label) {
                        guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                        if store.alerts[i].activeDays == nil { store.alerts[i].activeDays = [] }
                        if isOn {
                            store.alerts[i].activeDays?.remove(weekday)
                        } else {
                            store.alerts[i].activeDays?.insert(weekday)
                        }
                        store.saveAlerts()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: isOn ? .bold : .regular))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isOn ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isOn ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
            }
        }

        Toggle("Only during time range", isOn: Binding(
            get: { hasTime },
            set: { on in
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                if on {
                    store.alerts[i].activeStartHour = 9
                    store.alerts[i].activeStartMinute = 0
                    store.alerts[i].activeEndHour = 18
                    store.alerts[i].activeEndMinute = 0
                } else {
                    store.alerts[i].activeStartHour = nil
                    store.alerts[i].activeStartMinute = nil
                    store.alerts[i].activeEndHour = nil
                    store.alerts[i].activeEndMinute = nil
                }
                store.saveAlerts()
            }
        ))

        if hasTime {
            HStack {
                Text("From")
                    .font(.system(size: 11))
                timePicker(id: id, hourKey: \.activeStartHour, minuteKey: \.activeStartMinute)
                Text("to")
                    .font(.system(size: 11))
                timePicker(id: id, hourKey: \.activeEndHour, minuteKey: \.activeEndMinute)
            }
        }
    }

    @ViewBuilder
    private func timePicker(id: UUID, hourKey: WritableKeyPath<MegadeskAlert, Int?>, minuteKey: WritableKeyPath<MegadeskAlert, Int?>) -> some View {
        let alert = store.alerts.first(where: { $0.id == id })
        let hour = alert?[keyPath: hourKey] ?? 0
        let minute = alert?[keyPath: minuteKey] ?? 0
        // Build a reference date to bind DatePicker
        let refDate = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()

        DatePicker("", selection: Binding(
            get: { refDate },
            set: { newDate in
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                let cal = Calendar.current
                store.alerts[i][keyPath: hourKey] = cal.component(.hour, from: newDate)
                store.alerts[i][keyPath: minuteKey] = cal.component(.minute, from: newDate)
                store.saveAlerts()
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Date/Time Picker

    @ViewBuilder
    private func dateTimePicker(id: UUID, recurrence: Recurrence) -> some View {
        let dateBinding = dateBinding(id: id)
        switch recurrence {
        case .once:
            DatePicker("Date & Time", selection: dateBinding)
        case .interval:
            EmptyView()
        default:
            DatePicker("Time", selection: dateBinding, displayedComponents: .hourAndMinute)
        }
    }

    // MARK: - Notification Settings

    private var notificationSettings: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                Text("Notify via:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: {
                        if settings.alertShowToast { return 0 }
                        if settings.alertShowWidget { return 1 }
                        return 2  // none
                    },
                    set: { tag in
                        settings.alertShowToast = tag == 0
                        settings.alertShowWidget = tag == 1
                        settings.save()
                    }
                )) {
                    Text("Toast").tag(0)
                    Text("Widget").tag(1)
                    Text("None").tag(2)
                }
                .labelsHidden()
                .fixedSize()
                .font(.system(size: 11))

                Toggle("Notification", isOn: $settings.alertShowNotification)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onChange(of: settings.alertShowNotification) { _, _ in settings.save() }

                Toggle("Badge", isOn: $settings.alertShowBadge)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onChange(of: settings.alertShowBadge) { _, _ in settings.save() }

                Toggle("Sound", isOn: $settings.alertPlaySound)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onChange(of: settings.alertPlaySound) { _, _ in settings.save() }

                Spacer()
            }

            if settings.alertShowToast {
                HStack(spacing: 8) {
                    Text("Toast position:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $settings.toastPosition) {
                        ForEach(ToastPosition.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .font(.system(size: 11))
                    .onChange(of: settings.toastPosition) { _, _ in settings.save() }

                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Text("Snooze duration:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Picker("", selection: $settings.snoozeMinutes) {
                    Text("1 min").tag(1)
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                .labelsHidden()
                .fixedSize()
                .font(.system(size: 11))
                .onChange(of: settings.snoozeMinutes) { _, _ in settings.save() }

                Spacer()
            }
        }
    }

    // MARK: - Display Override (Toast/Widget mutually exclusive)

    @ViewBuilder
    private func displayOverridePicker(id: UUID) -> some View {
        let alert = store.alerts.first(where: { $0.id == id })
        let toastOverride = alert?.overrideShowToast
        let widgetOverride = alert?.overrideShowWidget

        // Compute current effective state for the "Default" label
        let globalLabel: String = {
            if settings.alertShowToast { return "Toast" }
            if settings.alertShowWidget { return "Widget" }
            return "None"
        }()

        // tag: -1 = default, 0 = toast, 1 = widget, 2 = none
        let currentTag: Int = {
            if toastOverride == nil && widgetOverride == nil { return -1 }
            if toastOverride == true { return 0 }
            if widgetOverride == true { return 1 }
            return 2
        }()

        HStack {
            Text("Display")
            Spacer()
            Picker("", selection: Binding(
                get: { currentTag },
                set: { tag in
                    guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                    switch tag {
                    case -1:
                        store.alerts[i].overrideShowToast = nil
                        store.alerts[i].overrideShowWidget = nil
                    case 0:
                        store.alerts[i].overrideShowToast = true
                        store.alerts[i].overrideShowWidget = false
                    case 1:
                        store.alerts[i].overrideShowToast = false
                        store.alerts[i].overrideShowWidget = true
                    default:
                        store.alerts[i].overrideShowToast = false
                        store.alerts[i].overrideShowWidget = false
                    }
                    store.saveAlerts()
                }
            )) {
                Text("Default (\(globalLabel))").tag(-1)
                Text("Toast").tag(0)
                Text("Widget").tag(1)
                Text("None").tag(2)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Per-alert Override Toggle

    /// Three-state toggle: nil (use default), true, false.
    /// Shows "Default (On/Off)" when nil, otherwise the explicit override.
    @ViewBuilder
    private func overrideToggle(_ label: String, id: UUID, keyPath: WritableKeyPath<MegadeskAlert, Bool?>, globalDefault: Bool) -> some View {
        let current = store.alerts.first(where: { $0.id == id })?[keyPath: keyPath]

        HStack {
            Text(label)
            Spacer()
            Picker("", selection: Binding(
                get: {
                    if let v = current { return v ? 1 : 0 }
                    return -1
                },
                set: { tag in
                    guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                    switch tag {
                    case -1: store.alerts[i][keyPath: keyPath] = nil
                    case 1:  store.alerts[i][keyPath: keyPath] = true
                    default: store.alerts[i][keyPath: keyPath] = false
                    }
                    store.saveAlerts()
                }
            )) {
                Text("Default (\(globalDefault ? "On" : "Off"))").tag(-1)
                Text("On").tag(1)
                Text("Off").tag(0)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - ID-based Bindings

    private func stringBinding(id: UUID, keyPath: WritableKeyPath<MegadeskAlert, String>) -> Binding<String> {
        Binding(
            get: { store.alerts.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: {
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                store.alerts[i][keyPath: keyPath] = $0
                store.saveAlerts()
            }
        )
    }

    private func boolBinding(id: UUID, keyPath: WritableKeyPath<MegadeskAlert, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.alerts.first(where: { $0.id == id })?[keyPath: keyPath] ?? false },
            set: {
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                store.alerts[i][keyPath: keyPath] = $0
                store.saveAlerts()
            }
        )
    }

    private func dateBinding(id: UUID) -> Binding<Date> {
        Binding(
            get: { store.alerts.first(where: { $0.id == id })?.date ?? Date() },
            set: {
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                store.alerts[i].date = $0
                store.saveAlerts()
            }
        )
    }

    // MARK: - Helpers

    private func addAlert() {
        let alert = MegadeskAlert()
        store.addAlert(alert)
        selectedAlertId = alert.id
    }

    private func removeSelected() {
        guard let id = selectedAlertId else { return }
        selectedAlertId = nil
        store.removeAlert(id: id)
    }

    private func clearCompleted() {
        selectedAlertId = nil
        for alert in completedAlerts {
            store.removeAlert(id: alert.id)
        }
    }

    private func nextFireSummary(_ alert: MegadeskAlert) -> String {
        guard alert.isEnabled else { return "Disabled" }
        guard let next = alert.nextFireDate() else { return "Won't fire" }
        let formatter = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(next) {
            formatter.dateFormat = "h:mm a"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())),
                  next < tomorrow.addingTimeInterval(86400) {
            formatter.dateFormat = "E h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: next)
    }

    private func recurrenceTag(_ r: Recurrence) -> Int {
        switch r {
        case .once: return 0
        case .daily: return 1
        case .weekdays: return 2
        case .weekly: return 3
        case .monthly: return 4
        case .interval(let m) where m >= 60 && m % 60 == 0: return 6
        case .interval: return 5
        }
    }

    private func recurrenceFromTag(_ tag: Int, current: Recurrence) -> Recurrence {
        switch tag {
        case 0: return .once
        case 1: return .daily
        case 2: return .weekdays
        case 3:
            if case .weekly(let w) = current { return .weekly(weekday: w) }
            return .weekly(weekday: 2)
        case 4:
            if case .monthly(let d) = current { return .monthly(day: d) }
            return .monthly(day: 1)
        case 5:
            if case .interval(let m) = current {
                // Switching from hours → minutes: keep raw value
                return .interval(minutes: m >= 60 ? m / 60 : m)
            }
            return .interval(minutes: 30)
        case 6:
            if case .interval(let m) = current {
                // Switching from minutes → hours: convert to at least 1 hour
                return .interval(minutes: m < 60 ? 60 : max(60, (m / 60) * 60))
            }
            return .interval(minutes: 60)
        default: return .once
        }
    }
}

private struct ToolbarButton: View {
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
