import SwiftUI

/// 负一屏小组件的内容。数据来自 `PowerMonitor`，由控制器以 1 秒的节奏驱动。
struct TodayContentView: View {
    @ObservedObject var monitor: PowerMonitor

    private var snapshot: PowerSnapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroRow
            if snapshot.externalConnected {
                batteryRow
                pathPanel
                adapterPanel
            } else {
                Panel("Power", systemImage: "bolt.slash") {
                    Text("Plug in a charger to read the adapter's handshake.")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 顶部：大环 + 关键读数

    private var heroRow: some View {
        HStack(alignment: .center, spacing: 14) {
            PowerRing(inputWatts: monitor.headline?.watts,
                      batteryWatts: snapshot.batteryWatts,
                      fullScale: max(snapshot.adapterRatedWatts ?? 30, 1),
                      caption: monitor.headline?.caption,
                      tint: snapshot.isWirelessInput ? .mwWireless : .mwAccent,
                      size: 132)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Pill(text: Text(snapshot.statusText),
                         systemImage: snapshot.isCharging ? "bolt.fill" : "powerplug.fill",
                         tint: snapshot.isCharging ? .mwBattery : .mwMuted)
                    if snapshot.isWirelessInput {
                        Pill(text: Text("Wireless"), systemImage: "wave.3.right", tint: .mwWireless)
                    }
                }

                Metric(caption: "Battery",
                       value: snapshot.percent.map { "\($0)" } ?? "—",
                       unit: snapshot.percent != nil ? "%" : nil,
                       tint: .mwBattery,
                       size: 26)

                if let voltage = snapshot.batteryVoltage, let current = snapshot.batteryCurrent {
                    Metric(caption: "Cell",
                           value: "\(Formatting.volts(voltage)) · \(Formatting.amps(current))",
                           size: 18)
                }
                if let temperature = snapshot.batteryTemperature {
                    Metric(caption: "Cell temperature",
                           value: Formatting.temperature(temperature),
                           tint: .mwTemperature(temperature),
                           size: 18)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 电池

    private var batteryRow: some View {
        Panel("Battery", systemImage: "battery.100") {
            HStack(spacing: 14) {
                Metric(caption: "Voltage",
                       value: snapshot.batteryVoltage.map(Formatting.volts) ?? "—",
                       tint: .mwAccent,
                       size: 20)
                Metric(caption: "Current",
                       value: snapshot.batteryCurrent.map(Formatting.amps) ?? "—",
                       tint: .mwBattery,
                       size: 20)
                Metric(caption: "Temperature",
                       value: snapshot.batteryTemperature.map(Formatting.temperature) ?? "—",
                       tint: snapshot.batteryTemperature.map { .mwTemperature($0) } ?? .mwMuted,
                       size: 20)
            }
        }
    }

    // MARK: 供电路径

    private var pathPanel: some View {
        Panel("Power path", systemImage: "arrow.triangle.branch",
              trailing: snapshot.adapterUtilisation.map {
                  Text(verbatim: "\(Formatting.percent($0 * 100))% of adapter")
              }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Metric(caption: "From charger",
                           value: snapshot.inputWatts.map(Formatting.watts) ?? "—",
                           unit: snapshot.inputWatts != nil ? "W" : nil,
                           tint: .mwAccent,
                           size: 22)
                    Metric(caption: "Into cell",
                           value: snapshot.batteryWatts.map { Formatting.watts(abs($0)) } ?? "—",
                           unit: snapshot.batteryWatts != nil ? "W" : nil,
                           tint: .mwBattery,
                           size: 22)
                }
                HStack(spacing: 14) {
                    Metric(caption: "Loss",
                           value: snapshot.conversionLossWatts.map(Formatting.watts) ?? "—",
                           unit: snapshot.conversionLossWatts != nil ? "W" : nil,
                           tint: .mwLoss,
                           size: 18)
                    Metric(caption: "Efficiency",
                           value: snapshot.conversionEfficiency.map { Formatting.percent($0 * 100) } ?? "—",
                           unit: snapshot.conversionEfficiency != nil ? "%" : nil,
                           tint: .mwBattery,
                           size: 18)
                }
            }
        }
    }

    // MARK: 适配器

    private var adapterPanel: some View {
        Panel("Adapter", systemImage: "powerplug",
              trailing: Text(verbatim: snapshot.adapterSource ?? "")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Metric(caption: "Actual",
                           value: snapshot.inputWatts.map(Formatting.watts) ?? "—",
                           unit: snapshot.inputWatts != nil ? "W" : nil,
                           tint: .mwAccent,
                           size: 22)
                    Metric(caption: "Rated",
                           value: snapshot.adapterRatedWatts.map { String(format: "%.0f", $0) } ?? "—",
                           unit: snapshot.adapterRatedWatts != nil ? "W" : nil,
                           size: 22)
                }

                if let utilisation = snapshot.adapterUtilisation {
                    BarRow(title: Text("Adapter utilisation"),
                           detail: Formatting.percent(utilisation * 100) + "%",
                           fraction: utilisation,
                           tint: .mwAccent)
                }

                if let name = snapshot.adapterName {
                    detailRow("Name", name)
                }
                if let profile = snapshot.negotiatedProfile {
                    detailRow("Negotiated", profile.label)
                }

                if !snapshot.adapterProfiles.isEmpty {
                    Divider().overlay(Color.mwCardStroke)
                    Text("Advertised profiles").mwCaption()
                    ForEach(snapshot.adapterProfiles) { profile in
                        HStack(spacing: 8) {
                            Image(systemName: profile.index == snapshot.negotiatedProfile?.index
                                  ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(profile.index == snapshot.negotiatedProfile?.index
                                                 ? Color.mwAccent : Color.mwMuted)
                            Text(verbatim: profile.label)
                                .mwMono(size: 12)
                            Spacer(minLength: 8)
                            Text(verbatim: String(format: "%.0f W", profile.watts))
                                .mwMono(size: 12)
                                .foregroundStyle(Color.mwMuted)
                        }
                    }
                }

                if let estimate = monitor.pathResistance {
                    Divider().overlay(Color.mwCardStroke)
                    HStack(spacing: 14) {
                        Metric(caption: "Path resistance",
                               value: "\(estimate.milliohms)",
                               unit: "mΩ",
                               tint: .mwLoss,
                               size: 18)
                        Metric(caption: "Voltage drop",
                               value: snapshot.inputVoltageDropVolts.map { String(format: "%.2f", $0) } ?? "—",
                               unit: snapshot.inputVoltageDropVolts != nil ? "V" : nil,
                               size: 18)
                    }
                }
            }
        }
    }

    private func detailRow(_ label: LocalizedStringResource, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.mwMuted)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
    }
}
