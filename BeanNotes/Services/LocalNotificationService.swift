//
//  LocalNotificationService.swift
//  BeanNotes
//

import Foundation
import UserNotifications

final class LocalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationService()
    static let folderNotificationsEnabledKey = "folderWelcomeNotificationsEnabled"
    private static let folderWelcomeIdentifierPrefix = "folder-welcome-"

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    func configureForegroundPresentation() {
        center.delegate = self
    }

    func notifyFolderCreated(named folderName: String) {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? "New Folder" : name

        Task {
            guard UserDefaults.standard.bool(forKey: Self.folderNotificationsEnabledKey) else { return }
            guard await notificationsAreEnabled() else { return }

            let theme = BeanNotesTheme.currentFromDefaults()
            let content = UNMutableNotificationContent()
            content.title = theme.notificationTitle
            content.body = theme.folderCreatedBody(folderName: displayName)
            content.sound = .default
            content.attachments = notificationIconAttachment(for: theme).map { [$0] } ?? []

            let request = UNNotificationRequest(
                identifier: "\(Self.folderWelcomeIdentifierPrefix)\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )

            do {
                try await center.add(request)
            } catch {
                NSLog("BeanNotes could not schedule a folder notification: \(error)")
            }
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    static func shouldPresentSystemNotificationInForeground(identifier: String) -> Bool {
        !identifier.hasPrefix(folderWelcomeIdentifierPrefix)
    }

    private func notificationIconAttachment(for theme: BeanNotesTheme) -> UNNotificationAttachment? {
        let iconName = theme.notificationAttachmentName
        guard let url = Bundle.main.url(forResource: iconName, withExtension: "png") else {
            return nil
        }

        return try? UNNotificationAttachment(
            identifier: iconName,
            url: url,
            options: nil
        )
    }

    private func notificationsAreEnabled() async -> Bool {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Folder creation already gets immediate in-app feedback while BeanNotes is active.
        guard Self.shouldPresentSystemNotificationInForeground(
            identifier: notification.request.identifier
        ) else { return [] }

        return [.banner, .list, .sound]
    }
}
