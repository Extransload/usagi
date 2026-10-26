import AppKit
import UserNotifications

/// Posts the limit alerts LimitAlerts decides on, and remembers what each limit last showed (Preferences.alertState).
/// Asks for permission when the first alert is due, not at launch.
@MainActor final class LimitNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Clicking an alert opens the account cards.
    var opened: () -> Void = {}

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func status(_ done: @escaping @MainActor (UNAuthorizationStatus) -> Void) {
        Task { done(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus) }
    }

    func requestAuthorization(then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task { done((try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false) }
    }

    /// Runs once per new snapshot.
    func check(_ snapshot: [String: Any], preferences: Preferences) {
        let options = LimitAlerts.Options(thresholds: preferences.thresholds, usedUp: preferences.notifyUsedUp,
                                          reset: preferences.notifyReset)
        let now = Date()
        var state = preferences.alertState, alerts: [(key: String, alert: LimitAlerts.Alert)] = []
        for (key, reading) in LimitAlerts.readings(snapshot) {
            let result = LimitAlerts.evaluate(state[key], reading, options: options, now: now)
            state[key] = result.record
            if let alert = result.alert { alerts.append((key, alert)) }
        }
        preferences.alertState = LimitAlerts.prune(state, now: now)
        guard !alerts.isEmpty else { return }
        status { [weak self] status in
            switch status {
            case .authorized, .provisional: alerts.forEach { self?.post($0.alert, key: $0.key) }
            case .notDetermined:
                self?.requestAuthorization { granted in if granted { alerts.forEach { self?.post($0.alert, key: $0.key) } } }
            default: break
            }
        }
    }

    /// One notification per limit: a newer alert for the same limit replaces the older one.
    private func post(_ alert: LimitAlerts.Alert, key: String) {
        let text = LimitAlerts.text(alert, key: key)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.opened() }
        completionHandler()
    }
}
