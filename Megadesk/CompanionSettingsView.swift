import SwiftUI
import AppKit

struct CompanionSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var petRegistry = CompanionPetRegistry.shared

    var body: some View {
        Form {
            Section("Companion") {
                Toggle("Enabled", isOn: $settings.companionEnabled)
                    .onChange(of: settings.companionEnabled) { _, _ in settings.save() }
                petGrid
                    .disabled(!settings.companionEnabled)
                customPetsRow
                    .disabled(!settings.companionEnabled)
                Toggle("Show name", isOn: $settings.companionShowName)
                    .onChange(of: settings.companionShowName) { _, _ in settings.save() }
                    .disabled(!settings.companionEnabled)
                Toggle("Show session summary", isOn: $settings.companionShowStateSummary)
                    .onChange(of: settings.companionShowStateSummary) { _, _ in settings.save() }
                    .disabled(!settings.companionEnabled)
                LabeledContent("Summary orientation") {
                    Picker("", selection: $settings.companionStateSummaryOrientation) {
                        ForEach(CompanionSummaryOrientation.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.companionStateSummaryOrientation) { _, _ in settings.save() }
                }
                .disabled(!settings.companionEnabled || !settings.companionShowStateSummary)
                LabeledContent("Summary side") {
                    Picker("", selection: $settings.companionStateSummarySide) {
                        ForEach(CompanionSummarySide.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.companionStateSummarySide) { _, _ in settings.save() }
                }
                .disabled(!settings.companionEnabled || !settings.companionShowStateSummary || settings.companionStateSummaryOrientation != .vertical)
                LabeledContent("Name size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.companionNameFontSize, in: 7...18, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.companionNameFontSize) { _, _ in settings.save() }
                        Text("\(Int(settings.companionNameFontSize))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.companionEnabled || !settings.companionShowName)
                LabeledContent("Name top gap") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.companionNameTopPadding, in: 0...24, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.companionNameTopPadding) { _, _ in settings.save() }
                        Text("\(Int(settings.companionNameTopPadding))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.companionEnabled || !settings.companionShowName)
                LabeledContent("Name bottom gap") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.companionNameBottomPadding, in: 0...24, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.companionNameBottomPadding) { _, _ in settings.save() }
                        Text("\(Int(settings.companionNameBottomPadding))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.companionEnabled || !settings.companionShowName)
                LabeledContent("Mode") {
                    Picker("", selection: $settings.companionMode) {
                        ForEach(CompanionMode.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.companionMode) { _, _ in settings.save() }
                }
                .disabled(!settings.companionEnabled)
                LabeledContent("Waiting alert") {
                    Stepper("\(settings.companionWaitingThresholdMinutes) min",
                            value: $settings.companionWaitingThresholdMinutes,
                            in: 5...120)
                    .onChange(of: settings.companionWaitingThresholdMinutes) { _, _ in settings.save() }
                }
                .disabled(!settings.companionEnabled)
                LabeledContent("Stuck working alert") {
                    Stepper("\(settings.companionStuckWorkingThresholdMinutes) min",
                            value: $settings.companionStuckWorkingThresholdMinutes,
                            in: 10...180)
                    .onChange(of: settings.companionStuckWorkingThresholdMinutes) { _, _ in settings.save() }
                }
                .disabled(!settings.companionEnabled)
                LabeledContent("Idle alert") {
                    Stepper("\(settings.companionIdleThresholdMinutes) min",
                            value: $settings.companionIdleThresholdMinutes,
                            in: 15...180)
                    .onChange(of: settings.companionIdleThresholdMinutes) { _, _ in settings.save() }
                }
                .disabled(!settings.companionEnabled)
                colorRow("Message highlight", hex: $settings.hexCompanionSubject)
                    .disabled(!settings.companionEnabled)
                colorRow("Pet color", hex: $settings.hexCompanionPet)
                    .disabled(!settings.companionEnabled)
                colorRow("Pet background", hex: $settings.hexCompanionBackground)
                    .disabled(!settings.companionEnabled)
                LabeledContent("Pet size") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.companionFontSize, in: 10...32, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.companionFontSize) { _, _ in settings.save() }
                        Text("\(Int(settings.companionFontSize))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.companionEnabled)
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $settings.companionHorizontalPadding, in: 0...80, step: 1)
                            .frame(width: 160)
                            .onChange(of: settings.companionHorizontalPadding) { _, _ in settings.save() }
                        Text("\(Int(settings.companionHorizontalPadding))pt")
                            .frame(width: 36, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lateral padding")
                        Text("Extra space on the sides — widens the panel so text has more room")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.companionEnabled)
            }

            Section("Recent messages") {
                CompanionHistoryView()
                    .frame(minHeight: 180, maxHeight: 320)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Pet grid

    private var petGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(petRegistry.all) { pet in
                PetGridCell(
                    pet: pet,
                    isSelected: settings.companionPetId == pet.id,
                    petColor: settings.colorCompanionPet,
                    backgroundColor: settings.colorCompanionBackground,
                    needsUpdate: !pet.missingOptionalVoiceKeys.isEmpty
                ) {
                    guard settings.companionPetId != pet.id else { return }
                    settings.companionPetId = pet.id
                    settings.save()
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Pet currently selected in Settings (defaults to default pet if none).
    private var selectedPet: CompanionPetDefinition {
        petRegistry.pet(id: settings.companionPetId) ?? petRegistry.defaultPet
    }

    /// Number of optional voice keys missing from the selected pet, used as
    /// a hint next to the update button so the count doesn't crowd the
    /// button label itself.
    private var missingKeyCount: Int {
        selectedPet.missingOptionalVoiceKeys.count
    }

    // MARK: - Custom pets row

    @ViewBuilder
    private var customPetsRow: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(petRegistry.userPetsURL)
                    } label: {
                        Label("Open folder", systemImage: "folder")
                    }
                    Button {
                        petRegistry.reload()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
                HStack(spacing: 8) {
                    CopyToClipboardButton(title: "Copy new-pet prompt") {
                        CompanionPetRegistry.llmPrompt
                    }
                    CopyToClipboardButton(
                        title: "Copy voice-update prompt",
                        isEnabled: missingKeyCount > 0
                    ) {
                        CompanionPetRegistry.voiceUpdatePrompt(for: selectedPet)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom pets")
                Text("Drop JSONs in the folder, then Reload. Use “new-pet prompt” to generate a fresh pet via an LLM, or “voice-update prompt” to extend the selected pet with new dialogue keys while keeping its voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if missingKeyCount > 0 {
                    Text("“\(selectedPet.displayName)” is missing \(missingKeyCount) optional voice template\(missingKeyCount == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("“\(selectedPet.displayName)” has every voice template defined.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
                        if Color(hex: val) != nil { AppSettings.shared.save() }
                    }

                ColorPicker("", selection: Binding(
                    get: { Color(hex: hex.wrappedValue) ?? Color(white: 0.5) },
                    set: { newColor in
                        hex.wrappedValue = newColor.hexString
                        AppSettings.shared.save()
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)
            }
        }
    }
}

// MARK: - CopyToClipboardButton

/// Button that copies a string payload to the pasteboard and briefly shows
/// a "Copied" checkmark so the user gets confirmation that something happened.
private struct CopyToClipboardButton: View {
    let title: String
    let isEnabled: Bool
    let payload: () -> String?

    @State private var justCopied = false
    @State private var resetWorkItem: DispatchWorkItem?

    init(title: String, isEnabled: Bool = true, payload: @escaping () -> String?) {
        self.title = title
        self.isEnabled = isEnabled
        self.payload = payload
    }

    var body: some View {
        Button(action: copy) {
            Label(
                justCopied ? "Copied" : title,
                systemImage: justCopied ? "checkmark.circle.fill" : "doc.on.clipboard"
            )
            // Fixed minimum width so the button doesn't shrink between the
            // longer normal label and the shorter "Copied" state.
            .frame(minWidth: 160)
        }
        .disabled(!isEnabled)
    }

    private func copy() {
        guard let text = payload() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        justCopied = true
        resetWorkItem?.cancel()
        let item = DispatchWorkItem { justCopied = false }
        resetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
}

// MARK: - PetGridCell

private struct PetGridCell: View {
    let pet: CompanionPetDefinition
    let isSelected: Bool
    let petColor: Color
    let backgroundColor: Color
    let needsUpdate: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    /// Match the font/weight used by the actual pet rendering so previews
    /// look like the live widget.
    private static let artFont = Font(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(backgroundColor)
                        // Leading alignment + fixedSize keeps column alignment of
                        // the ASCII art intact. With .center, SwiftUI trims trailing
                        // spaces per line and recenters each one, breaking the grid.
                        Text(pet.previewFrame?.normalized ?? "")
                            .font(Self.artFont)
                            .foregroundStyle(petColor.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .fixedSize()
                            .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                    )

                    if needsUpdate {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .padding(6)
                            .help("This pet is missing voice templates for new rules. Use “Update voices” to fill them in.")
                    }
                }

                Text(pet.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isHovered  { return .secondary.opacity(0.6) }
        return .secondary.opacity(0.25)
    }
}
