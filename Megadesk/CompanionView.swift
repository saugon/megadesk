import SwiftUI
import AppKit

private struct CompanionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CompanionView: View {
    @State private var engine = CompanionEngine.shared
    @State private var animator = CompanionAnimator()

    /// When true, renders inline inside the widget (fills available width).
    var inline: Bool = false

    private static let ghostFont = Font(NSFont.monospacedSystemFont(ofSize: 16, weight: .regular))
    private static let bubbleFont = Font(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))

    var body: some View {
        Group {
            if inline {
                contentStack
            } else {
                // Floating: push content to the bottom of the hosting view
                // with an explicit Spacer. The ghost always sits at the bottom.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    contentStack
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transaction { $0.animation = nil }
        .onChange(of: engine.currentMessage?.id) { _, _ in
            if inline {
                NotificationCenter.default.post(name: .megadeskCompanionBubbleChanged, object: nil)
            }
        }
        .onChange(of: engine.ghostState) { _, newState in
            animator.ghostState = newState
        }
        .onAppear {
            animator.ghostState = engine.ghostState
            animator.isVisible = true
        }
        .onDisappear {
            animator.isVisible = false
        }
    }

    // MARK: - Content (bubble + ghost), self-measuring

    private var contentStack: some View {
        VStack(spacing: 4) {
            if let message = engine.currentMessage {
                speechBubble(message)
            }
            Text(animator.currentFrame)
                .font(Self.ghostFont)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: CompanionHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(CompanionHeightKey.self) { height in
            if !inline {
                NotificationCenter.default.post(
                    name: .megadeskCompanionContentResized,
                    object: nil,
                    userInfo: ["height": height]
                )
            }
        }
    }

    // MARK: - Speech bubble

    private func speechBubble(_ message: CompanionMessage) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(message.text)
                .font(Self.bubbleFont)
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                engine.dismissMessage()
            } label: {
                Text("\u{00D7}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.12))
        )
        .padding(.horizontal, 6)
        .padding(.top, 10)
    }
}
