import SwiftUI

struct AlertsView: View {
    private var store = StatusStore.shared
    @Bindable private var settings = AppSettings.shared
    @State private var selectedAlertId: UUID?
    @State private var showingCompleted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Divider()
            detailPane
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
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
            VStack(spacing: 0) {
                detailToolbar(id: id)
                Divider()
                Form {
                    Section("Alert") {
                        TextField("Title", text: stringBinding(id: id, keyPath: \.title))
                            .textFieldStyle(.roundedBorder)

                        Toggle("Enabled", isOn: Binding(
                            get: { store.alerts.first(where: { $0.id == id })?.isEnabled ?? false },
                            set: { store.toggleAlert(id: id, enabled: $0) }
                        ))
                    }

                    Section("Schedule") {
                        recurrencePicker(id: id)
                        dateTimePicker(id: id, recurrence: alert.recurrence)
                    }

                    Section("Notifications") {
                        Toggle("Customize for this alert", isOn: Binding(
                            get: { isCustomized(id: id) },
                            set: { setCustomized(id: id, $0) }
                        ))

                        if isCustomized(id: id) {
                            customDisplayPicker(id: id)
                            Toggle("System notification", isOn: nonNilBoolBinding(id: id, keyPath: \.overrideShowNotification, default: settings.alertShowNotification))
                            Toggle("Menu bar badge", isOn: nonNilBoolBinding(id: id, keyPath: \.overrideShowBadge, default: settings.alertShowBadge))
                            Toggle("Sound", isOn: nonNilBoolBinding(id: id, keyPath: \.overridePlaySound, default: settings.alertPlaySound))
                        }
                    }
                }
                .formStyle(.grouped)
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "bell.slash")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No alert selected")
                    .foregroundStyle(.secondary)
                Button {
                    addAlert()
                } label: {
                    Label("New Alert", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Detail Toolbar

    private func detailToolbar(id: UUID) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                store.fireAlertForTest(id: id)
            } label: {
                Label("Test", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)

            Button {
                selectedAlertId = nil
                store.removeAlert(id: id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .help("Delete alert")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

    // MARK: - Notification Customization

    private func isCustomized(id: UUID) -> Bool {
        guard let a = store.alerts.first(where: { $0.id == id }) else { return false }
        return a.overrideShowToast != nil
            || a.overrideShowWidget != nil
            || a.overrideShowNotification != nil
            || a.overrideShowBadge != nil
            || a.overridePlaySound != nil
    }

    private func setCustomized(id: UUID, _ on: Bool) {
        guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
        if on {
            // Snapshot current global defaults into per-alert overrides
            store.alerts[i].overrideShowToast        = settings.alertShowToast
            store.alerts[i].overrideShowWidget       = settings.alertShowWidget
            store.alerts[i].overrideShowNotification = settings.alertShowNotification
            store.alerts[i].overrideShowBadge        = settings.alertShowBadge
            store.alerts[i].overridePlaySound        = settings.alertPlaySound
        } else {
            store.alerts[i].overrideShowToast        = nil
            store.alerts[i].overrideShowWidget       = nil
            store.alerts[i].overrideShowNotification = nil
            store.alerts[i].overrideShowBadge        = nil
            store.alerts[i].overridePlaySound        = nil
        }
        store.saveAlerts()
    }

    @ViewBuilder
    private func customDisplayPicker(id: UUID) -> some View {
        let alert = store.alerts.first(where: { $0.id == id })
        let currentTag: Int = {
            if alert?.overrideShowToast == true { return 0 }
            if alert?.overrideShowWidget == true { return 1 }
            return 2
        }()
        LabeledContent("Display") {
            Picker("", selection: Binding(
                get: { currentTag },
                set: { tag in
                    guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                    switch tag {
                    case 0: store.alerts[i].overrideShowToast = true;  store.alerts[i].overrideShowWidget = false
                    case 1: store.alerts[i].overrideShowToast = false; store.alerts[i].overrideShowWidget = true
                    default: store.alerts[i].overrideShowToast = false; store.alerts[i].overrideShowWidget = false
                    }
                    store.saveAlerts()
                }
            )) {
                Text("Toast").tag(0)
                Text("Widget").tag(1)
                Text("None").tag(2)
            }
            .labelsHidden()
        }
    }

    private func nonNilBoolBinding(id: UUID, keyPath: WritableKeyPath<MegadeskAlert, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { store.alerts.first(where: { $0.id == id })?[keyPath: keyPath] ?? defaultValue },
            set: {
                guard let i = store.alerts.firstIndex(where: { $0.id == id }) else { return }
                store.alerts[i][keyPath: keyPath] = $0
                store.saveAlerts()
            }
        )
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
