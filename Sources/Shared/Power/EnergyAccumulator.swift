import Foundation

/// Energy totals for one stretch of charging, integrated from the live sensors.
///
/// The sandbox never hands out the pack's design capacity, but it does hand out
/// voltage and current at ~1 Hz on both sides of the charge IC. Integrating those
/// gives the two numbers that actually matter — how much energy the adapter
/// delivered, and how much of it reached the cell.
nonisolated struct EnergyTotals: Codable, Hashable {
    /// ∫ V·I dt at the adapter, in watt-hours.
    var inputWattHours: Double = 0
    /// ∫ V·I dt at the battery rail, in watt-hours.
    var batteryWattHours: Double = 0
    /// ∫ I dt at the battery rail, in milliamp-hours. Comparable to a pack's mAh rating.
    var batteryMilliAmpHours: Double = 0
    /// Seconds of integration, which is not the same as wall-clock time: gaps
    /// longer than the sample window are dropped rather than extrapolated.
    var integratedSeconds: TimeInterval = 0

    /// Delivered energy, or nil when none could be measured.
    ///
    /// Wireless charging exposes no input-current sensor, so this stays at zero
    /// for a whole MagSafe session while the battery side accumulates normally.
    /// Nil says "not measured" where a bare 0.00 Wh would read as "nothing came in".
    var measuredInputWattHours: Double? {
        inputWattHours > 0.001 ? inputWattHours : nil
    }

    /// Share of delivered energy that reached the cell, 0…100.
    var efficiencyPercent: Double? {
        guard inputWattHours > 0.001, batteryWattHours > 0 else { return nil }
        return min(batteryWattHours / inputWattHours, 1) * 100
    }

    /// Energy that turned into heat in the cable, the charge IC and the coil.
    var lossWattHours: Double {
        max(inputWattHours - batteryWattHours, 0)
    }

    var averageInputWatts: Double? {
        guard integratedSeconds > 0 else { return nil }
        return inputWattHours * 3600 / integratedSeconds
    }
}

/// Trapezoidal integration of the live power readings.
///
/// Samples arrive about once a second while the app is in the foreground and stop
/// entirely when it is backgrounded. Rather than extrapolate across those gaps,
/// any interval longer than `maximumInterval` is discarded — the totals then read
/// as "energy measured while watching", which is honest, and `integratedSeconds`
/// records how much of the wall clock that covered.
nonisolated final class EnergyAccumulator {
    private struct Sample {
        let date: Date
        let inputWatts: Double
        let batteryWatts: Double
        let batteryAmps: Double
    }

    /// Longest gap that still counts as continuous measurement.
    private static let maximumInterval: TimeInterval = 10

    private(set) var totals = EnergyTotals()
    private var previous: Sample?

    func reset() {
        totals = EnergyTotals()
        previous = nil
    }

    func add(_ snapshot: PowerSnapshot) {
        let sample = Sample(date: snapshot.date,
                            inputWatts: snapshot.inputWatts ?? 0,
                            batteryWatts: max(snapshot.batteryWatts ?? 0, 0),
                            batteryAmps: max(snapshot.batteryCurrent ?? 0, 0))
        defer { previous = sample }
        guard let previous else { return }

        let interval = sample.date.timeIntervalSince(previous.date)
        guard interval > 0, interval <= Self.maximumInterval else { return }

        let hours = interval / 3600
        totals.inputWattHours += (previous.inputWatts + sample.inputWatts) / 2 * hours
        totals.batteryWattHours += (previous.batteryWatts + sample.batteryWatts) / 2 * hours
        totals.batteryMilliAmpHours += (previous.batteryAmps + sample.batteryAmps) / 2 * hours * 1000
        totals.integratedSeconds += interval
    }
}
