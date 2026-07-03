//
//  LocalNotificationService.swift
//  BeanNote
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
            guard await requestAuthorizationIfNeeded() else { return }

            let content = UNMutableNotificationContent()
            content.title = "BeanNote"
            content.body = "Welcome to \"\(displayName)\"!"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "folder-welcome-\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )

            try? await center.add(request)
        }
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
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
