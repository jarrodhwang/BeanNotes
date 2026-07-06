//
//  LocalNotificationService.swift
//  BeanNotes
//

import Foundation
import UserNotifications

final class LocalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotificationService()

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
            guard await notificationsAreEnabled() else { return }

            let theme = BeanNotesTheme.currentFromDefaults()
            let content = UNMutableNotificationContent()
            content.title = theme.notificationTitle
            content.body = theme.folderCreatedBody(folderName: displayName)
            content.sound = .default
            content.attachments = notificationIconAttachment(for: theme).map { [$0] } ?? []

            let request = UNNotificationRequest(
                identifier: "folder-welcome-\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )

            try? await center.add(request)
        }
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
        [.banner, .list, .sound]
    }
}
