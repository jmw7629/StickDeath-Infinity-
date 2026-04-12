// PushNotificationManager.swift
// Handles push notification permissions, APNs registration, device token storage,
// incoming notification routing, local streak reminders, and badge management

import Foundation
import UserNotifications
import UIKit
import Supabase

@MainActor
class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()

    @Published var isPermissionGranted = false
    @Published var deviceToken: String?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await checkCurrentPermission() }
    }

    // MARK: - Permission

    /// Request notification authorization and register for APNs
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { [weak self] granted, error in
            Task { @MainActor in
                self?.isPermissionGranted = granted
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                if let error {
                    print("⚠️ Push permission error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func checkCurrentPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isPermissionGranted = settings.authorizationStatus == .authorized
    }

    // MARK: - Device Token

    /// Called from AppDelegate when APNs returns a device token
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02.2hhx", $0) }.joined()
        self.deviceToken = token
        Task { await storeDeviceToken(token) }
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        print("⚠️ APNs registration failed: \(error.localizedDescription)")
    }

    /// Persist the device token to Supabase for server-side push
    private func storeDeviceToken(_ token: String) async {
        guard let userId = AuthManager.shared.session?.user.id else { return }

        struct DeviceTokenInsert: Encodable {
            let user_id: String
            let token: String
            let platform: String
            let created_at: String
        }

        let record = DeviceTokenInsert(
            user_id: userId.uuidString,
            token: token,
            platform: "ios",
            created_at: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try await supabase
                .from("device_tokens")
                .upsert(record, onConflict: "user_id,platform")
                .execute()
        } catch {
            print("⚠️ Failed to store device token: \(error.localizedDescription)")
        }
    }

    // MARK: - Incoming Notification Handling

    func handleNotification(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return }

        switch type {
        case "like":
            NotificationCenter.default.post(name: .pushLikeReceived, object: userInfo)
        case "view_milestone":
            NotificationCenter.default.post(name: .pushMilestoneReceived, object: userInfo)
        case "new_template":
            NotificationCenter.default.post(name: .pushTemplateReceived, object: userInfo)
        default:
            break
        }
    }

    // MARK: - Local Notifications (Streak Reminders)

    /// Schedule a daily streak reminder at the user's preferred time
    func scheduleStreakReminder(hour: Int = 19, minute: Int = 0) {
        let content = UNMutableNotificationContent()
        content.title = "Keep your streak alive! 🔥"
        content.body = "Open StickDeath and create something today"
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(
            identifier: "streak_reminder",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("⚠️ Failed to schedule streak reminder: \(error.localizedDescription)")
            }
        }
    }

    /// Cancel the streak reminder (e.g. if user opens app that day)
    func cancelStreakReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["streak_reminder"]
        )
    }

    // MARK: - Badge Management

    func setBadgeCount(_ count: Int) {
        Task { @MainActor in
            if #available(iOS 16.0, *) {
                _ = try? await UNUserNotificationCenter.current().setBadgeCount(count)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = count
            }
        }
    }

    func clearBadge() {
        setBadgeCount(0)
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// Show notification banner even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }

    /// User tapped on a notification
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            PushNotificationManager.shared.handleNotification(userInfo: userInfo)
        }
        completionHandler()
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let pushLikeReceived = Notification.Name("pushLikeReceived")
    static let pushMilestoneReceived = Notification.Name("pushMilestoneReceived")
    static let pushTemplateReceived = Notification.Name("pushTemplateReceived")
}
