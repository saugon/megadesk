import SwiftUI

enum MainSection: String, Hashable, CaseIterable, Identifiable {
    case alerts, companion, settings, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alerts:    return "Alerts"
        case .companion: return "Companion"
        case .settings:  return "Settings"
        case .help:      return "Help"
        }
    }

    var icon: String {
        switch self {
        case .alerts:    return "bell"
        case .companion: return "pawprint"
        case .settings:  return "gearshape"
        case .help:      return "questionmark.circle"
        }
    }
}

@Observable final class MainWindowState {
    var selection: MainSection = .alerts
}

struct MainWindowView: View {
    @Bindable var state: MainWindowState

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(MainSection.allCases, selection: Binding(
                get: { state.selection },
                set: { if let new = $0 { state.selection = new } }
            )) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailView: some View {
        switch state.selection {
        case .alerts:
            AlertsView()
        case .companion:
            CompanionSettingsView()
        case .settings:
            SettingsView()
        case .help:
            HelpView()
        }
    }
}
