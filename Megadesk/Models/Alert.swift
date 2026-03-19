import Foundation

struct MegadeskAlert: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var date: Date
    var recurrence: Recurrence
    var isEnabled: Bool
    var isCompleted: Bool?
    var lastFiredAt: Date?

    // Optional constraints for interval recurrence: which days and what time window.
    var activeDays: Set<Int>?       // nil = every day, otherwise subset of 1(Sun)..7(Sat)
    var activeStartHour: Int?       // e.g. 9
    var activeStartMinute: Int?     // e.g. 0
    var activeEndHour: Int?         // e.g. 18
    var activeEndMinute: Int?       // e.g. 0

    // Per-alert notification overrides (nil = use global default from AppSettings)
    var overrideShowToast: Bool?
    var overrideShowWidget: Bool?
    var overrideShowNotification: Bool?
    var overrideShowBadge: Bool?
    var overridePlaySound: Bool?

    init(id: UUID = UUID(), title: String = "New Alert", date: Date = Date().addingTimeInterval(300),
         recurrence: Recurrence = .once, isEnabled: Bool = true, lastFiredAt: Date? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.recurrence = recurrence
        self.isEnabled = isEnabled
        self.lastFiredAt = lastFiredAt
    }

    // Resolved notification settings (per-alert override or global default)
    var effectiveShowToast: Bool { overrideShowToast ?? AppSettings.shared.alertShowToast }
    var effectiveShowWidget: Bool { overrideShowWidget ?? AppSettings.shared.alertShowWidget }
    var effectiveShowNotification: Bool { overrideShowNotification ?? AppSettings.shared.alertShowNotification }
    var effectiveShowBadge: Bool { overrideShowBadge ?? AppSettings.shared.alertShowBadge }
    var effectivePlaySound: Bool { overridePlaySound ?? AppSettings.shared.alertPlaySound }

    /// Whether the given date falls within the active days + time range constraints.
    /// Returns true if no constraints are set.
    func isWithinActiveWindow(_ date: Date) -> Bool {
        let cal = Calendar.current
        if let days = activeDays, !days.isEmpty {
            let weekday = cal.component(.weekday, from: date)
            if !days.contains(weekday) { return false }
        }
        if let sh = activeStartHour, let sm = activeStartMinute,
           let eh = activeEndHour, let em = activeEndMinute {
            let startMin = sh * 60 + sm
            let endMin = eh * 60 + em
            guard startMin != endMin else { return true } // same = no constraint
            let hour = cal.component(.hour, from: date)
            let minute = cal.component(.minute, from: date)
            let nowMin = hour * 60 + minute
            if startMin < endMin {
                // e.g. 09:00 – 18:00
                if nowMin < startMin || nowMin >= endMin { return false }
            } else {
                // wraps midnight, e.g. 22:00 – 06:00
                if nowMin < startMin && nowMin >= endMin { return false }
            }
        }
        return true
    }
}

enum Recurrence: Codable, Equatable, Hashable {
    case once
    case daily
    case weekdays
    case weekly(weekday: Int)    // 1=Sun...7=Sat
    case monthly(day: Int)       // 1-31
    case interval(minutes: Int)  // every N minutes

    var label: String {
        switch self {
        case .once: return "Once"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays (Mon-Fri)"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .interval(let m) where m >= 60 && m % 60 == 0:
            return "Every \(m / 60) hour\(m / 60 == 1 ? "" : "s")"
        case .interval(let m):
            return "Every \(m) minute\(m == 1 ? "" : "s")"
        }
    }
}

// MARK: - Next Fire Date

extension MegadeskAlert {
    func nextFireDate(after referenceDate: Date = Date()) -> Date? {
        let cal = Calendar.current

        switch recurrence {
        case .once:
            if lastFiredAt != nil { return nil }
            return Self.stripSeconds(from: date)

        case .daily:
            let timeComponents = cal.dateComponents([.hour, .minute], from: date)
            guard var next = cal.nextDate(after: referenceDate, matching: timeComponents,
                                          matchingPolicy: .nextTime, direction: .forward) else { return nil }
            // If we haven't fired yet today and the time hasn't passed, use today
            let todayAtTime = cal.date(bySettingHour: timeComponents.hour ?? 0,
                                       minute: timeComponents.minute ?? 0,
                                       second: 0, of: referenceDate)
            if let today = todayAtTime, today >= referenceDate,
               (lastFiredAt == nil || !cal.isDate(lastFiredAt!, inSameDayAs: referenceDate)) {
                next = today
            }
            return next

        case .weekdays:
            let timeComponents = cal.dateComponents([.hour, .minute], from: date)
            var candidate = referenceDate
            for _ in 0..<8 {
                let weekday = cal.component(.weekday, from: candidate)
                let isWeekday = weekday >= 2 && weekday <= 6
                if isWeekday {
                    if let atTime = cal.date(bySettingHour: timeComponents.hour ?? 0,
                                             minute: timeComponents.minute ?? 0,
                                             second: 0, of: candidate) {
                        if atTime >= referenceDate {
                            if lastFiredAt == nil || !cal.isDate(lastFiredAt!, inSameDayAs: candidate) {
                                return atTime
                            }
                        }
                    }
                }
                candidate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: candidate))!
            }
            return nil

        case .weekly(let weekday):
            let timeComponents = cal.dateComponents([.hour, .minute], from: date)
            var components = timeComponents
            components.second = 0
            components.weekday = weekday
            guard let next = cal.nextDate(after: referenceDate, matching: components,
                                          matchingPolicy: .nextTime, direction: .forward) else { return nil }
            // Check if today matches
            if cal.component(.weekday, from: referenceDate) == weekday {
                if let today = cal.date(bySettingHour: timeComponents.hour ?? 0,
                                        minute: timeComponents.minute ?? 0,
                                        second: 0, of: referenceDate),
                   today >= referenceDate,
                   (lastFiredAt == nil || !cal.isDate(lastFiredAt!, inSameDayAs: referenceDate)) {
                    return today
                }
            }
            return next

        case .monthly(let day):
            let timeComponents = cal.dateComponents([.hour, .minute], from: date)
            var components = timeComponents
            components.second = 0
            components.day = day
            guard let next = cal.nextDate(after: referenceDate, matching: components,
                                          matchingPolicy: .nextTime, direction: .forward) else { return nil }
            if cal.component(.day, from: referenceDate) == day {
                if let today = cal.date(bySettingHour: timeComponents.hour ?? 0,
                                        minute: timeComponents.minute ?? 0,
                                        second: 0, of: referenceDate),
                   today >= referenceDate,
                   (lastFiredAt == nil || !cal.isDate(lastFiredAt!, inSameDayAs: referenceDate)) {
                    return today
                }
            }
            return next

        case .interval(let minutes):
            guard minutes > 0 else { return nil }
            let intervalSeconds = TimeInterval(minutes * 60)
            let raw: Date
            if let last = lastFiredAt {
                let next = last.addingTimeInterval(intervalSeconds)
                raw = next <= referenceDate ? referenceDate : next
            } else {
                raw = date <= referenceDate ? referenceDate : date
            }
            let candidate = Self.stripSeconds(from: raw)
            // If no day/time constraints, return as-is
            if activeDays == nil && activeStartHour == nil { return candidate }
            // Check if candidate falls within the active window
            if isWithinActiveWindow(candidate) { return candidate }
            // Skip forward to the next valid window start
            return nextActiveWindowStart(after: candidate)
        }
    }

    /// Truncates the seconds component to :00.
    private static func stripSeconds(from date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return cal.date(from: comps) ?? date
    }

    /// Finds the start of the next active window (day + time) after a given date.
    /// Scans up to 8 days ahead.
    private func nextActiveWindowStart(after date: Date) -> Date? {
        let cal = Calendar.current
        let startHour = activeStartHour ?? 0
        let startMinute = activeStartMinute ?? 0

        // Try today first (at the start time, if it hasn't passed), then the next 7 days
        for dayOffset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: date)) else { continue }
            guard let candidate = cal.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day) else { continue }
            // Must be in the future
            guard candidate > date else { continue }
            // Must be on an active day
            if let days = activeDays, !days.isEmpty {
                let weekday = cal.component(.weekday, from: candidate)
                if !days.contains(weekday) { continue }
            }
            return candidate
        }
        return nil
    }
}
