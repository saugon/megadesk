import AppKit
import SwiftUI

final class HelpWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Megadesk Help"
        window.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: HelpView())
        window.contentView = hosting
        window.center()

        let fittingSize = hosting.fittingSize
        if fittingSize.height > 0 {
            window.setContentSize(fittingSize)
            window.center()
        }

        self.init(window: window)
    }
}
