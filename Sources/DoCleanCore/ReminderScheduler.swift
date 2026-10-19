import Foundation

/// When should the "time to clean" reminder fire? Logic only; the app schedules the notification.
public struct ReminderScheduler: Sendable {
    public var calendar: Calendar
    /// Hour of day the reminder fires.
    public var hour: Int

    public init(calendar: Calendar = .current, hour: Int = 10) { self.calendar = calendar; self.hour = hour }

    /// The moment the reminder became (or becomes) due, before any "overdue" rolling. nil = reminders off.
    /// Base = last cleanup (else first launch) + `reminderDays`, never earlier than the last reminder + `reminderDays`, at `hour`:00.
    public func dueDate(settings: AppSettings, lastCleanup: Date?, now: Date = Date()) -> Date? {
        let days = settings.reminderDays
        guard days > 0 else { return nil }
        let anchor = lastCleanup ?? settings.firstLaunchAt ?? now
        var due = calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
        if let last = settings.lastReminderAt, let again = calendar.date(byAdding: .day, value: days, to: last), again > due { due = again }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: due) ?? due
    }

    /// Is a reminder due right now (the app should show it and set `lastReminderAt`)?
    public func isDue(settings: AppSettings, lastCleanup: Date?, now: Date = Date()) -> Bool {
        guard let due = dueDate(settings: settings, lastCleanup: lastCleanup, now: now) else { return false }
        return due <= now
    }

    /// When to schedule the next notification: the due date, or, if it has passed, the next `hour`:00 from now.
    public func nextReminder(settings: AppSettings, lastCleanup: Date?, now: Date = Date()) -> Date? {
        guard let due = dueDate(settings: settings, lastCleanup: lastCleanup, now: now) else { return nil }
        if due > now { return due }
        var next = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if next <= now { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
        return next
    }
}
