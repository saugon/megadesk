import SwiftUI
import AppKit

/// Transparent overlay that installs an NSTrackingArea with .activeAlways so the
/// pointing-hand cursor fires even in a nonactivatingPanel (which is never the key window).
private struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ nsView: CursorView, context: Context) {}

    final class CursorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Ensure tracking areas are registered as soon as the view enters a window
            updateTrackingAreas()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }
        override func cursorUpdate(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }
        // Return nil so all mouse events fall through to SwiftUI views below
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct SessionCardView: View {
    let session: Session
    let tick: Int
    let onFocus: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        // Outer Button handles focus tap. Inner Button handles dismiss.
        // SwiftUI nested buttons: innermost button wins — no conflict.
        Button(action: onFocus) {
            HStack(alignment: .center, spacing: 8) {
                StatusDot(color: dotColor, pulse: shouldPulse)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.projectName)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(session.isIdle ? .white.opacity(0.4) : .white)
                            .lineLimit(1)

                        Spacer()

                        Text(formatDuration(session.timeInState))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                    }

                    HStack(spacing: 4) {
                        Text(statusLabel)
                            .font(.system(size: 11))
                            .foregroundColor(labelColor)

                        if session.isWorking && !session.needsConfirmation && !session.toolName.isEmpty {
                            Text("(\(session.toolName))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }

                // Dismiss button — only visible on hover
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(isHovered ? 0.1 : 0))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardBackground)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PointingHandCursor())  // behind the button — NSTrackingArea for cursor, hitTest=nil so clicks pass through
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Derived appearance

    private var dotColor: Color {
        if session.needsConfirmation { return .orange }
        if session.isWorking         { return .green }
        if session.isIdle            { return Color(white: 0.45) }
        return Color(hue: 0.1, saturation: 0.8, brightness: 0.95)
    }

    private var shouldPulse: Bool { session.isWorking }

    private var statusLabel: String {
        if session.needsConfirmation { return "needs confirmation" }
        if session.isWorking         { return "working" }
        if session.isIdle            { return "idle" }
        return "waiting for input"
    }

    private var labelColor: Color {
        if session.needsConfirmation { return .orange.opacity(0.9) }
        if session.isWorking         { return .green.opacity(0.8) }
        if session.isIdle            { return Color(white: 0.4) }
        return Color(hue: 0.1, saturation: 0.7, brightness: 0.9)
    }

    private var cardBackground: Color {
        if session.needsConfirmation { return Color.orange.opacity(isHovered ? 0.16 : 0.08) }
        if session.isIdle            { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
        return Color.white.opacity(isHovered ? 0.12 : 0.05)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0   { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

struct StatusDot: View {
    let color: Color
    let pulse: Bool
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse && animating ? 1.4 : 1.0)
            .opacity(pulse && animating ? 0.6 : 1.0)
            .animation(
                pulse
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: animating
            )
            .onAppear { if pulse { animating = true } }
            .onChange(of: pulse) { _, newValue in animating = newValue }
    }
}
