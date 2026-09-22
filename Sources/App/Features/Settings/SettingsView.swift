import SwiftUI

/// 设置页。只保留与功率采样有关的开关，以及移植来源的署名。
struct SettingsView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var wattHoursText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep the screen awake while charging",
                           isOn: $monitor.keepScreenAwakeWhileCharging)
                } header: {
                    Text("Charging")
                } footer: {
                    Text("The one-second tick stops when the screen locks, so a whole charge cannot be recorded with it off.")
                }

                Section {
                    HStack {
                        Text("Battery energy")
                        Spacer()
                        TextField("15", text: $wattHoursText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit(commitWattHours)
                        Text("Wh").foregroundStyle(Color.mwMuted)
                    }
                    Text("Used to turn a %/h slope into watts for the discharge estimate. Ignored when the pack capacity is readable from IOKit.")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                } header: {
                    Text("Estimate")
                }

                Section {
                    LabeledContent("Device", value: monitor.deviceModelIdentifier)
                    LabeledContent("Sensors", value: monitor.sensorsAvailable ? "available" : "unavailable")
                    ForEach(monitor.diagnostics, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.footnote)
                            .foregroundStyle(Color.mwMuted)
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    Text("Power and adapter readings are ported from MiniWatts, © the MiniWatts authors, licensed under the Apache License 2.0. They are read from Apple's private IOKit interfaces — read-only, no writes — which is why this app is sideload-only.")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                } header: {
                    Text("Credits")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { commitWattHours(); dismiss() }
                }
            }
            .onAppear {
                wattHoursText = String(format: "%.1f", monitor.configuredBatteryWattHours)
            }
        }
    }

    private func commitWattHours() {
        let normalised = wattHoursText.replacingOccurrences(of: ",", with: ".")
        if let value = Double(normalised), value > 0 {
            monitor.configuredBatteryWattHours = value
        }
        wattHoursText = String(format: "%.1f", monitor.configuredBatteryWattHours)
    }
}
