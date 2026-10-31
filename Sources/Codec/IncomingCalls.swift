import AppKit
import UserNotifications

/// Posts "incoming call" notifications when a background channel rings its bell.
@MainActor
final class IncomingCalls: NSObject, UNUserNotificationCenterDelegate {
    static let shared = IncomingCalls()

    /// Called with the frequency of the channel whose notification was clicked.
    var onAnswer: ((String) -> Void)?

    /// UNUserNotificationCenter only works from a real .app bundle (not `swift run`).
    private var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var requestedAuthorization = false

    func activate() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func ring(frequency: String, label: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = "Incoming call · \(frequency)"
        content.body = label.isEmpty ? "A channel is trying to reach you." : "\(label) is trying to reach you."
        content.threadIdentifier = frequency
        content.userInfo = ["frequency": frequency]
        let request = UNNotificationRequest(identifier: "call-\(frequency)", content: content, trigger: nil)
        center.add(request)
    }

    func hangUp(frequency: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call-\(frequency)"])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let frequency = response.notification.request.content.userInfo["frequency"] as? String
        await MainActor.run {
            if let frequency { self.onAnswer?(frequency) }
        }
    }
}
