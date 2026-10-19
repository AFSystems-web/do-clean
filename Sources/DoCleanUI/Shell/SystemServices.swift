import Foundation
import ServiceManagement
import UserNotifications
import DoCleanCore

/// Launch at login, via SMAppService. Works only from the bundled .app.
@MainActor
enum LaunchAtLogin {
    /// UserNotifications and SMAppService crash or fail outside an app bundle (swift run, tests).
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static var isEnabled: Bool {
        guard isBundled else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns an error text for the UI, nil on success.
    static func set(_ on: Bool) -> String? {
        guard isBundled else { return "Работает только в собранном приложении (build/do clean.app)" }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// «Пора почистить» reminder: one pending local notification at `ReminderScheduler.nextReminder`.
@MainActor
enum Reminders {
    static let id = "doclean.reminder"

    static func reschedule(settings: AppSettings, history: History, rules: [Rule]) {
        guard LaunchAtLogin.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let last = HistoryStats(history: history, rules: rules).lastCleanup
        guard let date = ReminderScheduler().nextReminder(settings: settings, lastCleanup: last) else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Пора почистить Mac"
            content.body = "Прошло \(settings.reminderDays) дн. с последней чистки. Быстрый скан займёт пару секунд."
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(identifier: id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            center.add(request)
        }
    }
}
