import SwiftUI

struct CompactSessionCardView: View {
    let session: Session
    let tick: Int
    let displayName: String
    let horizontal: Bool
    let onFocus: () -> Bool

    @State private var isHovered = false

    var body: some View {
        Button(action: handleFocus) {
            Group {
                if horizontal {
                    HStack(spacing: 5) {
                        StatusDot(color: dotColor, pulse: shouldPulse)
                        nameLabel(displayName.prefix(8))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                } else {
                    VStack(spacing: 3) {
                        StatusDot(color: dotColor, pulse: shouldPulse)
                        nameLabel(displayName.prefix(4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(cardBackground)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func nameLabel(_ text: some StringProtocol) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .lineLimit(1)
    }

    // MARK: - Focus

    private func handleFocus() {
        _ = onFocus()
    }

    // MARK: - Derived appearance (mirrors SessionCardView)

    private var dotColor: Color {
        if session.needsConfirmation { return .cyan }
        if session.isWorking         { return .green }
        if session.isForgotten       { return Color(white: 0.45) }
        return .orange
    }

    private var shouldPulse: Bool { session.isWorking }

    private var cardBackground: Color {
        if session.needsConfirmation                   { return Color.cyan.opacity(isHovered ? 0.16 : 0.08) }
        if !session.isWorking && !session.isForgotten  { return Color.orange.opacity(isHovered ? 0.16 : 0.08) }
        if session.isForgotten                         { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
        return Color.white.opacity(isHovered ? 0.12 : 0.05)
    }
}
