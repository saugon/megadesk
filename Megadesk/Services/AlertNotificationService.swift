import Foundation
import UserNotifications

final class AlertNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertNotificationService()

    private let categoryIdentifier = "MEGADESK_ALERT"
    private var authorized = false

    private override init() {
        super.init()
    }

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let mins = AppSettings.shared.snoozeMinutes
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze \(mins) min", options: [])
        let dismiss = UNNotificationAction(identifier: "DISMISS", title: "Dismiss", options: .destructive)
        let category = UNNotificationCategory(identifier: categoryIdentifier,
                                              actions: [snooze, dismiss],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                self.authorized = granted
            }
        }
    }

    func postNotification(for alert: MegadeskAlert) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Megadesk Alert"
            content.body = alert.title
            content.sound = .default
            content.categoryIdentifier = self.categoryIdentifier
            content.userInfo = ["alertId": alert.id.uuidString]

            let request = UNNotificationRequest(identifier: alert.id.uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    // Show notification banner even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let alertIdString = response.notification.request.content.userInfo["alertId"] as? String ?? ""
        let alertId = UUID(uuidString: alertIdString)

        switch response.actionIdentifier {
        case "SNOOZE":
            if let id = alertId {
                let mins = AppSettings.shared.snoozeMinutes
                NotificationCenter.default.post(name: .megadeskSnoozeAlert, object: nil,
                                                userInfo: ["alertId": id, "minutes": mins])
            }
        case "DISMISS", UNNotificationDismissActionIdentifier:
            if let id = alertId {
                NotificationCenter.default.post(name: .megadeskDismissAlert, object: nil,
                                                userInfo: ["alertId": id])
            }
        default:
            break
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let megadeskSnoozeAlert = Notification.Name("megadeskSnoozeAlert")
    static let megadeskDismissAlert = Notification.Name("megadeskDismissAlert")
    static let megadeskAlertFired = Notification.Name("megadeskAlertFired")
}
