import SwiftUI

struct AlertCardView: View {
    let alert: MegadeskAlert
    let isCompact: Bool

    @State private var isHovered = false

    private var alertColor: Color { AppSettings.shared.colorAlert }
    private var nameFontSize: CGFloat { CGFloat(AppSettings.shared.cardFontSize) }
    private var statusFontSize: CGFloat { CGFloat(AppSettings.shared.cardFontSize - 2) }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: alert.lastFiredAt ?? alert.date)
    }

    var body: some View {
        if isCompact {
            compactBody
        } else {
            fullBody
        }
    }

    private var fixedDot: some View {
        Color.clear
            .frame(width: 8, height: 8)
            .overlay(StatusDot(color: alertColor, pulse: true))
    }

    private var compactBody: some View {
        VStack(spacing: 3) {
            fixedDot
            Text(String(alert.title.prefix(4)))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(alertColor.opacity(0.15))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var fullBody: some View {
        HStack(alignment: .center, spacing: 8) {
            fixedDot

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.system(size: nameFontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(timeString)
                    .font(.system(size: statusFontSize))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            HStack(spacing: 4) {
                iconButton("moon.zzz", action: snooze)
                if case .once = alert.recurrence {} else {
                    iconButton("bell.slash", action: disable)
                }
                iconButton("xmark", action: dismiss)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(alertColor.opacity(isHovered ? 0.18 : 0.12))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [alertColor.opacity(0.20), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(PointingHandCursor())
        .onHover { isHovered = $0 }
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        AlertIconButton(systemName: systemName, action: action)
    }

    // MARK: - Actions

    private func snooze() {
        let mins = AppSettings.shared.snoozeMinutes
        NotificationCenter.default.post(name: .megadeskSnoozeAlert, object: nil,
                                        userInfo: ["alertId": alert.id, "minutes": mins])
    }

    private func disable() {
        StatusStore.shared.toggleAlert(id: alert.id, enabled: false)
        StatusStore.shared.dismissFiredAlert(id: alert.id)
    }

    private func dismiss() {
        StatusStore.shared.dismissFiredAlert(id: alert.id)
    }
}

// MARK: - Icon button with individual hover state

private struct AlertIconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.4))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(isHovered ? 0.18 : 0))
                .clipShape(Circle())
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
