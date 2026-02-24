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
            DispatchQueue.main.async {
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
    let onFocus: () -> Bool
    let onDismiss: () -> Void
    let onRename: (String) -> Void
    let onEditStart: () -> Void
    let onEditEnd: () -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var isDying = false

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

    @ViewBuilder private var cardContent: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: dotColor, pulse: shouldPulse)
                .padding(.top, 5)

            // Left column: name/TextField + status
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    LimitedTextField(
                        text: $editText,
                        limit: 15,
                        font: .monospacedSystemFont(ofSize: 13, weight: .semibold),
                        onCommit: commitEdit,
                        onCancel: cancelEdit
                    )
                    .frame(height: 18)
                } else {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(session.isForgotten ? .white.opacity(0.4) : .white)
                        .lineLimit(1)
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

            Spacer()

            // Right column: time on top, then shortcut/edit slot below
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(session.timeInState))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))

                // Shortcut hint and edit button share the same slot:
                // shortcut visible at rest, edit button replaces it on hover.
                if isEditing {
                    Button(action: revertToDefault) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(isHovered ? 0.75 : 0.3))
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(isHovered ? 0.12 : 0))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hasCustomName ? 1 : 0)
                } else if !isDying {
                    if isFlashing {
                        ZStack {
                            Text("⇧ ⌥ + ↑ / ↓")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(isHovered ? 0 : 0.45))
                                .fixedSize()

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
                        }
                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                    } else {
                        Button(action: startEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(isHovered ? 0.75 : 0.3))
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(isHovered ? 0.12 : 0))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovered ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: isHovered)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFlashing ? cardBackground.opacity(2.5) : cardBackground)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.2), value: isFlashing)
        )
        .overlay(alignment: .leading) {
            if isFlashing {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .padding(.leading, 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isFlashing)
        .contentShape(Rectangle())
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

    // MARK: - Derived appearance

    private var dotColor: Color {
        if isDying                   { return .red }
        if session.needsConfirmation { return .cyan }
        if session.isWorking         { return .green }
        if session.isForgotten       { return Color(white: 0.45) }
        return .orange
    }

    private var shouldPulse: Bool { session.isWorking && !isDying }

    private var statusLabel: String {
        if isDying                   { return "terminal not found · deleting..." }
        if session.needsConfirmation { return "needs confirmation" }
        if session.isWorking         { return "working" }
        if session.isForgotten       { return "forgotten" }
        return "waiting for input"
    }

    private var labelColor: Color {
        if isDying                   { return .red.opacity(0.8) }
        if session.needsConfirmation { return .cyan.opacity(0.9) }
        if session.isWorking         { return .green.opacity(0.8) }
        if session.isForgotten       { return Color(white: 0.4) }
        return .orange.opacity(0.9)
    }

    private var cardBackground: Color {
        if isDying                                     { return Color.red.opacity(isHovered ? 0.12 : 0.06) }
        if session.needsConfirmation                   { return Color.cyan.opacity(isHovered ? 0.16 : 0.08) }
        if !session.isWorking && !session.isForgotten  { return Color.orange.opacity(isHovered ? 0.16 : 0.08) }
        if session.isForgotten                         { return Color.white.opacity(isHovered ? 0.07 : 0.02) }
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
