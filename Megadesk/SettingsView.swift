import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Paths") {
                    LabeledContent("Repositories") {
                        TextField("~/Repositories", text: $settings.repoBasePath)
                            .font(.system(size: 11, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onChange(of: settings.repoBasePath) { _, _ in settings.save() }
                    }
                    LabeledContent("Clone path") {
                        TextField("~/.megadesk/repos", text: $settings.cloneBasePath)
                            .font(.system(size: 11, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onChange(of: settings.cloneBasePath) { _, _ in settings.save() }
                    }
                }

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
                                .frame(width: 120)
                                .onChange(of: settings.idleOpacity) { _, _ in settings.save() }
                            Text("\(Int(settings.idleOpacity * 100))%")
                                .frame(width: 36, alignment: .trailing)
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
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .onChange(of: settings.sortOrder) { _, _ in settings.save() }
                    }
                }

                Section("Session States") {
                    colorRow("Working",            hex: $settings.hexWorking)
                    colorRow("Needs Confirmation", hex: $settings.hexConfirmation)
                    colorRow("Waiting",            hex: $settings.hexWaiting)
                    colorRow("Forgotten",          hex: $settings.hexForgotten)
                }

                Section("Pull Request States") {
                    colorRow("CI Passing", hex: $settings.hexPRPassing)
                    colorRow("CI Pending", hex: $settings.hexPRPending)
                    colorRow("CI Failing", hex: $settings.hexPRFailing)
                    colorRow("Merged",     hex: $settings.hexPRMerged)
                    colorRow("Closed",     hex: $settings.hexPRClosed)
                }

                Section("Issue States") {
                    colorRow("Open",   hex: $settings.hexIssueOpen)
                    colorRow("Closed", hex: $settings.hexIssueClosed)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
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
