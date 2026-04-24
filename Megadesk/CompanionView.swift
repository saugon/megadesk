import SwiftUI
import AppKit

private struct CompanionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CompanionGhostWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Invisible overlay that fires a callback when the user right-clicks its bounds.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    private final class CatcherView: NSView {
        var onRightClick: (() -> Void)?
        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return super.hitTest(point)
            }
            return nil
        }
    }
}

struct CompanionView: View {
    @State private var engine = CompanionEngine.shared
    @State private var animator = CompanionAnimator()
    @State private var lastGhostWidth: CGFloat = 0
    @Bindable private var settings = AppSettings.shared

    /// When true, renders inline inside the widget (fills available width).
    var inline: Bool = false

    private static let bubbleFont = Font(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))

    private var ghostFont: Font {
        Font(NSFont.monospacedSystemFont(ofSize: CGFloat(settings.companionFontSize), weight: .regular))
    }

    private var ghostHorizontalPadding: CGFloat {
        CGFloat(settings.companionHorizontalPadding)
    }

    var body: some View {
        Group {
            if inline {
                inlineLayout
            } else {
                floatingLayout
            }
        }
        .background(settings.colorCompanionBackground.opacity(inline ? 1.0 : 0.92))
        .transaction { $0.animation = nil }
        .onChange(of: engine.ghostState) { _, newState in
            animator.ghostState = newState
        }
        .onChange(of: settings.companionPetId) { _, newPetId in
            animator.petId = newPetId
        }
        .onAppear {
            animator.ghostState = engine.ghostState
            animator.petId = settings.companionPetId
            animator.isVisible = true
        }
        .onDisappear {
            animator.isVisible = false
        }
    }

    // MARK: - Inline (docked into widget)
    //
    // The bubble is rendered as an overlay above the ghost so its presence
    // doesn't change the companion section's height. The widget never grows
    // when a message appears/disappears — the bubble simply draws above the
    // ghost, potentially overlapping the sessions/PRs just above it.

    private var inlineLayout: some View {
        ghostAndName
            .overlay(alignment: .top) {
                // VStack wrapper so the alignment guide is always active,
                // even while the bubble is absent.
                VStack(spacing: 0) {
                    if let message = engine.currentMessage {
                        speechBubble(message)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .alignmentGuide(.top) { d in d[.bottom] + 4 }
            }
    }

    // MARK: - Floating (standalone panel)
    //
    // The bubble is a regular child of the VStack so the panel measures it
    // and grows upward (preserving bottom-left) via the size preference
    // notifications. The ghost stays pinned at the bottom.

    private var floatingLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                if let message = engine.currentMessage {
                    speechBubble(message)
                }
                ghostAndName
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: CompanionHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(CompanionHeightKey.self) { height in
                postResize(height: height)
            }
            .onPreferenceChange(CompanionGhostWidthKey.self) { width in
                lastGhostWidth = width
                postResize(ghostWidth: width)
            }
            .onChange(of: settings.companionHorizontalPadding) { _, _ in
                guard lastGhostWidth > 0 else { return }
                postResize(ghostWidth: lastGhostWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ghost + name (shared between layouts)

    private var ghostAndName: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(animator.currentFrame)
                    .font(ghostFont)
                    .foregroundStyle(settings.colorCompanionPet.opacity(0.9))
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: CompanionGhostWidthKey.self, value: geo.size.width)
                        }
                    )
                Spacer(minLength: 0)
            }

            if settings.companionShowName,
               let petName = CompanionPetRegistry.shared.pet(id: settings.companionPetId)?.displayName,
               !petName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(petName)
                    .font(.system(size: CGFloat(settings.companionNameFontSize), weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, CGFloat(settings.companionNameTopPadding))
                    .padding(.bottom, CGFloat(settings.companionNameBottomPadding))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            engine.repeatLastMessage()
        }
        .help("Double-click to repeat the last comment")
        .padding(.horizontal, ghostHorizontalPadding)
        .padding(.vertical, 1)
    }

    private func postResize(height: CGFloat? = nil, ghostWidth: CGFloat? = nil) {
        var info: [AnyHashable: Any] = [:]
        if let h = height { info["height"] = h }
        if let w = ghostWidth { info["width"] = w + ghostHorizontalPadding * 2 }
        guard !info.isEmpty else { return }
        NotificationCenter.default.post(
            name: .megadeskCompanionContentResized,
            object: nil,
            userInfo: info
        )
    }

    // MARK: - Speech bubble

    private func speechBubble(_ message: CompanionMessage) -> some View {
        Text(attributedMessage(message))
            .font(Self.bubbleFont)
            .foregroundStyle(.white)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .overlay(
                RightClickCatcher { engine.dismissMessage() }
            )
            .help("Right-click to dismiss")
            .padding(.horizontal, 6)
            .padding(.top, 10)
    }

    /// Builds an AttributedString where occurrences of `message.subject` are
    /// colored to stand out (uses the session-waiting color from settings).
    private func attributedMessage(_ message: CompanionMessage) -> AttributedString {
        var attr = AttributedString(message.text)
        guard let subject = message.subject, !subject.isEmpty else { return attr }

        var searchRange = attr.startIndex..<attr.endIndex
        while let range = attr[searchRange].range(of: subject) {
            attr[range].foregroundColor = AppSettings.shared.colorCompanionSubject
            attr[range].font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            searchRange = range.upperBound..<attr.endIndex
        }
        return attr
    }
}
