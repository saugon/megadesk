import SwiftUI

struct QuickAlertView: View {
    @State private var title = ""
    @State private var minutes = 5
    @FocusState private var titleFocused: Bool
    let onDismiss: () -> Void

    private let presets = [1, 5, 10, 15, 30, 60]

    var body: some View {
        VStack(spacing: 8) {
            TextField("Reminder...", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($titleFocused)
                .onSubmit { create() }

            HStack(spacing: 3) {
                ForEach(presets, id: \.self) { m in
                    Button {
                        minutes = m
                    } label: {
                        Text(m < 60 ? "\(m)m" : "\(m / 60)h")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: minutes == m ? .bold : .regular))
                    .foregroundStyle(minutes == m ? .primary : .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(minutes == m ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(minutes == m ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }

                Spacer()

                Button { create() } label: {
                    Text("Create").lineLimit(1).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .onAppear { titleFocused = true }
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let alert = MegadeskAlert(
            title: trimmed,
            date: Date().addingTimeInterval(TimeInterval(minutes * 60)),
            recurrence: .once,
            isEnabled: true
        )
        StatusStore.shared.addAlert(alert)
        onDismiss()
    }
}
