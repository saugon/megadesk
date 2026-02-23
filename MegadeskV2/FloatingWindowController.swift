import AppKit
import SwiftUI

/// NSHostingView subclass that accepts the first mouse-down event so that
/// clicks on the floating panel fire immediately without first activating the window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FloatingWindowController: NSWindowController {

    convenience init(contentView: some View) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [
                .titled,
                .nonactivatingPanel,
                .fullSizeContentView,
                .resizable,
            ],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor(white: 0.1, alpha: 0.92)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Use FirstMouseHostingView so taps fire on the first click
        panel.contentView = FirstMouseHostingView(rootView:
            contentView
                .background(Color(nsColor: NSColor(white: 0.1, alpha: 0.0)))
        )

        if let corner = panel.contentView {
            corner.wantsLayer = true
            corner.layer?.cornerRadius = 12
            corner.layer?.masksToBounds = true
        }

        self.init(window: panel)
    }

    var isWidgetVisible: Bool { window?.isVisible ?? false }

    func show() {
        guard let window = window else { return }
        if !window.isVisible {
            // Re-position to top-right on first show or after being hidden
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - window.frame.width - 16
                let y = screen.visibleFrame.maxY - window.frame.height - 16
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        isWidgetVisible ? hide() : show()
    }
}
