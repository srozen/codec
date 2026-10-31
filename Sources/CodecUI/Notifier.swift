import AppKit
import UserNotifications

/// Posts notifications for panes that need you while you're looking elsewhere.
@MainActor
final class Notifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    /// Called with the ID of the pane whose notification was clicked.
    var onOpen: ((String) -> Void)?
    private var requestedAuthorization = false

    /// UNUserNotificationCenter only works from a real .app bundle (not `swift run` or tests).
    private var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func activate() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(id: String, title: String, body: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert]) { _, error in
                if let error { Log.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = id
        content.userInfo = ["pane": id]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func clear(id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["pane"] as? String else { return }
        await MainActor.run { self.onOpen?(id) }
    }
}
