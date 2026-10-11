import SwiftUI

/// 「电源」页分段 3 —— 充电控制。**这是分段的内容，不是页面。**
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
/// 所以这一段用 SwiftUI 重写。视觉与交互跟设计稿一致，而且直接复用了 App 自己的
/// `Panel` / `BarRow` / 配色与字体 —— 比嵌一层网页更贴合，也少一整套
/// 「WebView 加载失败 / 白屏 / 手势冲突」的失败模式。
///
/// `www/` 仍然随包发布：它是守护进程的 web root（删掉只会多一种失败模式），
/// 同时也是一道保险 —— 界面出问题时，在 Safari 里打开 `http://127.0.0.1:1230`
/// 依然能手动停充。关于页里有这个地址。
///
/// ── 2026-10-11 ──────────────────────────────────────────────────────────────
///
/// 这里原本还有一个 `ChargeControlView`（一个带两段 `Picker` 的独立分页「智充」）。
/// 现在「智充」这个名字没有了：这一段并入了 `PowerHubView`，外壳由它提供。
/// 所以结构体从 `private` 变成模块内可见，并且**自己带上滚动容器** ——
/// 它以前是被 `PageScaffold` 的 `ScrollView` 装着的。
///
/// ── 2026-10-11（第二轮）────────────────────────────────────────────────────
///
/// 按界面反馈又收了两处：
///
///   1. 「电池信息」分段整个并进来了（`ChargeBatteryPanels` 删除）。它的两张卡片
///      —— 电池、电池参数 —— 现在排在这一页最后；
///   2. 「高级」卡片只留「智能停充」与「重置全部设置」，挪进「基础」卡片末尾，
///      其余四项（Prefer SmartBattery / 停充时启用禁流 / 热模拟 / PPM 模拟 / 限流）
///      移除。那些配置项在守护进程里仍然存在，只是不再有界面入口。

// ══════════════════════════════════════════════════════════════════════════════
//  分段 3：充电控制（含电池信息）
// ══════════════════════════════════════════════════════════════════════════════

/// 「电源」页分段 3 —— 充电控制 + 电池信息。
///
/// 滚动容器在这一层（它以前是被 `PageScaffold` 的 `ScrollView` 装着的），
/// 所以面板列表从「`PageScaffold` 的若干兄弟子视图」变成「一个 `LazyVStack` 的子视图」，
/// 间距 14 由 `LazyVStack` 自己给 —— 与 `PageScaffold` 里的间距是同一个数。
///
/// 卡片顺序：基础（含智能停充 / 重置）→ 容量阈值 → 温度控制 → 电池 → 电池参数。
/// 前两张是「怎么管充电」，后两张是「电池现在什么样」—— 后者原本是独立分段，
/// 按要求挪到末尾。
struct ChargeControlPanels: View {
    @EnvironmentObject private var charge: ChargeControlService

    private var battery: ChargeBatteryInfo { charge.battery }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ChargeServiceNote()

                basicsPanel
                thresholdsPanel
                temperaturePanel
                batteryPanel
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 24)
            .mwContainerWidth()
        }
    }

    private var basicsPanel: some View {
        Panel("Basics", systemImage: "switch.2",
              trailing: charge.daemonRunning ? Text("Service running") : Text("Service stopped")) {
            VStack(spacing: 12) {
                ToggleRow("Enable", isOn: Binding(get: { charge.config.enable },
                                                  set: { charge.setEnable($0) }))

                // 关掉总开关时，下面这几项仍然可调 —— 守护进程照样收，只是不执行。
                // 这样用户可以先配好再打开，不必反过来。
                //
                // 「模式」的说明文案原本独占一行挂在下面，2026-10-11 按要求挪进这一行
                // ——挤在标题与右侧取值之间，字号缩一档。见 `MenuRow.detail`。
                MenuRow("Mode",
                        value: Text(charge.config.mode.title),
                        detail: charge.config.mode.detail,
                        tint: .mwAccent) {
                    ForEach(ChargeMode.allCases) { mode in
                        Button { charge.setMode(mode) } label: { Text(mode.title) }
                    }
                }

                MenuRow("Update frequency",
                        value: Text(verbatim: "\(charge.config.updateFrequency) s"),
                        tint: .mwAccent) {
                    ForEach(Self.frequencies, id: \.self) { seconds in
                        Button { charge.setUpdateFrequency(seconds) } label: { Text(verbatim: "\(seconds) s") }
                    }
                }

                // ── 2026-10-11：从「高级」卡片搬过来的一项 ──────────────────────
                //
                // 「高级」里原有六项（Prefer SmartBattery / 智能停充 / 停充时启用禁流 /
                // 热模拟 / PPM 模拟 / 限流），只留「智能停充」挪到这张卡片末尾，
                // 其余移除（「重置全部设置」也在同一天删掉了）。
                //
                // 被移除的五项里，前四项是**实验性开关**（上游 ChargeLimiter 的调试入口），
                // 「限流」是给特定充电器兜底用的 —— 它们都仍然在守护进程的配置里，
                // 只是不再有界面入口；已经设过的值原样保留。
                Divider().overlay(Color.mwCardStroke)

                ToggleRow("Predictive charge inhibit",
                          isOn: Binding(get: { charge.config.predictiveInhibit },
                                        set: { charge.setPredictiveInhibit($0) }))
            }
        }
    }

    private var thresholdsPanel: some View {
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
    }

    private var temperaturePanel: some View {
        Panel("Temperature control", systemImage: "thermometer.medium") {
            VStack(spacing: 16) {
                // 这里原本还有一个「温度控制」开关，2026-10-11 按要求删掉了 ——
                // 它并入「基础」卡片里的「启用」总开关：总开关打开就等于温度控制生效。
                // 写入在 `ChargeControlService.setEnable`，守护进程侧的老配置由
                // `reconcileTemperatureControl` 对齐。
                //
                // 两个阈值仍然只在总开关打开时可调，所以套一层单独的 `VStack` 再禁用它。
                //
                // **`.disabled()` 会向整棵子树传播** —— 早先把它套在最外层那个 `VStack` 上，
                // 结果连上面那个总开关自己也一起被禁掉了；而它默认是关的，于是永远打不开，
                // 整块看上去就是「点了没反应」。这类错误不会报任何编译或运行错误。
                VStack(spacing: 16) {
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
                .disabled(!charge.config.enable)
                .opacity(charge.config.enable ? 1 : 0.5)

                // 灰掉的原因要写出来 —— 开关在上一张卡片里，这一页看不到它。
                Text("Follows the Enable switch above.")
                    .font(.caption2)
                    .foregroundStyle(Color.mwMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 电池：实时读数（电量 / 健康度 / 温度）+ 静态参数（循环次数 / 容量 / 电压电流）。
    ///
    /// 2026-10-11 由两张卡片合并成一张 —— 它们说的是同一个东西的两面，
    /// 中间一条分隔线比两张卡片各带一个标题更省地方。原来的标题「电池参数」
    /// 随之取消，那几行读数本身就是自解释的。
    private var batteryPanel: some View {
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

                Divider().overlay(Color.mwCardStroke)

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
    }

    private static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    /// 原版的下拉项。1 秒是给「看着它动」用的，30 秒是给「装兜里省电」用的。
    private static let frequencies = [1, 2, 3, 5, 10, 30]
}

/// 守护进程没起来时的提示条。
///
/// 它原来画在 `ChargeControlView` 里、位于分段控件与分段内容之间，两个分段都能看到。
/// 2026-10-11 之后「电池信息」并进了这一页，所以只剩一个调用点 —— 但**类型保留**：
/// 它答的是「为什么下面全部不生效」，和 `ChargeControlPanels` 那堆面板是两件事。
///
/// 两种情况要分开说：
///   · **没打进包**（`daemonBundled == false`）：这一版构建就没带它，用户自己修不了；
///   · **打进包但没跑起来**：可能是权限、可能是被杀，值得让用户知道「下面全部不生效」。
struct ChargeServiceNote: View {
    @EnvironmentObject private var charge: ChargeControlService

    var body: some View {
        if !charge.daemonBundled {
            EmptyNote(text: "The charge control service is not in this build. Run scripts/build-ipa.sh to fetch and bundle it.",
                      systemImage: "exclamationmark.triangle")
        } else if !charge.daemonRunning {
            EmptyNote(text: "The charge control service is not running. Nothing on this page will take effect until it starts.",
                      systemImage: "exclamationmark.triangle")
        }
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
    /// 行内说明，可选。给「模式」用 —— 那句话原本独占一行挂在下面，
    /// 2026-10-11 按要求挪进标题与右侧取值之间。
    ///
    /// 已经是译文（`ChargeMode.detail` 返回 `String`），所以渲染走 `Text(verbatim:)`，
    /// 不会二次查表。
    var detail: String?
    var tint: Color = .mwAccent
    @ViewBuilder var options: () -> Options

    init(_ title: LocalizedStringKey,
         value: Text,
         detail: String? = nil,
         tint: Color = .mwAccent,
         @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.value = value
        self.detail = detail
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
                if let detail {
                    // `layoutPriority(-1)`：空间不够时**先压这一句**，别去挤标题和取值 ——
                    // 那两个才是这一行真正要传达的东西。再配合 `minimumScaleFactor`，
                    // 长一点的说明会缩到能放下为止，而不是把右边的取值顶出去。
                    Text(verbatim: detail)
                        .font(AppFont.text(11))
                        .foregroundStyle(Color.mwMuted)
                        .lineLimit(1)
                        // 0.6 而不是 0.7：这句话在英文下有小 80 个字符，而这一行还要
                        // 容下标题与右侧取值。压到 0.6 是「勉强能读」与「被截断」的
                        // 折中 —— 再小就不如直接截断（截断至少不骗人）。
                        .minimumScaleFactor(0.6)
                        .layoutPriority(-1)
                }
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
