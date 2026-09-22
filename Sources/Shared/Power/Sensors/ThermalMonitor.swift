import Foundation

/// Watches the system's own thermal verdict.
///
/// This is public API, and it is what makes the temperature numbers mean
/// something: when fast charging drops from 20 W to 10 W a few minutes in, the
/// reason is usually that iOS moved past `.nominal` and started limiting current.
///
/// iOS 16 compatibility: no longer `@Observable`. Views do not observe this
/// object directly any more — `PowerMonitor` mirrors `state`, `stateSince` and
/// `lowPowerMode` into its own published properties after every tick.
final class ThermalMonitor {
    private(set) var state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// When the current thermal state was entered, so the UI can say how long
    /// throttling has been in effect.
    private(set) var stateSince: Date = .now

    /// Polled from `PowerMonitor`'s one-second tick rather than driven by
    /// `thermalStateDidChangeNotification`.
    ///
    /// The notification bought nothing here: the tick already runs whenever the
    /// app is on screen, so the state is at most a second stale while anyone can
    /// see it, and neither route observes a change that happens while the app is
    /// suspended. Dropping it also drops the observer tokens, which a Swift 6
    /// `deinit` — nonisolated, on a main-actor class — is not allowed to clean up.
    func update() {
        let current = ProcessInfo.processInfo.thermalState
        if current != state {
            state = current
            stateSince = .now
        }
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

extension ProcessInfo.ThermalState {
    var title: LocalizedStringKey {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// What the state means for charging specifically.
    var chargingEffect: LocalizedStringKey {
        switch self {
        case .nominal: return "No thermal limit on charge current."
        case .fair: return "Warming up. Charge current may be trimmed."
        case .serious: return "Throttling: iOS is limiting charge current and clocks."
        case .critical: return "Overheated: charging is suspended until the phone cools."
        @unknown default: return "Unrecognised thermal state."
        }
    }

    var symbol: String {
        switch self {
        case .nominal: return "checkmark.circle"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        @unknown default: return "questionmark.circle"
        }
    }

    /// True once the system is actively limiting power.
    var isThrottling: Bool {
        self == .serious || self == .critical
    }

    /// 0…1, for the severity meter.
    var severity: Double {
        switch self {
        case .nominal: return 0.15
        case .fair: return 0.45
        case .serious: return 0.75
        case .critical: return 1.0
        @unknown default: return 0
        }
    }
}
