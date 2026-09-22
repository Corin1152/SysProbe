import SwiftUI

/// 设置页。语言、诊断信息，以及移植来源的署名。
struct SettingsView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var charge: ChargeControlService
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

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
                        LabeledContent("Device", value: monitor.deviceModelIdentifier)
                        LabeledContent("Sensors",
                                       value: Strings.text(monitor.sensorsAvailable
                                                           ? "available"
                                                           : "unavailable"))
                        // 版本与扩展摘要。排查负一屏问题时，第一步就是确认装的是哪一版、
                        // 扩展有没有被打进包 —— 这两行显示的就是**这一版**的真实内容。
                        LabeledContent("App version", value: AppInfo.version)
                        LabeledContent("Widget", value: AppInfo.widgetSummary)
                        // 充电守护进程的状态。
                        //
                        // 这一行值得放在这里而不是只放在充电页上：它是唯一能区分
                        // 「守护进程没被打进包」与「打进去了但起不来」的地方 ——
                        // 两者的界面表现一模一样（开关能点、什么都不发生）。
                        LabeledContent("Charge control",
                                       value: Strings.text(charge.daemonRunning
                                                           ? "Service running"
                                                           : "Service stopped"))
                        // 守护进程托管的网页界面。App 里**不用**它（见 `ChargeControlView`），
                        // 但它是 App 之外最后一道保险：界面出问题时，在 Safari 里打开
                        // 这个地址依然能手动停充。
                        Link(destination: ChargeBridge.interfaceURL) {
                            HStack {
                                Text("Service address")
                                Spacer()
                                Text(ChargeBridge.interfaceURL.absoluteString)
                                    .foregroundStyle(Color.mwAccent)
                            }
                        }
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
                        Text("Charge control is ported from ChargeLimiter, © lich4, licensed under the GNU GPL v3. Its daemon is fetched from the upstream release at build time rather than stored in this repository.")
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
                    Button("Done") { dismiss() }
                }
            }
        }
        .mwSheetBackground()
    }
}
