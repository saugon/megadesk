import AppKit
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

enum ToastPosition: String, CaseIterable {
    case topRight  = "topRight"
    case topCenter = "topCenter"
    case center    = "center"

    var label: String {
        switch self {
        case .topRight:  return "Top Right"
        case .topCenter: return "Top Center"
        case .center:    return "Center"
        }
    }
}

/// Style of the collapsed widget edge tab (⌘⇧L).
enum PeekTabStyle: String, CaseIterable {
    case compact      // thin bar; a click anywhere restores the widget
    case interactive  // taller; clickable per-session/PR/alert slots + expand button

    var label: String {
        switch self {
        case .compact:     return "Compact"
        case .interactive: return "Interactive"
        }
    }
}

/// Modifier that, while held, suspends the widget/companion "dodge the mouse"
/// behavior so the panel can be reached and clicked.
enum DodgeModifier: String, CaseIterable {
    case command, option, control, shift, function

    var label: String {
        switch self {
        case .command:  return "Command (⌘)"
        case .option:   return "Option (⌥)"
        case .control:  return "Control (⌃)"
        case .shift:    return "Shift (⇧)"
        case .function: return "Function (fn)"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command:  return .command
        case .option:   return .option
        case .control:  return .control
        case .shift:    return .shift
        case .function: return .function
        }
    }
}

/// Whether the dodge modifier suspends dodging while held, or is what enables
/// it in the first place.
enum DodgeTriggerMode: String, CaseIterable {
    case dodgeUnlessHeld    // dodge by default; hold the key to keep it in place
    case dodgeOnlyWhenHeld  // stay put by default; only dodge while the key is held

    var label: String {
        switch self {
        case .dodgeUnlessHeld:   return "Keeps it in place"
        case .dodgeOnlyWhenHeld: return "Makes it dodge"
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
    var cardFontSize: Double  // session card name size; status text is cardFontSize - 2
    var showSpinnerVerb: Bool
    var spinnerVerbAnimatedColor: Bool
    /// Whether the ⌘⇧L global shortcut that collapses the widget to an edge
    /// tab is active. When off, the combo is released for other apps.
    var peekShortcutEnabled: Bool
    /// Whether session cards show the Claude Code permission-mode badge under
    /// the provider icon.
    var showPermissionMode: Bool
    /// Style of the collapsed widget edge tab (⌘⇧L).
    var peekTabStyle: PeekTabStyle
    /// Height (pt) of each slot in the interactive collapsed tab.
    var peekSlotHeight: Double
    /// When on, the widget and floating companion slide to the nearest screen
    /// edge (leaving a sliver) when the mouse approaches, and return once it
    /// leaves. Holding `edgeDodgeBypassModifier` suspends it.
    var edgeDodgeEnabled: Bool
    /// Modifier used to control dodging (role set by `edgeDodgeTriggerMode`).
    var edgeDodgeBypassModifier: DodgeModifier
    /// Whether holding the modifier keeps the panels in place, or is what makes
    /// them dodge in the first place.
    var edgeDodgeTriggerMode: DodgeTriggerMode
    /// Sliver (pt) of the panel left visible when it tucks against the edge.
    var edgeDodgeReveal: Double
    /// When on, hovering the tucked sliver enlarges it to `edgeDodgeHoverReveal`.
    var edgeDodgeHoverPeekEnabled: Bool
    /// Sliver (pt) shown while the cursor hovers the tucked panel.
    var edgeDodgeHoverReveal: Double

    // MARK: - Session state colors (stored as hex strings)
    var hexWorking:      String
    var hexConfirmation: String
    var hexWaiting:      String
    var hexForgotten:    String

    // MARK: - Alert color
    var hexAlert: String

    // MARK: - PR state colors
    var hexPRPassing: String
    var hexPRPending: String
    var hexPRFailing: String
    var hexPRMerged:  String
    var hexPRClosed:  String

    // MARK: - Alert display settings
    var alertShowToast: Bool
    var alertShowWidget: Bool
    var alertShowNotification: Bool
    var alertShowBadge: Bool
    var alertPlaySound: Bool
    var toastPosition: ToastPosition
    var snoozeMinutes: Int

    // MARK: - Companion
    var companionEnabled: Bool
    var companionMode: CompanionMode
    var companionWaitingThresholdMinutes: Int
    var companionStuckWorkingThresholdMinutes: Int
    var companionIdleThresholdMinutes: Int
    var hexCompanionSubject: String
    var colorCompanionSubject: Color { Color(hex: hexCompanionSubject) ?? .orange }
    var hexCompanionPet: String
    var hexCompanionBackground: String
    var colorCompanionPet: Color { Color(hex: hexCompanionPet) ?? .white }
    var colorCompanionBackground: Color { Color(hex: hexCompanionBackground) ?? Color(white: 0.1) }
    var companionFontSize: Double
    var companionHorizontalPadding: Double
    /// ID of the selected pet (matches a JSON in `Megadesk/Pets/`). The
    /// pet's JSON also drives its display name — there's no separate name
    /// override setting.
    var companionPetId: String
    var companionShowName: Bool
    var companionNameFontSize: Double
    var companionNameTopPadding: Double    // between ghost and name
    var companionNameBottomPadding: Double // between name and container edge
    /// Shows a live segmented bar summarizing how many sessions are in each
    /// state at the bottom of the floating companion panel. Only rendered in
    /// the standalone panel — inline in the widget it would duplicate the cards.
    var companionShowStateSummary: Bool
    var companionStateSummaryOrientation: CompanionSummaryOrientation
    var companionStateSummarySide: CompanionSummarySide

    // MARK: - Context Save
    var contextNote: String?

    // MARK: - Computed Color accessors
    var colorWorking:      Color { Color(hex: hexWorking)      ?? .green }
    var colorConfirmation: Color { Color(hex: hexConfirmation) ?? .cyan  }
    var colorWaiting:      Color { Color(hex: hexWaiting)      ?? .orange }
    var colorForgotten:    Color { Color(hex: hexForgotten)    ?? Color(white: 0.45) }

    var colorAlert: Color { Color(hex: hexAlert) ?? .orange }

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
        cardFontSize = ud.object(forKey: "megadesk.cardFontSize") as? Double ?? 13
        showSpinnerVerb = ud.object(forKey: "megadesk.showSpinnerVerb") as? Bool ?? false
        spinnerVerbAnimatedColor = ud.object(forKey: "megadesk.spinnerVerbAnimatedColor") as? Bool ?? false
        peekShortcutEnabled = ud.object(forKey: "megadesk.peekShortcutEnabled") as? Bool ?? true
        showPermissionMode = ud.object(forKey: "megadesk.showPermissionMode") as? Bool ?? true
        peekTabStyle = PeekTabStyle(rawValue: ud.string(forKey: "megadesk.peekTabStyle") ?? "") ?? .compact
        peekSlotHeight = ud.object(forKey: "megadesk.peekSlotHeight") as? Double ?? 16
        edgeDodgeEnabled = ud.object(forKey: "megadesk.edgeDodgeEnabled") as? Bool ?? false
        edgeDodgeBypassModifier = DodgeModifier(rawValue: ud.string(forKey: "megadesk.edgeDodgeBypassModifier") ?? "") ?? .command
        edgeDodgeTriggerMode = DodgeTriggerMode(rawValue: ud.string(forKey: "megadesk.edgeDodgeTriggerMode") ?? "") ?? .dodgeUnlessHeld
        edgeDodgeReveal = ud.object(forKey: "megadesk.edgeDodgeReveal") as? Double ?? 26
        edgeDodgeHoverPeekEnabled = ud.object(forKey: "megadesk.edgeDodgeHoverPeekEnabled") as? Bool ?? true
        edgeDodgeHoverReveal = ud.object(forKey: "megadesk.edgeDodgeHoverReveal") as? Double ?? 70
        hexWorking       = ud.string(forKey: "megadesk.color.working")      ?? "#34C759"
        hexConfirmation  = ud.string(forKey: "megadesk.color.confirmation") ?? "#5AC8FA"
        hexWaiting       = ud.string(forKey: "megadesk.color.waiting")      ?? "#FF9500"
        hexForgotten     = ud.string(forKey: "megadesk.color.forgotten")    ?? "#737373"
        hexAlert         = ud.string(forKey: "megadesk.color.alert")        ?? "#FF9500"
        hexPRPassing     = ud.string(forKey: "megadesk.color.pr.passing")   ?? "#34C759"
        hexPRPending     = ud.string(forKey: "megadesk.color.pr.pending")   ?? "#FF9500"
        hexPRFailing     = ud.string(forKey: "megadesk.color.pr.failing")   ?? "#FF3B30"
        hexPRMerged      = ud.string(forKey: "megadesk.color.pr.merged")    ?? "#5AC8FA"
        hexPRClosed      = ud.string(forKey: "megadesk.color.pr.closed")    ?? "#737373"
        alertShowToast        = ud.object(forKey: "megadesk.alert.showToast") as? Bool ?? true
        alertShowWidget       = ud.object(forKey: "megadesk.alert.showWidget") as? Bool ?? false
        alertShowNotification = ud.object(forKey: "megadesk.alert.showNotification") as? Bool ?? true
        alertShowBadge        = ud.object(forKey: "megadesk.alert.showBadge") as? Bool ?? true
        alertPlaySound        = ud.object(forKey: "megadesk.alert.playSound") as? Bool ?? true
        toastPosition         = ToastPosition(rawValue: ud.string(forKey: "megadesk.alert.toastPosition") ?? "") ?? .center
        snoozeMinutes         = ud.object(forKey: "megadesk.alert.snoozeMinutes") as? Int ?? 5
        companionEnabled      = ud.object(forKey: "megadesk.companion.enabled") as? Bool ?? false
        companionMode         = CompanionMode(rawValue: ud.string(forKey: "megadesk.companion.mode") ?? "") ?? .floating
        companionWaitingThresholdMinutes      = ud.object(forKey: "megadesk.companion.waitingThreshold") as? Int ?? 15
        companionStuckWorkingThresholdMinutes = ud.object(forKey: "megadesk.companion.stuckWorkingThreshold") as? Int ?? 30
        companionIdleThresholdMinutes         = ud.object(forKey: "megadesk.companion.idleThreshold") as? Int ?? 45
        hexCompanionSubject                   = ud.string(forKey: "megadesk.companion.color.subject") ?? "#FF9500"
        hexCompanionPet                       = ud.string(forKey: "megadesk.companion.color.pet") ?? "#FFFFFF"
        hexCompanionBackground                = ud.string(forKey: "megadesk.companion.color.background") ?? "#1A1A1A"
        companionFontSize                     = ud.object(forKey: "megadesk.companion.fontSize") as? Double ?? 16
        companionHorizontalPadding            = ud.object(forKey: "megadesk.companion.horizontalPadding") as? Double ?? 45
        companionPetId                        = ud.string(forKey: "megadesk.companion.pet") ?? CompanionPetRegistry.defaultId
        companionShowName                     = ud.object(forKey: "megadesk.companion.showName") as? Bool ?? true
        companionNameFontSize                 = ud.object(forKey: "megadesk.companion.nameFontSize") as? Double ?? 9
        companionNameTopPadding               = ud.object(forKey: "megadesk.companion.nameTopPadding") as? Double ?? 2
        companionNameBottomPadding            = ud.object(forKey: "megadesk.companion.nameBottomPadding") as? Double ?? 6
        companionShowStateSummary             = ud.object(forKey: "megadesk.companion.showStateSummary") as? Bool ?? true
        companionStateSummaryOrientation      = CompanionSummaryOrientation(rawValue: ud.string(forKey: "megadesk.companion.stateSummaryOrientation") ?? "") ?? .horizontal
        companionStateSummarySide             = CompanionSummarySide(rawValue: ud.string(forKey: "megadesk.companion.stateSummarySide") ?? "") ?? .left
        contextNote           = ud.string(forKey: "megadesk.contextNote")
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(forgottenMinutes,    forKey: "megadesk.forgottenMinutes")
        ud.set(sortOrder.rawValue,  forKey: "megadesk.sortOrder")
        ud.set(idleOpacity,         forKey: "megadesk.idleOpacity")
        ud.set(cardFontSize,        forKey: "megadesk.cardFontSize")
        ud.set(showSpinnerVerb,     forKey: "megadesk.showSpinnerVerb")
        ud.set(spinnerVerbAnimatedColor, forKey: "megadesk.spinnerVerbAnimatedColor")
        ud.set(peekShortcutEnabled, forKey: "megadesk.peekShortcutEnabled")
        ud.set(showPermissionMode, forKey: "megadesk.showPermissionMode")
        ud.set(peekTabStyle.rawValue, forKey: "megadesk.peekTabStyle")
        ud.set(peekSlotHeight, forKey: "megadesk.peekSlotHeight")
        ud.set(edgeDodgeEnabled, forKey: "megadesk.edgeDodgeEnabled")
        ud.set(edgeDodgeBypassModifier.rawValue, forKey: "megadesk.edgeDodgeBypassModifier")
        ud.set(edgeDodgeTriggerMode.rawValue, forKey: "megadesk.edgeDodgeTriggerMode")
        ud.set(edgeDodgeReveal, forKey: "megadesk.edgeDodgeReveal")
        ud.set(edgeDodgeHoverPeekEnabled, forKey: "megadesk.edgeDodgeHoverPeekEnabled")
        ud.set(edgeDodgeHoverReveal, forKey: "megadesk.edgeDodgeHoverReveal")
        ud.set(hexWorking,          forKey: "megadesk.color.working")
        ud.set(hexConfirmation,     forKey: "megadesk.color.confirmation")
        ud.set(hexWaiting,          forKey: "megadesk.color.waiting")
        ud.set(hexForgotten,        forKey: "megadesk.color.forgotten")
        ud.set(hexAlert,            forKey: "megadesk.color.alert")
        ud.set(hexPRPassing,        forKey: "megadesk.color.pr.passing")
        ud.set(hexPRPending,        forKey: "megadesk.color.pr.pending")
        ud.set(hexPRFailing,        forKey: "megadesk.color.pr.failing")
        ud.set(hexPRMerged,         forKey: "megadesk.color.pr.merged")
        ud.set(hexPRClosed,         forKey: "megadesk.color.pr.closed")
        ud.set(alertShowToast,        forKey: "megadesk.alert.showToast")
        ud.set(alertShowWidget,       forKey: "megadesk.alert.showWidget")
        ud.set(alertShowNotification, forKey: "megadesk.alert.showNotification")
        ud.set(alertShowBadge,        forKey: "megadesk.alert.showBadge")
        ud.set(alertPlaySound,        forKey: "megadesk.alert.playSound")
        ud.set(toastPosition.rawValue, forKey: "megadesk.alert.toastPosition")
        ud.set(snoozeMinutes,         forKey: "megadesk.alert.snoozeMinutes")
        ud.set(companionEnabled,      forKey: "megadesk.companion.enabled")
        ud.set(companionMode.rawValue, forKey: "megadesk.companion.mode")
        ud.set(companionWaitingThresholdMinutes,      forKey: "megadesk.companion.waitingThreshold")
        ud.set(companionStuckWorkingThresholdMinutes, forKey: "megadesk.companion.stuckWorkingThreshold")
        ud.set(companionIdleThresholdMinutes,         forKey: "megadesk.companion.idleThreshold")
        ud.set(hexCompanionSubject,                   forKey: "megadesk.companion.color.subject")
        ud.set(hexCompanionPet,                       forKey: "megadesk.companion.color.pet")
        ud.set(hexCompanionBackground,                forKey: "megadesk.companion.color.background")
        ud.set(companionFontSize,                     forKey: "megadesk.companion.fontSize")
        ud.set(companionHorizontalPadding,            forKey: "megadesk.companion.horizontalPadding")
        ud.set(companionPetId,                        forKey: "megadesk.companion.pet")
        ud.set(companionShowName,                     forKey: "megadesk.companion.showName")
        ud.set(companionNameFontSize,                 forKey: "megadesk.companion.nameFontSize")
        ud.set(companionNameTopPadding,               forKey: "megadesk.companion.nameTopPadding")
        ud.set(companionNameBottomPadding,            forKey: "megadesk.companion.nameBottomPadding")
        ud.set(companionShowStateSummary,             forKey: "megadesk.companion.showStateSummary")
        ud.set(companionStateSummaryOrientation.rawValue, forKey: "megadesk.companion.stateSummaryOrientation")
        ud.set(companionStateSummarySide.rawValue,        forKey: "megadesk.companion.stateSummarySide")
        if let note = contextNote {
            ud.set(note, forKey: "megadesk.contextNote")
        } else {
            ud.removeObject(forKey: "megadesk.contextNote")
        }
    }

    func resetToDefaults() {
        forgottenMinutes = 5
        sortOrder        = .byState
        idleOpacity      = 1.0
        cardFontSize     = 13
        showSpinnerVerb  = false
        spinnerVerbAnimatedColor = false
        peekShortcutEnabled = true
        showPermissionMode = true
        peekTabStyle = .compact
        peekSlotHeight = 16
        edgeDodgeEnabled = false
        edgeDodgeBypassModifier = .command
        edgeDodgeTriggerMode = .dodgeUnlessHeld
        edgeDodgeReveal = 26
        edgeDodgeHoverPeekEnabled = true
        edgeDodgeHoverReveal = 70
        hexWorking       = "#34C759"
        hexConfirmation  = "#5AC8FA"
        hexWaiting       = "#FF9500"
        hexForgotten     = "#737373"
        hexAlert         = "#FF9500"
        hexPRPassing     = "#34C759"
        hexPRPending     = "#FF9500"
        hexPRFailing     = "#FF3B30"
        hexPRMerged      = "#5AC8FA"
        hexPRClosed      = "#737373"
        alertShowToast        = true
        alertShowWidget       = false
        alertShowNotification = true
        alertShowBadge        = true
        alertPlaySound        = true
        toastPosition         = .center
        snoozeMinutes         = 5
        companionEnabled      = false
        companionMode         = .floating
        companionWaitingThresholdMinutes      = 15
        companionStuckWorkingThresholdMinutes = 30
        companionIdleThresholdMinutes         = 45
        hexCompanionSubject                   = "#FF9500"
        hexCompanionPet                       = "#FFFFFF"
        hexCompanionBackground                = "#1A1A1A"
        companionFontSize                     = 16
        companionHorizontalPadding            = 45
        companionPetId                        = CompanionPetRegistry.defaultId
        companionShowName                     = true
        companionNameFontSize                 = 9
        companionNameTopPadding               = 2
        companionNameBottomPadding            = 6
        companionShowStateSummary             = true
        companionStateSummaryOrientation      = .horizontal
        companionStateSummarySide             = .left
        contextNote           = nil
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
