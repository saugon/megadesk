import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Behavior") {
                LabeledContent("Forgotten after") {
                    Stepper("\(settings.forgottenMinutes) min",
                            value: $settings.forgottenMinutes,
                            in: 1...120)
                    .onChange(of: settings.forgottenMinutes) { _, _ in settings.save() }
                }
                LabeledContent("Widget opacity") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.idleOpacity, in: 0.1...1.0)
                            .frame(width: 160)
                            .onChange(of: settings.idleOpacity) { _, _ in settings.save() }
                        Text("\(Int(settings.idleOpacity * 100))%")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Card font size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.cardFontSize, in: 10...18, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.cardFontSize) { _, _ in settings.save() }
                        Text("\(Int(settings.cardFontSize))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 6) {
                        Toggle("Show in session cards", isOn: $settings.showSpinnerVerb)
                            .onChange(of: settings.showSpinnerVerb) { _, _ in settings.save() }
                        Toggle("Animated color", isOn: $settings.spinnerVerbAnimatedColor)
                            .disabled(!settings.showSpinnerVerb)
                            .onChange(of: settings.spinnerVerbAnimatedColor) { _, _ in settings.save() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spinner verb")
                        Text("Show Claude's current activity in session cards")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Sort sessions") {
                    Picker("", selection: $settings.sortOrder) {
                        ForEach(SessionSortOrder.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.sortOrder) { _, _ in settings.save() }
                }
                LabeledContent {
                    Picker("", selection: $settings.prSortOrder) {
                        ForEach(PRSortOrder.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.prSortOrder) { _, _ in settings.save() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sort PRs")
                        Text("By state puts failing CI first, then conflicts, then running checks, then ready, with merged and closed last")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Show permission mode", isOn: $settings.showPermissionMode)
                    .onChange(of: settings.showPermissionMode) { _, _ in settings.save() }
            }

            Section("Collapsed Tab") {
                Toggle("Collapse shortcut (⌘⇧L)", isOn: $settings.peekShortcutEnabled)
                    .onChange(of: settings.peekShortcutEnabled) { _, _ in settings.save() }
                LabeledContent("Style") {
                    Picker("", selection: $settings.peekTabStyle) {
                        ForEach(PeekTabStyle.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.peekTabStyle) { _, _ in settings.save() }
                }
                .disabled(!settings.peekShortcutEnabled)
                LabeledContent("Slot size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.peekSlotHeight, in: 8...32, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.peekSlotHeight) { _, _ in settings.save() }
                        Text("\(Int(settings.peekSlotHeight))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.peekShortcutEnabled || settings.peekTabStyle != .interactive)
            }

            Section("Move Out of the Way") {
                LabeledContent {
                    Toggle("", isOn: $settings.edgeDodgeEnabled)
                        .labelsHidden()
                        .onChange(of: settings.edgeDodgeEnabled) { _, _ in settings.save() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dodge the mouse")
                        Text("The widget and floating companion slide to the nearest edge when the cursor gets close, and return when it leaves")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Modifier key") {
                    Picker("", selection: $settings.edgeDodgeBypassModifier) {
                        ForEach(DodgeModifier.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.edgeDodgeBypassModifier) { _, _ in settings.save() }
                }
                .disabled(!settings.edgeDodgeEnabled)
                LabeledContent("Holding it") {
                    Picker("", selection: $settings.edgeDodgeTriggerMode) {
                        ForEach(DodgeTriggerMode.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.edgeDodgeTriggerMode) { _, _ in settings.save() }
                }
                .disabled(!settings.edgeDodgeEnabled)
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $settings.edgeDodgeReveal, in: 4...80, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.edgeDodgeReveal) { _, _ in settings.save() }
                        Text("\(Int(settings.edgeDodgeReveal))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Peek width")
                        Text("How much of the panel stays visible at the edge while it's hidden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.edgeDodgeEnabled)
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $settings.edgeDodgeReturnDelay, in: 0...2, step: 0.05)
                            .frame(width: 160)
                            .onChange(of: settings.edgeDodgeReturnDelay) { _, _ in settings.save() }
                        Text(settings.edgeDodgeReturnDelay < 0.025
                             ? "none"
                             : String(format: "%.2fs", settings.edgeDodgeReturnDelay))
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Return delay")
                        Text("How long it waits, once the cursor is clear, before sliding back")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.edgeDodgeEnabled)
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $settings.edgeDodgeReturnDuration, in: 0.05...1, step: 0.01)
                            .frame(width: 160)
                            .onChange(of: settings.edgeDodgeReturnDuration) { _, _ in settings.save() }
                        Text(String(format: "%.2fs", settings.edgeDodgeReturnDuration))
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Return duration")
                        Text("How long the slide back takes. Lower is snappier; getting out of the way stays quick")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.edgeDodgeEnabled)
                LabeledContent {
                    Toggle("", isOn: $settings.edgeDodgeHoverPeekEnabled)
                        .labelsHidden()
                        .onChange(of: settings.edgeDodgeHoverPeekEnabled) { _, _ in settings.save() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grow on hover")
                        Text("Enlarge the peek while the cursor is over it, to see more without bringing the panel back")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.edgeDodgeEnabled)
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $settings.edgeDodgeHoverRevealPercent, in: 10...100, step: 5)
                            .frame(width: 160)
                            .onChange(of: settings.edgeDodgeHoverRevealPercent) { _, _ in settings.save() }
                        Text("\(Int(settings.edgeDodgeHoverRevealPercent))%")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grown width")
                        Text("How much of the panel shows while the cursor hovers the peek (100% shows it whole)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.edgeDodgeEnabled || !settings.edgeDodgeHoverPeekEnabled)
            }

            Section("Tasks") {
                LabeledContent {
                    Toggle("", isOn: $settings.tasksEnabled)
                        .labelsHidden()
                        .onChange(of: settings.tasksEnabled) { _, _ in settings.save() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Task module")
                        Text("The counter bar in the widget, the indicator on session cards, the tasks window and its reminders. Switching it off keeps every task saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    Picker("", selection: $settings.taskReminderStyle) {
                        ForEach(TaskReminderStyle.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.taskReminderStyle) { _, _ in settings.save() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reminder style")
                        Text("Companion puts a pet where the toast would go, with the same buttons. It's its own pet, separate from the widget's")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.tasksEnabled)
                LabeledContent("Companion size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.taskCompanionFontSize, in: 8...36, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.taskCompanionFontSize) { _, _ in settings.save() }
                        Text("\(Int(settings.taskCompanionFontSize))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.tasksEnabled || settings.taskReminderStyle != .companion)
            }

            Section("Alert Defaults") {
                LabeledContent("Notify via") {
                    Picker("", selection: Binding(
                        get: {
                            if settings.alertShowToast { return 0 }
                            if settings.alertShowWidget { return 1 }
                            return 2
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
                }
                if settings.alertShowToast {
                    LabeledContent("Toast position") {
                        Picker("", selection: $settings.toastPosition) {
                            ForEach(ToastPosition.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: settings.toastPosition) { _, _ in settings.save() }
                    }
                }
                Toggle("System notification", isOn: $settings.alertShowNotification)
                    .onChange(of: settings.alertShowNotification) { _, _ in settings.save() }
                Toggle("Menu bar badge", isOn: $settings.alertShowBadge)
                    .onChange(of: settings.alertShowBadge) { _, _ in settings.save() }
                Toggle("Sound", isOn: $settings.alertPlaySound)
                    .onChange(of: settings.alertPlaySound) { _, _ in settings.save() }
                LabeledContent("Snooze duration") {
                    Picker("", selection: $settings.snoozeMinutes) {
                        Text("1 min").tag(1)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                    }
                    .labelsHidden()
                    .onChange(of: settings.snoozeMinutes) { _, _ in settings.save() }
                }
            }

            Section("Session States") {
                colorRow("Working",            hex: $settings.hexWorking)
                colorRow("Needs Confirmation", hex: $settings.hexConfirmation)
                colorRow("Waiting",            hex: $settings.hexWaiting)
                colorRow("Forgotten",          hex: $settings.hexForgotten)
            }

            Section("Alerts") {
                colorRow("Alert", hex: $settings.hexAlert)
            }

            Section("Pull Request States") {
                colorRow("CI Passing", hex: $settings.hexPRPassing)
                colorRow("CI Pending", hex: $settings.hexPRPending)
                colorRow("CI Failing", hex: $settings.hexPRFailing)
                colorRow("Merged",     hex: $settings.hexPRMerged)
                colorRow("Closed",     hex: $settings.hexPRClosed)
            }

            Section {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func colorRow(_ label: String, hex: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField("", text: hex)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 76)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: hex.wrappedValue) { _, val in
                        if Color(hex: val) != nil { settings.save() }
                    }

                ColorPicker("", selection: Binding(
                    get: { Color(hex: hex.wrappedValue) ?? Color(white: 0.5) },
                    set: { newColor in
                        hex.wrappedValue = newColor.hexString
                        settings.save()
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)
            }
        }
    }
}
