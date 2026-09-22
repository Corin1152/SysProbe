import SwiftUI

/// 设置页。语言、估算参数、诊断信息，以及移植来源的署名。
struct SettingsView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var wattHoursText: String = ""

    var body: some View {
        NavigationStack {
            // 画布铺在 `Form` **外面**、与它做兄弟节点，而不是 `Form` 的 `.background`。
            //
            // 两处差别都是看得见的：`NavigationStack` 自己的底色是系统分组色，只铺 `Form`
            // 的话导航栏那一条露出来的是它；而弹入／退出转场的第一帧若内容还没画上，
            // 露出来的同样是它 —— 深色下是近黑、浅色下是灰白，看起来就是整屏闪一下。
            ZStack {
                Color.mwCanvas
                Backdrop(glow: .mwAccent)
                Form {
                    Section {
                        Picker("Language", selection: $app.language) {
                            // 语言名一律用该语言自己的写法，且不参与翻译 —— 把「简体中文」
                            // 翻成 "Simplified Chinese" 之后，只会中文的人反而找不到它。
                            ForEach(AppLanguage.allCases) { language in
                                Text(verbatim: language.endonym).tag(language)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Language")
                    } footer: {
                        Text("Applies to the whole app straight away. The Today widget follows the system language instead — it runs in its own process and cannot read this setting.")
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
                        LabeledContent("Sensors",
                                       value: Strings.text(monitor.sensorsAvailable
                                                           ? "available"
                                                           : "unavailable"))
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
                .scrollContentBackground(.hidden)
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
        .mwSheetBackground()
    }

    private func commitWattHours() {
        let normalised = wattHoursText.replacingOccurrences(of: ",", with: ".")
        if let value = Double(normalised), value > 0 {
            monitor.configuredBatteryWattHours = value
        }
        wattHoursText = String(format: "%.1f", monitor.configuredBatteryWattHours)
    }
}
