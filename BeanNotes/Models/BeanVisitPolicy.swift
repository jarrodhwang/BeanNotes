//
//  BeanVisitPolicy.swift
//  BeanNotes
//

import Foundation

struct BeanVisitPolicy {
    static let enabledKey = "beanVisitsEnabled"
    static let lastShownDateKey = "lastBeanVisitDate"

    static let initialDelayNanoseconds: UInt64 = 120_000_000_000
    static let displayDurationNanoseconds: UInt64 = 5_000_000_000
    static let minimumCooldown: TimeInterval = 12 * 60 * 60

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

    static func lastShownDate(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastShownDateKey) as? Date
    }

    static func recordVisit(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastShownDateKey)
    }
}
