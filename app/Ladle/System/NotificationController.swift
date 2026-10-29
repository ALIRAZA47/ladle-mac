import Foundation
import LadleKit
import UserNotifications

/// "Download complete" notifications with Open and Show in Finder.
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let categoryID = "me.alirazakhan.Ladle.finished"
    static let openAction = "open"
    static let revealAction = "reveal"

    /// Called on the main thread with the download's id.
    var onOpen: ((UUID) -> Void)?
    var onReveal: ((UUID) -> Void)?

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func start() {
        center.delegate = self
        let open = UNNotificationAction(identifier: NotificationController.openAction, title: "Open", options: [.foreground])
        let reveal = UNNotificationAction(identifier: NotificationController.revealAction, title: "Show in Finder", options: [.foreground])
        let category = UNNotificationCategory(identifier: NotificationController.categoryID, actions: [open, reveal], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postFinished(_ item: DownloadItem, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.subtitle = item.fileName
        var parts: [String] = []
        let size = item.totalBytes ?? item.receivedBytes
        if item.activeDuration >= 1 {
            parts.append("\(Format.size(size)) in \(Format.duration(item.activeDuration))")
        } else {
            parts.append(Format.size(size))
        }
        switch item.checksumState {
        case .verified?: parts.append("checksum verified")
        case .mismatch?: parts.append("checksum doesn’t match")
        default: break
        }
        content.body = parts.joined(separator: " · ")
        content.categoryIdentifier = NotificationController.categoryID
        content.userInfo = ["id": item.id.uuidString]
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if let raw = info["id"] as? String, let id = UUID(uuidString: raw) {
            DispatchQueue.main.async {
                if action == NotificationController.revealAction {
                    self.onReveal?(id)
                } else if action == NotificationController.openAction || action == UNNotificationDefaultActionIdentifier {
                    self.onOpen?(id)
                }
            }
        }
        completionHandler()
    }
}
