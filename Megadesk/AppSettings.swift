import SwiftUI

enum SessionSortOrder: String, CaseIterable {
    case byState    = "state"
    case byActivity = "activity"
    case byName     = "name"
    case byCreation = "creation"

    var label: String {
        switch self {
        case .byState:    return "By state"
        case .byActivity: return "By recent activity"
        case .byName:     return "By name"
        case .byCreation: return "By creation"
        }
    }
}

/// Global app settings — colors and behavior. Observable so views react to changes.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // MARK: - Behavior
    var forgottenMinutes: Int
    var sortOrder: SessionSortOrder
    var idleOpacity: Double

    // MARK: - Paths
    var repoBasePath: String
    var cloneBasePath: String

    // MARK: - Session state colors (stored as hex strings)
    var hexWorking:      String
    var hexConfirmation: String
    var hexWaiting:      String
    var hexForgotten:    String

    // MARK: - PR state colors
    var hexPRPassing: String
    var hexPRPending: String
    var hexPRFailing: String
    var hexPRMerged:  String
    var hexPRClosed:  String

    // MARK: - Computed Color accessors
    var colorWorking:      Color { Color(hex: hexWorking)      ?? .green }
    var colorConfirmation: Color { Color(hex: hexConfirmation) ?? .cyan  }
    var colorWaiting:      Color { Color(hex: hexWaiting)      ?? .orange }
    var colorForgotten:    Color { Color(hex: hexForgotten)    ?? Color(white: 0.45) }

    var colorPRPassing: Color { Color(hex: hexPRPassing) ?? .green }
    var colorPRPending: Color { Color(hex: hexPRPending) ?? .orange }
    var colorPRFailing: Color { Color(hex: hexPRFailing) ?? .red }
    var colorPRMerged:  Color { Color(hex: hexPRMerged)  ?? .cyan }
    var colorPRClosed:  Color { Color(hex: hexPRClosed)  ?? Color(white: 0.45) }

    private init() {
        let ud = UserDefaults.standard
        forgottenMinutes = ud.object(forKey: "megadesk.forgottenMinutes") as? Int ?? 5
        sortOrder    = SessionSortOrder(rawValue: ud.string(forKey: "megadesk.sortOrder") ?? "") ?? .byState
        idleOpacity  = ud.object(forKey: "megadesk.idleOpacity") as? Double ?? 1.0
        hexWorking       = ud.string(forKey: "megadesk.color.working")      ?? "#34C759"
        hexConfirmation  = ud.string(forKey: "megadesk.color.confirmation") ?? "#5AC8FA"
        hexWaiting       = ud.string(forKey: "megadesk.color.waiting")      ?? "#FF9500"
        hexForgotten     = ud.string(forKey: "megadesk.color.forgotten")    ?? "#737373"
        hexPRPassing     = ud.string(forKey: "megadesk.color.pr.passing")   ?? "#34C759"
        hexPRPending     = ud.string(forKey: "megadesk.color.pr.pending")   ?? "#FF9500"
        hexPRFailing     = ud.string(forKey: "megadesk.color.pr.failing")   ?? "#FF3B30"
        hexPRMerged      = ud.string(forKey: "megadesk.color.pr.merged")    ?? "#5AC8FA"
        hexPRClosed      = ud.string(forKey: "megadesk.color.pr.closed")    ?? "#737373"
        repoBasePath     = ud.string(forKey: "megadesk.repoBasePath")       ?? "~/Repositories"
        cloneBasePath    = ud.string(forKey: "megadesk.cloneBasePath")      ?? "~/.megadesk/repos"
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(forgottenMinutes,    forKey: "megadesk.forgottenMinutes")
        ud.set(sortOrder.rawValue,  forKey: "megadesk.sortOrder")
        ud.set(idleOpacity,         forKey: "megadesk.idleOpacity")
        ud.set(hexWorking,          forKey: "megadesk.color.working")
        ud.set(hexConfirmation,     forKey: "megadesk.color.confirmation")
        ud.set(hexWaiting,          forKey: "megadesk.color.waiting")
        ud.set(hexForgotten,        forKey: "megadesk.color.forgotten")
        ud.set(hexPRPassing,        forKey: "megadesk.color.pr.passing")
        ud.set(hexPRPending,        forKey: "megadesk.color.pr.pending")
        ud.set(hexPRFailing,        forKey: "megadesk.color.pr.failing")
        ud.set(hexPRMerged,         forKey: "megadesk.color.pr.merged")
        ud.set(hexPRClosed,         forKey: "megadesk.color.pr.closed")
        ud.set(repoBasePath,        forKey: "megadesk.repoBasePath")
        ud.set(cloneBasePath,       forKey: "megadesk.cloneBasePath")
    }

    func resetToDefaults() {
        forgottenMinutes = 5
        sortOrder        = .byState
        idleOpacity      = 1.0
        hexWorking       = "#34C759"
        hexConfirmation  = "#5AC8FA"
        hexWaiting       = "#FF9500"
        hexForgotten     = "#737373"
        hexPRPassing     = "#34C759"
        hexPRPending     = "#FF9500"
        hexPRFailing     = "#FF3B30"
        hexPRMerged      = "#5AC8FA"
        hexPRClosed      = "#737373"
        repoBasePath     = "~/Repositories"
        cloneBasePath    = "~/.megadesk/repos"
        save()
    }
}

// MARK: - Color ↔ Hex

extension Color {
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("#") { str = String(str.dropFirst()) }
        guard str.count == 6, let value = UInt64(str, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8)  & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#808080" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent   * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent  * 255).rounded()))
    }
}
