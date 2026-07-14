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

        var sayings: [Saying] {
            switch self {
            case .friendly:
                [
                    Saying(
                        title: "Bean stopped by",
                        message: "Bean brought you one supportive tail wag."
                    ),
                    Saying(
                        title: "A note from Bean",
                        message: "Bean says you have got this. She would also like to know if that is cheese."
                    ),
                    Saying(
                        title: "Bean heard an idea",
                        message: "Her ears perked up, so it must be a good one."
                    ),
                    Saying(
                        title: "Paws for encouragement",
                        message: "Bean is cheering on your next idea with her whole tail."
                    ),
                    Saying(
                        title: "Bean's tiny patrol",
                        message: "She checked the page for squirrels. All clear."
                    ),
                    Saying(
                        title: "Good work, human",
                        message: "Bean approves and requests a celebratory ear scratch."
                    )
                ]
            case .returnFromBreak:
                [
                    Saying(
                        title: "Welcome back",
                        message: "Bean saved your spot while you were away."
                    ),
                    Saying(
                        title: "Bean kept watch",
                        message: "Your notes are safe. She only sniffed them a little."
                    ),
                    Saying(
                        title: "You came back!",
                        message: "Bean's tail has officially resumed wagging."
                    ),
                    Saying(
                        title: "Bean missed you",
                        message: "She waited very patiently, by dog standards."
                    )
                ]
            case .focusBreak:
                [
                    Saying(
                        title: "Time for a Bean break",
                        message: "Stretch, sip some water, or take a short walk. Bean recommends all three."
                    ),
                    Saying(
                        title: "Bean says: paws up",
                        message: "You have been focused for a while. Give your eyes and paws a rest."
                    ),
                    Saying(
                        title: "Walkies?",
                        message: "Bean thinks a quick movement break would do you both good."
                    ),
                    Saying(
                        title: "Snack inspection",
                        message: "Time to refuel. Bean volunteers to supervise every bite."
                    ),
                    Saying(
                        title: "Bean's stretch club",
                        message: "Stand up, stretch tall, and shake it out like a very happy dog."
                    )
                ]
            }
        }

        func randomSaying() -> Saying {
            sayings.randomElement() ?? Saying(
                title: "Bean stopped by",
                message: "Bean brought you one supportive tail wag."
            )
        }
    }

    struct Saying: Equatable, Sendable {
        let title: String
        let message: String
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
