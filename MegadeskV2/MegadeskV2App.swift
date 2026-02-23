import SwiftUI

@main
struct MegadeskV2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use AppDelegate + NSPanel for always-on-top floating behaviour.
        // This Settings scene is a no-op placeholder to satisfy @main requirements.
        Settings {
            EmptyView()
        }
    }
}
