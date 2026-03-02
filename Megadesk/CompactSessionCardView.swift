import SwiftUI

struct CompactSessionCardView: View {
    let session: Session
    let tick: Int
    let displayName: String
    let onFocus: () -> Bool
    let onDismiss: () -> Void

    @State private var isHovered = false
    @State private var isDying = false

    var body: some View {
        Button(action: handleFocus) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    StatusDot(color: dotColor, pulse: shouldPulse)
                    Text(session.provider == .codex ? "X" : "C")
                        .font(.system(size: 6, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .offset(x: 6, y: -4)
                }
                Text(displayName.prefix(4))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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

    // MARK: - Focus / dismiss

    private func handleFocus() {
        guard !isDying else { return }
        if !onFocus() {
            isDying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                onDismiss()
            }
        }
    }

    // MARK: - Derived appearance (mirrors SessionCardView)

    private var dotColor: Color {
        if isDying                   { return .red }
        if session.needsConfirmation { return .cyan }
        if session.isWorking         { return .green }
        if session.isForgotten       { return Color(white: 0.45) }
        if session.isIdle            { return Color(white: 0.45) }
        return .orange
    }

    private var shouldPulse: Bool { session.isWorking && !isDying }

    private var cardBackground: Color {
        if isDying                                     { return Color.red.opacity(isHovered ? 0.12 : 0.06) }
        if session.needsConfirmation                   { return Color.cyan.opacity(isHovered ? 0.16 : 0.08) }
        if session.isIdle                              { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
        if !session.isWorking && !session.isForgotten  { return Color.orange.opacity(isHovered ? 0.16 : 0.08) }
        if session.isForgotten                         { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
        return Color.white.opacity(isHovered ? 0.12 : 0.05)
    }
}
