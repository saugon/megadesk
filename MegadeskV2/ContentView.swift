import SwiftUI

struct ContentView: View {
    @State private var store = StatusStore()

    var body: some View {
        VStack(spacing: 4) {
            if store.sessions.isEmpty {
                emptyState
            } else {
                ForEach(store.sessions) { session in
                    SessionCardView(
                        session: session,
                        tick: store.tick,
                        onFocus: { store.focusTerminal(session: session) },
                        onDismiss: { store.dismiss(session: session) }
                    )
                }
            }
        }
        .padding(8)
        .frame(minWidth: 280, maxWidth: 280)
    }

    private var emptyState: some View {
        Text("No active instances")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
}
