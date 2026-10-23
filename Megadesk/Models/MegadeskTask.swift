import Foundation
import SwiftUI

/// How urgent a task is. Priority colors the row but never reorders the list:
/// the order is manual and dragged by hand.
enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case none, low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:   return "None"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    var color: Color {
        switch self {
        case .none:   return Color(white: 0.45)
        case .low:    return .blue
        case .medium: return .orange
        case .high:   return .red
        }
    }
}

/// When a task nags on its own. Either a single moment, or a fixed cadence
/// counted from a starting point ("from now" is just today's date as the start).
enum TaskReminder: Codable, Equatable, Hashable {
    case at(date: Date)
    case every(minutes: Int, from: Date)

    var label: String {
        switch self {
        case .at:
            return "At a time"
        case .every(let m, _) where m >= 60 && m % 60 == 0:
            return "Every \(m / 60) hour\(m / 60 == 1 ? "" : "s")"
        case .every(let m, _):
            return "Every \(m) minute\(m == 1 ? "" : "s")"
        }
    }
}

/// How often the task itself comes back. A task whose recurrence isn't `.never`
/// is the head of a series: once the occurrence passes and no instance of the
/// series is still open, a fresh instance is generated from it.
enum TaskRecurrence: Codable, Equatable, Hashable {
    case never
    case daily
    case weekdays
    case weekly(weekday: Int)   // 1=Sun...7=Sat
    case monthly(day: Int)      // 1-31

    var label: String {
        switch self {
        case .never:    return "Never"
        case .daily:    return "Daily"
        case .weekdays: return "Weekdays (Mon-Fri)"
        case .weekly:   return "Weekly"
        case .monthly:  return "Monthly"
        }
    }

    var repeats: Bool {
        if case .never = self { return false }
        return true
    }
}

struct MegadeskTask: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var notes: String
    var priority: TaskPriority
    var tags: [String]
    /// Optional deadline (date + time). Drives the overdue/today counters and
    /// the overdue group, never the order.
    var dueDate: Date?
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    /// Position in the hand-dragged list. Lower comes first.
    var sortIndex: Int
    /// True while the task is being filled in for the first time and hasn't
    /// been confirmed. A draft stays out of the list and never reminds, so an
    /// abandoned one can't turn into a task nobody meant to create.
    var isDraft: Bool?

    // MARK: Session link
    /// `terminalSessionId` of the linked session, i.e. the same key the store
    /// uses for custom names — one terminal tab, one key.
    var linkedSessionKey: String?
    /// Name the session had when it was linked, so a dead link can still say
    /// what it pointed at.
    var linkedSessionLabel: String?
    /// Working directory of the linked session. A session that comes back with
    /// a new terminal id but the same cwd is the same work, so the link is
    /// rebound to it instead of staying dead.
    var linkedSessionCwd: String?

    // MARK: Reminder
    var reminder: TaskReminder?
    /// When the reminder last went off. Kept apart from `reminderSnoozedUntil`,
    /// which is an explicit "not now": this one is what tells a one-shot
    /// reminder it is done.
    var reminderLastFiredAt: Date?
    var reminderSnoozedUntil: Date?

    // MARK: Recurrence
    var recurrence: TaskRecurrence
    var recurrenceHour: Int
    var recurrenceMinute: Int
    /// Occurrence this series last consumed. The next one is computed from it,
    /// so a stretch with the module off collapses into a single catch-up
    /// instead of a burst of backdated ones.
    var lastSpawnedAt: Date?
    /// Every instance generated from the same recurring task shares this id.
    /// A task that has never recurred is its own series.
    var seriesId: UUID

    init(id: UUID = UUID(),
         title: String = "",
         notes: String = "",
         priority: TaskPriority = .none,
         tags: [String] = [],
         dueDate: Date? = nil,
         isCompleted: Bool = false,
         completedAt: Date? = nil,
         createdAt: Date = Date(),
         sortIndex: Int = 0,
         isDraft: Bool? = nil,
         linkedSessionKey: String? = nil,
         linkedSessionLabel: String? = nil,
         linkedSessionCwd: String? = nil,
         reminder: TaskReminder? = nil,
         reminderLastFiredAt: Date? = nil,
         reminderSnoozedUntil: Date? = nil,
         recurrence: TaskRecurrence = .never,
         recurrenceHour: Int = 9,
         recurrenceMinute: Int = 0,
         lastSpawnedAt: Date? = nil,
         seriesId: UUID? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.priority = priority
        self.tags = tags
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.isDraft = isDraft
        self.linkedSessionKey = linkedSessionKey
        self.linkedSessionLabel = linkedSessionLabel
        self.linkedSessionCwd = linkedSessionCwd
        self.reminder = reminder
        self.reminderLastFiredAt = reminderLastFiredAt
        self.reminderSnoozedUntil = reminderSnoozedUntil
        self.recurrence = recurrence
        self.recurrenceHour = recurrenceHour
        self.recurrenceMinute = recurrenceMinute
        self.lastSpawnedAt = lastSpawnedAt
        self.seriesId = seriesId ?? id
    }

    // MARK: - Derived

    /// In the active list: confirmed and not done.
    var isActive: Bool { isDraft != true && !isCompleted }

    func isOverdue(now: Date = Date()) -> Bool {
        guard isActive, let due = dueDate else { return false }
        return due < now
    }

    func isDueToday(now: Date = Date()) -> Bool {
        guard isActive, let due = dueDate, due >= now else { return false }
        return Calendar.current.isDateInToday(due)
    }

    // MARK: - Reminder scheduling

    /// When the reminder should next go off, or nil if it has nothing left to
    /// say. A pending snooze outranks the schedule: it's an explicit "in N
    /// minutes", whatever the reminder would otherwise do.
    func nextReminderDate(after referenceDate: Date = Date()) -> Date? {
        guard isActive, let reminder else { return nil }

        if let snoozedUntil = reminderSnoozedUntil, snoozedUntil > referenceDate {
            return snoozedUntil
        }

        switch reminder {
        case .at(let date):
            if reminderLastFiredAt != nil { return nil }
            return date

        case .every(let minutes, let from):
            guard minutes > 0 else { return nil }
            let intervalSeconds = TimeInterval(minutes * 60)
            if let last = reminderLastFiredAt {
                let next = last.addingTimeInterval(intervalSeconds)
                // A gap (app closed, module off) collapses into one round, not
                // one per interval that went by.
                return next <= referenceDate ? referenceDate : next
            }
            return from <= referenceDate ? referenceDate : from
        }
    }

    // MARK: - Recurrence scheduling

    /// First occurrence strictly after `referenceDate`, at the task's own
    /// time of day.
    func nextOccurrence(after referenceDate: Date) -> Date? {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.hour = recurrenceHour
        comps.minute = recurrenceMinute
        comps.second = 0

        switch recurrence {
        case .never:
            return nil

        case .daily:
            return cal.nextDate(after: referenceDate, matching: comps,
                                matchingPolicy: .nextTime, direction: .forward)

        case .weekdays:
            var candidate = referenceDate
            for _ in 0..<8 {
                guard let next = cal.nextDate(after: candidate, matching: comps,
                                              matchingPolicy: .nextTime, direction: .forward) else { return nil }
                let weekday = cal.component(.weekday, from: next)
                if weekday >= 2 && weekday <= 6 { return next }
                candidate = next
            }
            return nil

        case .weekly(let weekday):
            comps.weekday = weekday
            return cal.nextDate(after: referenceDate, matching: comps,
                                matchingPolicy: .nextTime, direction: .forward)

        case .monthly(let day):
            comps.day = day
            return cal.nextDate(after: referenceDate, matching: comps,
                                matchingPolicy: .nextTime, direction: .forward)
        }
    }
}
