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
    static let blueberryVisitsEnabledKey = "blueberryVisitsEnabled"
    static let blueberryVisitsMayInterruptKey = "blueberryVisitsMayInterrupt"
    static let blueberryFocusReminderIntervalKey = "blueberryFocusReminderInterval"
    static let lastBlueberryVisitDateKey = "lastBlueberryVisitDate"

    static let blueberryEnabledKey = blueberryVisitsEnabledKey
    static let blueberryAllowsInterruptionsKey = blueberryVisitsMayInterruptKey
    static let blueberryLastShownDateKey = lastBlueberryVisitDateKey

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

    struct StorageKeys: Equatable, Sendable {
        let enabled: String
        let allowsInterruptions: String
        let focusReminderInterval: String
        let lastShownDate: String
    }

    static func storageKeys(for theme: BeanNotesTheme) -> StorageKeys? {
        switch theme {
        case .standard:
            nil
        case .bean:
            StorageKeys(
                enabled: enabledKey,
                allowsInterruptions: allowsInterruptionsKey,
                focusReminderInterval: focusReminderIntervalKey,
                lastShownDate: lastShownDateKey
            )
        case .blueberry:
            StorageKeys(
                enabled: blueberryEnabledKey,
                allowsInterruptions: blueberryAllowsInterruptionsKey,
                focusReminderInterval: blueberryFocusReminderIntervalKey,
                lastShownDate: blueberryLastShownDateKey
            )
        }
    }

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

        var blueberrySayings: [Saying] {
            switch self {
            case .friendly:
                [
                    Saying(
                        title: "A blueberry hello",
                        message: "A tiny blueberry rolled in to say your next idea is worth noting."
                    ),
                    Saying(
                        title: "Snack-sized cheer",
                        message: "Fancy a few blueberries? They bring fiber along with their bright flavor."
                    ),
                    Saying(
                        title: "Vitamin C note",
                        message: "Blueberries contain vitamin C and make a colorful writing-time snack."
                    ),
                    Saying(
                        title: "Deep-blue detail",
                        message: "Anthocyanins are pigments that help give blueberries their rich blue color."
                    ),
                    Saying(
                        title: "Berry good company",
                        message: "Keep writing, and save a small handful of blueberries for your next pause."
                    )
                ]
            case .returnFromBreak:
                [
                    Saying(
                        title: "Welcome back",
                        message: "Your page waited right here. Would a few blueberries make a refreshing return snack?"
                    ),
                    Saying(
                        title: "A fresh blue start",
                        message: "Blueberries contain fiber, so a small bowl can add a little fiber to snack time."
                    ),
                    Saying(
                        title: "Colorful return",
                        message: "Vitamin C is one of the nutrients found in blueberries. Ready for the next line?"
                    ),
                    Saying(
                        title: "Back in blue",
                        message: "Anthocyanins help make blueberries blue. Your notes are ready for more color too."
                    ),
                    Saying(
                        title: "Berry nice to see you",
                        message: "Settle back in, and enjoy a few blueberries if you are hungry."
                    )
                ]
            case .focusBreak:
                [
                    Saying(
                        title: "Blueberry break",
                        message: "Rest your eyes and stretch. If you are hungry, try a small blueberry snack."
                    ),
                    Saying(
                        title: "A little fiber pause",
                        message: "Blueberries contain fiber. A few can be a simple companion for this break."
                    ),
                    Saying(
                        title: "Vitamin C pause",
                        message: "Blueberries contain vitamin C. Take a breath, sip some water, and reset."
                    ),
                    Saying(
                        title: "Anthocyanin moment",
                        message: "Those deep blue pigments are called anthocyanins. Enjoy the color while you pause."
                    ),
                    Saying(
                        title: "Fresh focus soon",
                        message: "Have a few blueberries, loosen your shoulders, and return when you feel ready."
                    )
                ]
            }
        }

        func sayings(for theme: BeanNotesTheme) -> [Saying] {
            switch theme {
            case .standard:
                []
            case .bean:
                sayings
            case .blueberry:
                blueberrySayings
            }
        }

        func randomSaying() -> Saying {
            sayings.randomElement() ?? Saying(
                title: "Bean stopped by",
                message: "Bean brought you one supportive tail wag."
            )
        }

        func randomSaying(for theme: BeanNotesTheme) -> Saying {
            sayings(for: theme).randomElement() ?? Saying(
                title: "A writing break",
                message: "Your notes are ready whenever you are."
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
        theme.supportsFriendlyVisits
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

    static func lastShownDate(
        for theme: BeanNotesTheme,
        in defaults: UserDefaults = .standard
    ) -> Date? {
        guard let key = storageKeys(for: theme)?.lastShownDate else { return nil }
        return defaults.object(forKey: key) as? Date
    }

    static func recordVisit(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastShownDateKey)
    }

    static func recordVisit(
        for theme: BeanNotesTheme,
        at date: Date = Date(),
        in defaults: UserDefaults = .standard
    ) {
        guard let key = storageKeys(for: theme)?.lastShownDate else { return }
        defaults.set(date, forKey: key)
    }

    static func cooldownHasElapsed(
        for theme: BeanNotesTheme,
        now: Date,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        cooldownHasElapsed(now: now, lastShownDate: lastShownDate(for: theme, in: defaults))
    }

    static func cooldownRemaining(
        for theme: BeanNotesTheme,
        now: Date,
        in defaults: UserDefaults = .standard
    ) -> TimeInterval {
        cooldownRemaining(now: now, lastShownDate: lastShownDate(for: theme, in: defaults))
    }
}
