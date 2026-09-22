import SwiftUI

/// 设置页。语言、与功率采样有关的开关，以及移植来源的署名。
struct SettingsView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var wattHoursText: String = ""

    var body: some View {
        NavigationStack {
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
                    Toggle("Keep the screen awake while charging",
                           isOn: $monitor.keepScreenAwakeWhileCharging)
                } header: {
                    // 刻意不叫 "Charging"：那个键已经被充电状态那颗 Pill 占了
                    // （"Charging" → 充电中），一个键只能有一条译文，复用会把
                    // 分区标题写成「充电中」。
                    Text("Charging options")
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
                    // `Strings.text` 而不是 `String(localized:)`：后者的解析路径不
                    // 经过被替换掉的那个 `Bundle` 方法，切了语言也不会变。
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
            // 与三个分页铺同一张画布。原先是裸 `Form`，用的是系统分组背景 —— 弹入／
            // 退出设置页时整屏底色会从画布色跳成系统灰（深色下是近黑跳成 #1C1C1E），
            // 看起来就是一下闪。铺上画布后，转场前后是同一个底色。
            .scrollContentBackground(.hidden)
            .background(Backdrop(glow: .mwAccent))
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
