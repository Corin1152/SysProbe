import SwiftUI

/// 「电源」页的分段 1 —— 功率。原先是底部第 2 个分页。
///
/// 2026-10-11 起它不再是一个独立分页，而是 `PowerHubView` 里的一个分段：
/// 外壳（导航栈、画布、光晕、标题、分段控件）全部由 `PowerHubView` 提供，
/// 这里只负责**滚动容器 + 面板**。
///
/// 这样拆有一个必须守住的地方：`isVisible` 还是靠 `onAppear` / `onDisappear` 维护。
/// 它决定实时曲线要不要每秒刷新 —— 分段被切走时视图会被销毁，`onDisappear` 照常触发，
/// 所以「离开这一屏还在采样」不会发生。改动这里时别把这两个回调挪到外层。
struct DashboardPanels: View {
    @EnvironmentObject private var monitor: PowerMonitor

    /// 这一段是不是正在显示。
    ///
    /// 以前读的是 `AppState.selectedTab`，但那意味着这一页得观察 `AppState`。
    /// 换成本地状态，由 `onAppear` / `onDisappear` 维护，观察面就干净了。
    @State private var isVisible = false

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var plugged: Bool { snapshot.externalConnected }

    // 光晕不在这一层：它属于页面外壳，由 `PowerHubView.glow` 按分段给。
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                heroPanel
                if monitor.thermalState.isThrottling { throttleBanner }
                batteryPanel
                breakdownPanel
                livePanel
                sessionPanel
                if !monitor.sensorsAvailable { sensorNote }
            }
            .padding(.horizontal, 16)
            // 顶上的 4 减到 2：分段控件已经给了 8 的下边距，再叠一层 4 就偏松了。
            .padding(.top, 2)
            .padding(.bottom, 24)
            .mwContainerWidth()
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    /// 功率环的 tint。
    ///
    /// **与 `PowerHubView` 的整页光晕是同一个值** —— 它调的就是那个函数。
    /// 原来这两处在 `DashboardView` 里本来就是同一个 `glowColor`；拆成两个类型之后
    /// 如果各写一份，环的颜色会与背景对不上，看起来像坏了，而且不报任何错。
    private var ringTint: Color {
        PowerSegment.glow(for: .draw,
                          throttling: monitor.thermalState.isThrottling,
                          wirelessInput: snapshot.isWirelessInput,
                          externalConnected: plugged)
    }

    // MARK: Hero

    private var heroPanel: some View {
        Panel {
            VStack(spacing: 14) {
                PowerRing(inputWatts: monitor.headline?.watts,
                          batteryWatts: plugged && snapshot.inputWatts != nil ? snapshot.batteryWatts : nil,
                          fullScale: fullScale,
                          caption: monitor.headline?.caption,
                          tint: ringTint)
                    .padding(.top, 4)

                FlowRow(spacing: 6) {
                    Pill(text: Text(verbatim: snapshot.statusText),
                         systemImage: plugged ? "bolt.fill" : "battery.50",
                         tint: plugged ? .mwAccent : .mwMuted)
                    if snapshot.isWirelessInput {
                        Pill(text: Text("MagSafe"), systemImage: "wave.3.right", tint: .mwWireless)
                    }
                    if snapshot.holdIsInferred {
                        Pill(text: Text("inferred"), systemImage: "questionmark.circle", tint: .mwLoss)
                    }
                    if monitor.lowPowerMode || snapshot.lowPowerMode {
                        Pill(text: Text("Low Power"), systemImage: "battery.25", tint: .mwLoss)
                    }
                    Pill(text: Text(verbatim: monitor.thermalState.title),
                         systemImage: monitor.thermalState.symbol,
                         tint: thermalTint)
                }
            }
        }
    }

    /// True while charging wirelessly with no way to measure what comes in.
    private var wirelessInputUnmeasurable: Bool {
        plugged && snapshot.inputWatts == nil && snapshot.isWirelessInput
    }



    /// Full scale is the adapter's nameplate when it declares one, so the dial
    /// shows how much of the charger is actually being used.
    private var fullScale: Double {
        guard plugged else { return 15 }
        // With no input reading the dial is showing battery-side watts, which never
        // exceed what the adapter can supply — but a low wireless ceiling would put
        // the needle near full for an ordinary trickle, so keep a floor under it.
        if snapshot.inputWatts == nil { return max(snapshot.adapterRatedWatts ?? 25, 10) }
        return max(snapshot.adapterRatedWatts ?? 30, 5)
    }

    private var thermalTint: Color {
        switch monitor.thermalState {
        case .nominal: return .mwBattery
        case .fair: return .mwLoss
        default: return .mwDanger
        }
    }

    private var throttleBanner: some View {
        Panel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "thermometer.high")
                    .font(AppFont.text(18, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Thermal throttling active")
                        .font(AppFont.text(14, weight: .semibold))
                    Text(verbatim: monitor.thermalState.chargingEffect)
                        .font(.caption)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    // 拆成两段而不是把 `Text` 嵌进插值：嵌进去的键会是
                    // `%@ for %@` 且其中一个参数是 `Text`，格式串怎么解析没有
                    // 保证；拆开后只是一句带 `%@` 的普通文案，中文语序也顺。
                    HStack(spacing: 4) {
                        Text(verbatim: monitor.thermalState.title)
                        Text("for \(Formatting.duration(Date.now.timeIntervalSince(monitor.thermalStateSince)))")
                    }
                    .mwMono(size: 10)
                    .foregroundStyle(Color.mwMuted)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwDanger.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: Battery

    private var batteryPanel: some View {
        Panel("Battery", systemImage: "battery.100") {
            VStack(spacing: 12) {
                if let percent = snapshot.percent {
                    BarRow(title: Text("Charge level"),
                           detail: "\(percent)%",
                           fraction: Double(percent) / 100,
                           tint: percent <= 20 ? .mwDanger : .mwBattery,
                           subtitle: snapshot.timeRemainingMinutes.map { minutes in
                               // Two whole sentences rather than a fragment glued to a
                               // number: word order around the duration is not the same
                               // in every language.
                               let remaining = Formatting.minutesRemaining(minutes)
                               return snapshot.isCharging ? Text("full in \(remaining)")
                                                          : Text("empty in \(remaining)")
                           })
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Cell voltage",
                           value: snapshot.batteryVoltage.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "V", size: 20)
                    Metric(caption: "Cell current",
                           value: snapshot.batteryCurrent.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "A",
                           tint: (snapshot.batteryCurrent ?? 0) > 0 ? .mwBattery : .primary,
                           size: 20)
                    Metric(caption: "Cell temp",
                           value: snapshot.batteryTemperature.map { String(format: "%.1f", $0) } ?? "—",
                           unit: "°C",
                           tint: snapshot.batteryTemperature.map { Color.mwTemperature($0) } ?? .primary,
                           size: 20)
                }
            }
        }
    }

    // MARK: Breakdown

    private var breakdownPanel: some View {
        Panel("Power path", systemImage: "arrow.triangle.branch",
              // 百分号先落成 `String` 再插值，于是键是 `%@ of adapter` 而不是
              // `%lld% of adapter` —— 后者会把一个字面量 `%` 塞进格式串里，
              // 交给 `String(format:)` 解析是未定义行为。文案表也按 `%@` 写。
              trailing: snapshot.adapterUtilisation.map { utilisation in
                  let percent = "\(Int(utilisation * 100))%"
                  return Text("\(percent) of adapter")
              }) {
            VStack(spacing: 12) {
                // 四项读数在未插电时都按 **0** 显示，而不是「—」。
                //
                // 「—」在四格并排的面板里显得像「这一格坏了」；而 0 W / 0 % 是准确的
                // 读数 —— 确实没有功率进来、确实没有损耗。电芯那格本来就是这个行为，
                // 四格现在一致。
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "From charger",
                           value: Formatting.watts(snapshot.inputWatts ?? 0),
                           unit: "W", tint: .mwAccent, size: 22)
                    Metric(caption: "Into cell",
                           value: Formatting.watts(max(snapshot.batteryWatts ?? 0, 0)),
                           unit: "W", tint: .mwBattery, size: 22)
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Lost as heat",
                           value: Formatting.watts(snapshot.conversionLossWatts ?? 0),
                           unit: "W", tint: .mwLoss, size: 22)
                    Metric(caption: "Efficiency",
                           value: String(format: "%.0f", snapshot.conversionEfficiency ?? 0),
                           unit: "%",
                           tint: efficiencyTint,
                           size: 22)
                }
                if let input = snapshot.inputWatts, input > 0.2, let battery = snapshot.batteryWatts, battery > 0 {
                    PowerFlowBar(input: input, toBattery: battery)
                }
                if wirelessInputUnmeasurable {
                    EmptyNote(text: "Charging wirelessly. The charge IC exposes the coil's voltage but no current to pair with it, so the power coming in cannot be measured — only what reaches the cell. The figure the charger reports about itself is a ceiling, not a reading, and does not move.",
                              systemImage: "wave.3.right")
                }
            }
        }
    }

    private var efficiencyTint: Color {
        guard let efficiency = snapshot.conversionEfficiency else { return .primary }
        return efficiency >= 85 ? .mwBattery : (efficiency >= 70 ? .mwLoss : .mwDanger)
    }

    // MARK: Live

    private var livePanel: some View {
        Panel("Last 3 minutes", systemImage: "waveform.path.ecg",
              trailing: Text("\(monitor.live.count) samples")) {
            VStack(alignment: .leading, spacing: 8) {
                // 没在看这一页时只占位、不建图：`TabView` 会把切走的分页留在视图树里，
                // 采样一发布这张图就跟着重算 —— 它是重渲染里最贵的一块。占位高度与图
                // 一致（`LivePowerChart` 默认 130），切回来时布局不跳。
                if isVisible {
                    LivePowerChart(samples: monitor.live)
                } else {
                    Color.clear.frame(height: 130)
                }
                HStack(spacing: 14) {
                    LegendDot(color: .mwAccent, text: "From charger")
                    LegendDot(color: .mwBattery, text: "Into battery", dashed: true)
                }
            }
        }
    }

    // MARK: Session

    private var sessionPanel: some View {
        Panel("This charge", systemImage: "sum",
              trailing: monitor.currentSession.map { Text(verbatim: Formatting.duration($0.duration)) } ?? Text("idle")) {
            if monitor.currentSession != nil {
                let totals = monitor.sessionTotals
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Delivered",
                               value: totals.measuredInputWattHours.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "Wh", tint: .mwAccent, size: 20)
                        Metric(caption: "Stored",
                               value: String(format: "%.2f", totals.batteryWattHours),
                               unit: "Wh", tint: .mwBattery, size: 20)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Into cell",
                               value: String(format: "%.0f", totals.batteryMilliAmpHours),
                               unit: "mAh", size: 20)
                        Metric(caption: "Round trip",
                               value: totals.efficiencyPercent.map { String(format: "%.0f", $0) } ?? "—",
                               unit: "%", tint: .mwLoss, size: 20)
                    }
                }
            } else {
                EmptyNote(text: "Plug in to start measuring. Energy is integrated from the live sensors while the app is open, and saved to History when you unplug.",
                          systemImage: "powerplug")
            }
        }
    }

    private var sensorNote: some View {
        Panel("Sensors", systemImage: "sensor") {
            EmptyNote(text: "No HID power sensors were found. On the simulator this is expected — IOKit reads the Mac's battery and the phone's PMU sensors do not exist. Run on the device for real numbers.",
                      systemImage: "exclamationmark.triangle")
        }
    }
}

/// The input-versus-stored split, drawn as one bar so the loss has a size.
struct PowerFlowBar: View {
    let input: Double
    let toBattery: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let stored = CGFloat(min(toBattery / input, 1))
                HStack(spacing: 2) {
                    Capsule()
                        .fill(Theme.gradient(.mwBattery))
                        .frame(width: max(2, geometry.size.width * stored - 1))
                    Capsule()
                        .fill(Theme.gradient(.mwLoss).opacity(0.7))
                }
            }
            .frame(height: 8)
            HStack {
                Text("stored in cell").font(.caption2).foregroundStyle(Color.mwBattery)
                Spacer()
                Text("system load + losses").font(.caption2).foregroundStyle(Color.mwLoss)
            }
        }
    }
}

struct LegendDot: View {
    let color: Color
    let text: LocalizedStringKey
    var dashed: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            // One stroked line with a dash pattern, rather than two capsules —
            // the second capsule used to be offset out of its own frame and
            // landed on top of the label.
            LegendLine()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5,
                                                  lineCap: .round,
                                                  dash: dashed ? [3.5, 3.5] : []))
                .frame(width: 16, height: 2.5)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.mwMuted)
        }
    }
}

nonisolated private struct LegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A wrapping row of pills. `LazyVGrid` cannot do variable-width items on iOS 17,
/// so the layout is done by hand.
nonisolated struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: width, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
