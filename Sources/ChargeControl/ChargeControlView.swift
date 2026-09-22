import SwiftUI

/// 充电控制页。
///
/// ## 为什么是原生界面，而不是守护进程托管的那份网页
///
/// 移植前评估过「把 web 前端改造成 SysProbe 的样子再塞进 WebView」，也照那个思路
/// 写了一份（随包发布的 `www/` 就是它）。真到落地时两个 WebView 都用不了：
///
/// - **WKWebView**：本 App 必须带 `com.apple.private.security.no-container`
///   （要 `posix_spawn` 一个 root 子进程，见 `Support/SysProbe.entitlements`），
///   而 iOS 16 起 WKWebView 要求 `container-required`，两者互斥 —— 这是
///   ChargeLimiter 作者自己在 `ui.mm` 里写下的结论；
/// - **UIWebView**：iOS 26 SDK 已把它从公开 API 里去掉，而 CI 跑在 Xcode 26 上，
///   编译都过不去。它没有替代品：这个 App 的场景就是不能用 WKWebView。
///
/// 所以这一页用 SwiftUI 重写。视觉与交互跟设计稿一致，而且直接复用了 App 自己的
/// `Panel` / `BarRow` / 配色与字体 —— 比嵌一层网页更贴合，也少一整套
/// 「WebView 加载失败 / 白屏 / 手势冲突」的失败模式。
///
/// `www/` 仍然随包发布：它是守护进程的 web root（删掉只会多一种失败模式），
/// 同时也是一道保险 —— 界面出问题时，在 Safari 里打开 `http://127.0.0.1:1230`
/// 依然能手动停充。设置页里有这个地址。
struct ChargeControlView: View {
    /// 见 `PageScaffold.onOpenSettings`：传动作，不传状态。
    var onOpenSettings: @MainActor () -> Void

    @EnvironmentObject private var charge: ChargeControlService
    @State private var page = 0

    var body: some View {
        PageScaffold("Charge", glow: .mwBattery, onOpenSettings: onOpenSettings) {
            Picker("Charge", selection: $page) {
                Text("Charge control").tag(0)
                Text("Battery info").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // 守护进程没起来时，下面所有开关都是「看着能点、点了没用」。
            // 与其让用户对着一个不生效的界面调半天，不如在顶上把话说清楚。
            if !charge.daemonBundled {
                EmptyNote(text: "The charge control service is not in this build. Run scripts/build-ipa.sh to fetch and bundle it.",
                          systemImage: "exclamationmark.triangle")
            } else if !charge.daemonRunning {
                EmptyNote(text: "The charge control service is not running. Nothing on this page will take effect until it starts.",
                          systemImage: "exclamationmark.triangle")
            }

            if page == 0 {
                ChargeControlPanels()
            } else {
                ChargeBatteryPanels()
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
//  Tab 1：充电控制
// ══════════════════════════════════════════════════════════════════════════════

private struct ChargeControlPanels: View {
    @EnvironmentObject private var charge: ChargeControlService
    @State private var confirmingReset = false

    var body: some View {
        Panel("Basics", systemImage: "switch.2",
              trailing: charge.daemonRunning ? Text("Service running") : Text("Service stopped")) {
            VStack(spacing: 12) {
                ToggleRow("Enable", isOn: Binding(get: { charge.config.enable },
                                                  set: { charge.setEnable($0) }))

                // 关掉总开关时，下面这些参数仍然可调 —— 守护进程照样收，只是不执行。
                // 这样用户可以先配好再打开，不必反过来。
                MenuRow("Mode",
                        value: Text(charge.config.mode.title),
                        tint: .mwAccent) {
                    ForEach(ChargeMode.allCases) { mode in
                        Button { charge.setMode(mode) } label: { Text(mode.title) }
                    }
                }
                Text(charge.config.mode.detail)
                    .font(.caption2)
                    .foregroundStyle(Color.mwMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MenuRow("Update frequency",
                        value: Text(verbatim: "\(charge.config.updateFrequency) s"),
                        tint: .mwAccent) {
                    ForEach(Self.frequencies, id: \.self) { seconds in
                        Button { charge.setUpdateFrequency(seconds) } label: { Text(verbatim: "\(seconds) s") }
                    }
                }

                MenuRow("Action",
                        value: charge.config.action == ChargeAction.notify.rawValue
                            ? Text(ChargeAction.notify.title) : Text(ChargeAction.none.title),
                        tint: .mwAccent) {
                    ForEach(ChargeAction.allCases) { action in
                        Button { charge.setAction(action) } label: { Text(action.title) }
                    }
                }
            }
        }

        Panel("Capacity thresholds", systemImage: "battery.50") {
            VStack(spacing: 16) {
                ThresholdSlider(title: "Start charging below",
                                value: charge.config.chargeBelow,
                                range: 10...80,
                                unit: "%",
                                tint: .mwAccent,
                                onChange: { charge.setChargeBelow($0) })
                ThresholdSlider(title: "Stop charging above",
                                value: charge.config.chargeAbove,
                                range: 30...100,
                                unit: "%",
                                tint: .mwBattery,
                                onChange: { charge.setChargeAbove($0) })
            }
        }

        Panel("Temperature control", systemImage: "thermometer.medium") {
            VStack(spacing: 16) {
                ToggleRow("Temperature control",
                          isOn: Binding(get: { charge.config.enableTemperature },
                                        set: { charge.setTemperatureControl($0) }))
                ThresholdSlider(title: "Stop charging above (°C)",
                                value: charge.config.temperatureAbove,
                                range: 20...45,
                                unit: "°",
                                tint: .mwLoss,
                                onChange: { charge.setTemperatureAbove($0) })
                ThresholdSlider(title: "Resume charging below (°C)",
                                value: charge.config.temperatureBelow,
                                range: 10...40,
                                unit: "°",
                                tint: .mwAccent,
                                onChange: { charge.setTemperatureBelow($0) })
            }
            .disabled(!charge.config.enableTemperature)
            .opacity(charge.config.enableTemperature ? 1 : 0.5)
        }

        Panel("Advanced", systemImage: "slider.horizontal.3") {
            VStack(spacing: 12) {
                ToggleRow("Prefer SmartBattery",
                          isOn: Binding(get: { charge.config.preferSmartBattery },
                                        set: { charge.setPreferSmartBattery($0) }))
                ToggleRow("Predictive charge inhibit",
                          isOn: Binding(get: { charge.config.predictiveInhibit },
                                        set: { charge.setPredictiveInhibit($0) }))
                ToggleRow("Disable current inflow while stopped",
                          isOn: Binding(get: { charge.config.disableInflow },
                                        set: { charge.setDisableInflow($0) }))

                MenuRow("Thermal simulation",
                        value: Text(charge.config.thermalMode.title),
                        tint: .mwAccent) {
                    ForEach(CuffMode.allCases) { mode in
                        Button { charge.setThermalMode(mode) } label: { Text(mode.title) }
                    }
                }
                MenuRow("PPM simulation",
                        value: Text(charge.config.ppmMode.title),
                        tint: .mwAccent) {
                    ForEach(CuffMode.allCases) { mode in
                        Button { charge.setPPMMode(mode) } label: { Text(mode.title) }
                    }
                }

                ToggleRow("Limit inflow",
                          isOn: Binding(get: { charge.config.limitInflow },
                                        set: { charge.setLimitInflow($0) }))

                Divider().overlay(Color.mwCardStroke)

                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    HStack {
                        Text("Reset all settings")
                        Spacer()
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .font(AppFont.text(14, weight: .medium))
                }
                .tint(.mwDanger)
                .confirmationDialog("Reset all settings", isPresented: $confirmingReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { charge.resetConfig() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every charge threshold, temperature limit and advanced option goes back to its default. This cannot be undone.")
                }
            }
        }
    }

    /// 原版的下拉项。1 秒是给「看着它动」用的，30 秒是给「装兜里省电」用的。
    private static let frequencies = [1, 2, 3, 5, 10, 30]
}

// ══════════════════════════════════════════════════════════════════════════════
//  Tab 2：电池信息
// ══════════════════════════════════════════════════════════════════════════════

private struct ChargeBatteryPanels: View {
    @EnvironmentObject private var charge: ChargeControlService

    private var battery: ChargeBatteryInfo { charge.battery }

    var body: some View {
        Panel("Battery", systemImage: "battery.100",
              trailing: battery.updateTime.map { Text($0.formatted(date: .omitted, time: .standard)) }) {
            VStack(spacing: 14) {
                BarRow(title: Text("Charge level"),
                       detail: Self.percent(battery.currentCapacity),
                       fraction: Double(battery.currentCapacity ?? 0) / 100,
                       tint: .mwBattery)
                BarRow(title: Text("Health"),
                       detail: battery.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                       fraction: (battery.healthPercent ?? 0) / 100,
                       tint: .mwAccent)
                BarRow(title: Text("Temperature"),
                       detail: battery.temperature.map { String(format: "%.1f °C", $0) } ?? "—",
                       // 0…50 °C 铺满整条。再热也不会到 50，而 0…40 会把日常读数挤在右半边。
                       fraction: (battery.temperature ?? 0) / 50,
                       tint: battery.temperature.map { Color.mwTemperature($0) } ?? .mwMuted)
            }
        }

        Panel("Charging", systemImage: "bolt.fill") {
            VStack(spacing: 12) {
                // 这是**即时动作**：直接对 IOPMPS 服务写 ExternalConnected，
                // 不写配置、重启 App 也不会保留。所以它跟上面那些开关长得一样、
                // 语义完全不同 —— 面板标题写「正在充电」而不是「充电控制」就是为了这个。
                ToggleRow("Charging now",
                          isOn: Binding(get: { battery.isCharging },
                                        set: { charge.setCharging($0) }))
                ValueRow(title: "Battery installed",
                         value: Strings.text(battery.isInstalled ? "Yes" : "No"),
                         tint: battery.isInstalled ? .mwBattery : .mwMuted)
            }
        }

        Panel("Battery parameters", systemImage: "list.bullet.rectangle") {
            VStack(spacing: 10) {
                ValueRow(title: "Cycle count", value: battery.cycleCount.map { String($0) } ?? "—")
                ValueRow(title: "Design capacity",
                         value: battery.designCapacity.map { "\($0) mAh" } ?? "—")
                ValueRow(title: "Full charge capacity",
                         value: battery.nominalChargeCapacity.map { "\($0) mAh" } ?? "—")
                ValueRow(title: "Current",
                         value: battery.amperage.map { "\($0) mA" } ?? "—")
                // 两个电压都是毫伏，跟原版前端一样除以 1000 显示。
                ValueRow(title: "Boot voltage",
                         value: battery.bootVoltage.map { String(format: "%.2f V", Double($0) / 1000) } ?? "—")
                ValueRow(title: "Voltage",
                         value: battery.voltage.map { String(format: "%.2f V", Double($0) / 1000) } ?? "—")
                ValueRow(title: "Serial", value: battery.serial ?? "—", monospaced: true)
            }
        }
    }

    private static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }
}

// ══════════════════════════════════════════════════════════════════════════════
//  行控件
// ══════════════════════════════════════════════════════════════════════════════

/// 标签 + 开关。
private struct ToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(AppFont.text(14, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .tint(.mwAccent)
    }
}

/// 标签 + 当前值 + 一个弹出菜单。
///
/// 当前值收 `Text` 而不是 `LocalizedStringKey`：这一列里既有译文（「插电即充」），
/// 也有量（「5 s」），把「要不要查表」的选择留在调用点 —— 跟 `Panel.trailing` 一个路子。
private struct MenuRow<Options: View>: View {
    let title: LocalizedStringKey
    let value: Text
    var tint: Color = .mwAccent
    @ViewBuilder var options: () -> Options

    init(_ title: LocalizedStringKey,
         value: Text,
         tint: Color = .mwAccent,
         @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.value = value
        self.tint = tint
        self.options = options
    }

    var body: some View {
        Menu {
            options()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(AppFont.text(14, weight: .medium))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                value
                    .font(AppFont.text(14, weight: .semibold))
                    .foregroundStyle(tint)
                Image(systemName: "chevron.up.chevron.down")
                    .font(AppFont.text(10, weight: .bold))
                    .foregroundStyle(Color.mwMuted)
            }
            .contentShape(Rectangle())
        }
    }
}

/// 标签 + 只读值。
private struct ValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var tint: Color = .primary
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppFont.text(14, weight: .medium))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text(value)
                .mwReadout(size: 14, weight: .semibold)
                .foregroundStyle(value == "—" ? Color.mwMuted.opacity(0.55) : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// 标签 + 数值 + 滑块。
///
/// 拖动期间只改本地 `draft`，松手才提交。不这样做的话，守护进程每 5 秒回一次配置，
/// 会把正在拖的滑块从手指底下拽回去。
private struct ThresholdSlider: View {
    let title: LocalizedStringKey
    let value: Int
    let range: ClosedRange<Double>
    let unit: String
    let tint: Color
    let onChange: (Int) -> Void

    @State private var draft: Double
    @State private var dragging = false

    init(title: LocalizedStringKey,
         value: Int,
         range: ClosedRange<Double>,
         unit: String,
         tint: Color,
         onChange: @escaping (Int) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.unit = unit
        self.tint = tint
        self.onChange = onChange
        self._draft = State(initialValue: Double(value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppFont.text(13, weight: .medium))
                Spacer(minLength: 8)
                Text("\(Int(draft))\(unit)")
                    .mwReadout(size: 16, weight: .semibold)
                    .foregroundStyle(tint)
            }
            // 显式写 `onEditingChanged:` 而不是用尾随闭包：`Slider` 有好几个重载，
            // 尾随闭包要靠编译器去挑「最后一个参数是闭包」的那一个，读起来也不明确。
            Slider(value: $draft, in: range, step: 1, onEditingChanged: { started in
                dragging = started
                if !started { onChange(Int(draft)) }
            })
            .tint(tint)
        }
        // 外部改了值（重置、或守护进程那边被别处改了）就跟着走。
        .onChange(of: value) { newValue in
            guard !dragging else { return }
            draft = Double(newValue)
        }
    }
}
