import Foundation
import UserNotifications
import UIKit

/// Presents OS notifications for socket pushes received while the app is in
/// the background. The web client covers this with Web Push (VAPID); on iOS
/// the socket stays alive in background via the audio background mode, so we
/// surface incoming `social/notify` and `messenger/new_message` frames as
/// local notifications — no APNs infrastructure required.
final class PushNotificationsService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationsService()

    private var isRegistered = false

    private override init() {
        super.init()
    }

    /// Ask once; safe to call repeatedly.
    func requestPermissionIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[Push] permission error: \(error.localizedDescription)")
            } else {
                print("[Push] permission granted: \(granted)")
            }
        }
    }

    /// Only presents when the app is not in the foreground — while active the
    /// in-app banner already handles it (same split as the web client).
    func presentIfBackgrounded(title: String, body: String, identifier: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        guard !body.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Push] present error: \(error.localizedDescription)")
            }
        }
    }

    // Show banners even if the app is foregrounded right at the moment of
    // delivery (rare race between state check and presentation).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
