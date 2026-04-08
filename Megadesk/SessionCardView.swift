import SwiftUI
import AppKit

/// NSViewRepresentable wrapping NSTextField that enforces a character limit at the
/// AppKit level, catching both keyboard and paste input reliably.
struct LimitedTextField: NSViewRepresentable {
    @Binding var text: String
    let limit: Int
    let font: NSFont
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.textColor = .white
        tf.font = font
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.stringValue = text
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        // Request focus on the next run-loop tick after the view is installed
        if context.coordinator.needsFocus {
            context.coordinator.needsFocus = false
            DispatchQueue.main.async(qos: .userInteractive) {
                tf.window?.makeFirstResponder(tf)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LimitedTextField
        var needsFocus = true

        init(_ parent: LimitedTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            let capped = String(tf.stringValue.prefix(parent.limit))
            if tf.stringValue != capped { tf.stringValue = capped }
            parent.text = capped
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

/// Transparent overlay that installs an NSTrackingArea with .activeAlways so the
/// pointing-hand cursor fires even in a nonactivatingPanel (which is never the key window).
struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ nsView: CursorView, context: Context) {}

    final class CursorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
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
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct SessionCardView: View {
    let session: Session
    let tick: Int
    let displayName: String
    let hasCustomName: Bool
    let isFlashing: Bool
    let toolDetail: String?
    let spinnerInfo: TerminalFocuser.SpinnerInfo?
    let onFocus: () -> Bool
    let onRename: (String) -> Void
    let onEditStart: () -> Void
    let onEditEnd: () -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var spinnerFrame = 0

    var body: some View {
        // When editing, drop the outer Button so it doesn't intercept the space key
        Group {
            if isEditing {
                cardContent
            } else {
                Button(action: handleFocus) { cardContent }.buttonStyle(.plain)
            }
        }
        .background(PointingHandCursor())
        .onHover { isHovered = $0 }
    }

    private static let spinnerFrames: [String] = [
        "✳", "✶", "✢", "✻", "·", "✽"
    ]

    @ViewBuilder private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            if spinnerInfo != nil && session.isWorking {
                Text(Self.spinnerFrames[spinnerFrame % Self.spinnerFrames.count])
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(spinnerVerbColor)
                    .frame(width: 16, height: 16)
                    .padding(.top, 4)
                    .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                        spinnerFrame += 1
                    }
            } else if session.provider == .codex {
                ProviderBadge(letter: "X", color: dotColor, pulse: shouldPulse,
                              dimmed: session.isForgotten)
                    .padding(.top, 4)
            } else {
                Text("\u{2733}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(session.isForgotten ? Color(white: 0.75) : dotColor)
                    .frame(width: 16, height: 16)
                    .padding(.top, 4)
            }

            // Left column: name/TextField + status
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    LimitedTextField(
                        text: $editText,
                        limit: 15,
                        font: .monospacedSystemFont(ofSize: nameFontSize, weight: .semibold),
                        onCommit: commitEdit,
                        onCancel: cancelEdit
                    )
                    .frame(height: nameFontSize + 5)
                } else {
                    Text(displayName)
                        .font(.system(size: nameFontSize, weight: .semibold, design: .monospaced))
                        .foregroundColor(session.isForgotten && !isFlashing ? .white.opacity(0.4) : .white)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Text(statusLabel)
                        .font(.system(size: statusFontSize))
                        .foregroundColor(labelColor)
                        .lineLimit(1)
                        .animation(.easeInOut(duration: 0.8), value: tick)
                    if session.isWorking && !session.needsConfirmation && spinnerInfo == nil {
                        let detail = toolDetail ?? (session.toolName.isEmpty ? nil : session.toolName)
                        if let detail {
                            Text(detail)
                                .font(.system(size: statusFontSize, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                if let info = spinnerInfo, session.isWorking, !info.detail.isEmpty {
                    Text("(\(info.detail))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            // Right column: duration on top, edit/revert button below (aligned)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(session.timeInState))
                    .font(.system(size: statusFontSize, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))

                if isEditing {
                    Button(action: revertToDefault) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hasCustomName ? 1 : 0)
                } else {
                    Button(action: startEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardBackground)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        )
        .overlay {
            if isFlashing {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [dotColor.opacity(session.isForgotten ? 0.32 : 0.18), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .shadow(color: isFlashing ? dotColor.opacity(session.isForgotten ? 0.5 : 0.3) : .clear,
                radius: isFlashing && session.isForgotten ? 10 : 6, x: 0, y: 0)
        .animation(.easeInOut(duration: 0.2), value: isFlashing)
        .contentShape(Rectangle())
    }

    // MARK: - Focus / dismiss

    private func handleFocus() {
        // Focus may fail for tmux sessions or after detach/reattach where the
        // terminal session ID becomes stale. Don't delete the session — it may
        // still be alive. The orphan checker handles truly dead sessions on a timer.
        _ = onFocus()
    }

    // MARK: - Edit actions

    private func startEdit() {
        editText = displayName
        isEditing = true
        onEditStart()
    }

    private func commitEdit() {
        onRename(editText)
        isEditing = false
        onEditEnd()
    }

    private func cancelEdit() {
        isEditing = false
        onEditEnd()
    }

    private func revertToDefault() {
        onRename("")   // empty → StatusStore clears the custom name
        isEditing = false
        onEditEnd()
    }

    // MARK: - Font sizes (from settings)

    private var nameFontSize: CGFloat { CGFloat(AppSettings.shared.cardFontSize) }
    private var statusFontSize: CGFloat { CGFloat(AppSettings.shared.cardFontSize - 2) }

    // MARK: - Derived appearance

    private var dotColor: Color {
        if session.needsConfirmation { return AppSettings.shared.colorConfirmation }
        if session.isWorking         { return AppSettings.shared.colorWorking }
        if session.isForgotten       { return AppSettings.shared.colorForgotten }
        return AppSettings.shared.colorWaiting
    }

    private var shouldPulse: Bool { session.isWorking }

    private var statusLabel: String {
        if session.needsConfirmation { return "needs confirmation" }
        if session.isWorking {
            if let info = spinnerInfo { return "\(info.verb)\u{2026}" }
            return "working"
        }
        if session.isForgotten       { return "forgotten" }
        return "waiting for input"
    }

    private var labelColor: Color {
        if session.needsConfirmation { return AppSettings.shared.colorConfirmation.opacity(0.9) }
        if session.isWorking {
            if spinnerInfo != nil { return spinnerVerbColor }
            return AppSettings.shared.colorWorking.opacity(0.8)
        }
        if session.isForgotten       { return isFlashing ? Color(white: 0.7) : Color(white: 0.4) }
        return AppSettings.shared.colorWaiting.opacity(0.9)
    }

    /// Animated color for the spinner verb — cycles through warm oranges,
    /// or steady red when high effort is active.
    private var spinnerVerbColor: Color {
        guard let info = spinnerInfo else { return labelColor }
        if info.isHighEffort {
            return Color(hue: 0.02, saturation: 0.85, brightness: 0.9)
        }
        // Triangle wave over 8 seconds: 0→1→0
        let cycle = tick % 8
        let t = cycle < 4 ? Double(cycle) / 4.0 : Double(8 - cycle) / 4.0
        let hue = 0.09 - t * 0.05          // 0.09 (amber) → 0.04 (red-orange)
        let saturation = 0.75 + t * 0.15   // 0.75 → 0.90
        return Color(hue: hue, saturation: saturation, brightness: 0.95)
    }

    private var cardBackground: Color {
        if session.needsConfirmation                   { return AppSettings.shared.colorConfirmation.opacity(isHovered ? 0.16 : 0.08) }
        if !session.isWorking && !session.isForgotten  { return AppSettings.shared.colorWaiting.opacity(isHovered ? 0.16 : 0.08) }
        if session.isForgotten                         { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
        return Color.white.opacity(isHovered ? 0.12 : 0.05)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        let days = total / 86400
        if days > 0    { return "\(days)d \(hours % 24)h" }
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
            .opacity(pulse && animating ? 0.5 : 1.0)
            .onAppear {
                guard pulse else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
            .onChange(of: pulse) { _, newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        animating = true
                    }
                } else {
                    withAnimation(.default) { animating = false }
                }
            }
    }
}

struct ProviderBadge: View {
    let letter: String
    let color: Color
    let pulse: Bool
    var dimmed: Bool = false

    private var scale: CGFloat { CGFloat(AppSettings.shared.cardFontSize) / 13 }

    var body: some View {
        let size = round(16 * scale)
        let fontSize = round(10 * scale)
        Text(letter)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundColor(dimmed ? Color(white: 0.75) : .white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
    }
}
