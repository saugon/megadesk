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
