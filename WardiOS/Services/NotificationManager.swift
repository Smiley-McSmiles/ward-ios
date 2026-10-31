import Foundation
import UserNotifications
import UIKit

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private var authorized = false

    private init() {}

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let category = UNNotificationCategory(identifier: "MESSAGE", actions: [reply], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func notify(message: Message, chat: Chat, settings: SettingsStore) {
        guard settings.bool("notify.enabled"), !chat.isMuted else { return }
        if chat.isGroup {
            switch settings.string("notify.groups", "mentions") {
            case "none": return
            case "mentions": if !message.mentionsMe { return }
            default: break
            }
        }
        if isQuietHours(settings.string("notify.quiet_hours")) && !message.mentionsMe { return }
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "MESSAGE"
        content.threadIdentifier = "chat-\(chat.id)"
        content.userInfo = ["chatId": Int(chat.id), "accountId": Int(chat.accountId)]
        let mode = settings.string("notify.content", "full")
        if mode == "nothing" {
            content.title = "Ward"
            content.body = "New message"
        } else if mode == "sender" {
            content.title = chat.displayName
            content.body = "New message"
        } else {
            content.title = chat.isGroup ? "\(message.senderName) · \(chat.displayName)" : chat.displayName
            content.body = message.body.isEmpty ? (message.attachments.isEmpty ? "New message" : "📎 Attachment") : message.body
        }
        if settings.bool("notify.hide_encrypted") && !message.encryption.isEmpty {
            content.body = "Encrypted message"
        }
        if !settings.bool("notify.sounds") { content.sound = nil } else { content.sound = .default }
        let request = UNNotificationRequest(identifier: "message-\(message.id)-\(message.timestamp)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        updateBadge(settings: settings)
    }

    func updateBadge(settings: SettingsStore, unread: Int? = nil) {
        guard settings.bool("notify.badge") else { return }
        let count = unread ?? 0
        UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
    }

    private func isQuietHours(_ range: String) -> Bool {
        let parts = range.split(separator: "-")
        guard parts.count == 2,
              let start = minutes(String(parts[0])), let end = minutes(String(parts[1])) else { return false }
        let calendar = Calendar.current
        let now = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
        if start == end { return false }
        if start < end { return now >= start && now < end }
        return now >= start || now < end
    }

    private func minutes(_ value: String) -> Int? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - Deep links & notification replies

final class WardAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var replyHandler: (@MainActor (Int64, String) -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let chatId = info["chatId"] as? Int {
            UserDefaults.standard.set(chatId, forKey: "ward.pendingChat")
            NotificationCenter.default.post(name: .wardOpenChat, object: nil, userInfo: ["chatId": Int64(chatId)])
        }
        if response.actionIdentifier == "REPLY",
           let text = (response as? UNTextInputNotificationResponse)?.userText,
           let chatId = info["chatId"] as? Int {
            if let handler = WardAppDelegate.replyHandler {
                Task { @MainActor in handler(Int64(chatId), text) }
            }
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let wardOpenChat = Notification.Name("ward.openChat")
}
