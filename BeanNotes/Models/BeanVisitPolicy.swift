//
//  BeanVisitPolicy.swift
//  BeanNotes
//

import Foundation

struct BeanVisitPolicy {
    static let enabledKey = "beanVisitsEnabled"
    static let allowsInterruptionsKey = "beanVisitsMayInterrupt"
    static let focusReminderIntervalKey = "beanFocusReminderInterval"
    static let lastShownDateKey = "lastBeanVisitDate"

    static let interruptibleInitialDelay: TimeInterval = 2 * 60
    static let displayDurationNanoseconds: UInt64 = 5_000_000_000
    static let minimumCooldown: TimeInterval = 15 * 60
    static let awayThreshold: TimeInterval = 3 * 60
    static let defaultFocusReminderInterval: TimeInterval = 60 * 60

    static let focusReminderOptions: [FocusReminderOption] = [
        FocusReminderOption(label: "30 minutes", interval: 30 * 60),
        FocusReminderOption(label: "1 hour", interval: defaultFocusReminderInterval),
        FocusReminderOption(label: "90 minutes", interval: 90 * 60),
        FocusReminderOption(label: "2 hours", interval: 2 * 60 * 60)
    ]

    enum VisitReason: String, Equatable, Sendable {
        case friendly
        case returnFromBreak
        case focusBreak

        var title: String {
            switch self {
            case .friendly:
                "Bean stopped by"
            case .returnFromBreak:
                "Welcome back"
            case .focusBreak:
                "Time for a Bean break"
            }
        }

        var message: String {
            switch self {
            case .friendly:
                "Bean is cheering on your next idea."
            case .returnFromBreak:
                "Bean saved your spot while you were away."
            case .focusBreak:
                "You have been focused for a while. Stretch, sip some water, or grab a meal."
            }
        }
    }

    struct FocusReminderOption: Identifiable, Equatable, Sendable {
        var label: String
        var interval: TimeInterval

        var id: TimeInterval { interval }
    }

    static func canSchedule(
        theme: BeanNotesTheme,
        isEnabled: Bool,
        sceneIsActive: Bool,
        isSafeSurface: Bool,
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState,
        launchArguments: [String]
    ) -> Bool {
        theme == .bean
            && isEnabled
            && sceneIsActive
            && isSafeSurface
            && !isLowPowerModeEnabled
            && thermalState != .serious
            && thermalState != .critical
            && !launchArguments.contains(BeanNotesLaunchConfiguration.uiTestingArgument)
    }

    static func cooldownHasElapsed(now: Date, lastShownDate: Date?) -> Bool {
        guard let lastShownDate else { return true }
        return now.timeIntervalSince(lastShownDate) >= minimumCooldown
    }

    static func cooldownRemaining(now: Date, lastShownDate: Date?) -> TimeInterval {
        guard let lastShownDate else { return 0 }
        return max(0, minimumCooldown - now.timeIntervalSince(lastShownDate))
    }

    static func shouldVisitAfterReturning(
        awayDuration: TimeInterval,
        allowsInterruptions: Bool
    ) -> Bool {
        !allowsInterruptions && awayDuration >= awayThreshold
    }

    static func shouldVisitAfterFocusing(
        focusDuration: TimeInterval,
        reminderInterval: TimeInterval,
        allowsInterruptions: Bool
    ) -> Bool {
        !allowsInterruptions && focusDuration >= normalizedFocusReminderInterval(reminderInterval)
    }

    static func normalizedFocusReminderInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultFocusReminderInterval }
        return focusReminderOptions.contains { $0.interval == interval }
            ? interval
            : defaultFocusReminderInterval
    }

    static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        let normalized = max(0, interval.isFinite ? interval : 0)
        return UInt64(min(normalized * 1_000_000_000, Double(UInt64.max)))
    }

    static func lastShownDate(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastShownDateKey) as? Date
    }

    static func recordVisit(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastShownDateKey)
    }
}
