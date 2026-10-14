import SwiftUI

/// 「电源」页的分段 1 —— 功率。
///
/// ── 2026-10-14：适配器分段并进来了 ────────────────────────────────────────────
///
/// 「适配器」原本是与它并列的一个分段。去掉「实际 vs 额定」「握手信息」「实时供电轨」
/// 三张卡片之后，那边剩下的两张 —— 「广播档位」与「线缆与连接」—— 说的都是
/// 「这条充电链路本身怎么样」，与这一页的「功率从哪来、去了哪」是同一个问题的两面，
/// 于是并到这里，分段栏从三格收成两格（功率 / 充电控制）。
///
/// 一并去掉的还有三张：**采样曲线图**（这一页最贵的一块，每秒重绘）、
/// **本次充电**（充电过程中的累计量几乎不动）、**无传感器提示**（只在模拟器上出现，
/// 真机永远读得到 HID 传感器）。散热横幅保留 —— 它是真实会发生、且与充电直接相关的
/// 一条告警。
struct DashboardPanels: View {
    @EnvironmentObject private var monitor: PowerMonitor

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
                profilesPanel
                connectionPanel
            }
            .padding(.horizontal, 16)
            // 顶上的 4 减到 2：分段控件已经给了 8 的下边距，再叠一层 4 就偏松了。
            .padding(.top, 2)
            .padding(.bottom, 24)
            .mwContainerWidth()
        }
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

    // MARK: Profiles（2026-10-14 从「适配器」分段迁入）

    /// 适配器广播的 PD 档位表，当前生效的那一档带勾。
    ///
    /// 未插电时给一句空态而不是把「没有广播档位表」那句显示出来 —— 后者描述的是
    /// 「充电器不上报」，没接充电器时说这句话是错的。
    private var profilesPanel: some View {
        Panel("Advertised profiles", systemImage: "list.bullet.rectangle",
              trailing: snapshot.adapterProfiles.isEmpty ? nil : Text(verbatim: "\(snapshot.adapterProfiles.count)")) {
            if !plugged {
                EmptyNote(text: "Plug in a charger to read its advertised profiles.",
                          systemImage: "powerplug")
            } else if snapshot.adapterProfiles.isEmpty {
                EmptyNote(text: "This adapter published no PD profile menu. Legacy USB-A chargers and some wireless pads report only a single voltage and current.")
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.adapterProfiles) { profile in
                        ProfileRow(profile: profile,
                                   isActive: profile.index == snapshot.negotiatedProfile?.index)
                    }
                }
            }
        }
    }

    // MARK: Connection（2026-10-14 从「适配器」分段迁入）

    /// What the cable and the two plugs are costing.
    ///
    /// The cable itself cannot be identified from the phone: while charging the
    /// phone is the sink, so it is the charger that reads the cable's e-marker, and
    /// none of that reaches iOS — `IOPortTransportComponentCCUSBPDSOPp` does not even
    /// exist there. What is measurable is the consequence, and there are two ways to
    /// get at it, which fail in opposite conditions:
    ///
    /// - `PathResistanceMeter` fits the port voltage against the current and needs no
    ///   reference voltage, but needs the current to have moved.
    /// - `PowerSnapshot.inputPathMilliohms` divides the drop from the negotiated
    ///   voltage by the current, which answers immediately but trusts a contract
    ///   figure that is a ceiling rather than a reading.
    ///
    /// The bad-cable case is exactly where the fit goes quiet: a collapsed rail pins
    /// the current, so there is nothing to fit a slope to. Hence both, with the panel
    /// saying which one it is showing.
    private var connectionPanel: some View {
        Panel("Cable and connection", systemImage: "cable.connector.horizontal",
              trailing: monitor.pathResistance.map { Text("\($0.sampleCount) samples") }) {
            if !plugged {
                EmptyNote(text: "Plug in a charger to measure the path.",
                          systemImage: "powerplug")
            } else if let resistance {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Path resistance",
                               value: String(format: "%.0f", resistance.milliohms),
                               unit: "mΩ",
                               tint: resistanceTint(resistance.milliohms),
                               footnote: resistance.fitted
                                   ? Text("fitted over the whole contract")
                                   : Text("from one sample"),
                               size: 22)
                        Metric(caption: "Voltage drop",
                               value: snapshot.inputVoltageDropVolts.map { String(format: "%.2f", $0) } ?? "—",
                               unit: "V",
                               tint: isSagging ? .mwDanger : .primary,
                               // Copy with a measurement inside it, so the sentence
                               // is extracted and the number is not.
                               footnote: snapshot.usbInputVoltage.map { Text("\(String(format: "%.2f V", $0)) at the port") },
                               size: 22)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Lost in the path",
                               value: snapshot.usbInputCurrent.map {
                                   Formatting.watts(resistance.milliohms / 1000 * $0 * $0)
                               } ?? "—",
                               unit: "W",
                               tint: .mwLoss,
                               footnote: Text("at the current draw"),
                               size: 22)
                        Metric(caption: "Taking",
                               value: snapshot.inputCurrentUtilisation.map { String(format: "%.0f", $0 * 100) } ?? "—",
                               unit: "%",
                               tint: (snapshot.inputCurrentUtilisation ?? 1) < 0.6 ? .mwLoss : .primary,
                               footnote: Text("of the current on offer"),
                               size: 22)
                    }
                    // 这里原本还有两段解释文字：`resistanceVerdict(...)`（按阻值分档给
                    // 一句「正常 / 偏高」的判词）与 `provenance`（这个数字是拟合出来的
                    // 还是单次采样算的）。2026-10-11 按要求去掉 —— 四行读数本身已经把
                    // 「通路电阻 / 压降 / 损失 / 占用量」说清楚了，下面再堆三小段灰字
                    // 只会把卡片拉长。
                    //
                    // 2026-10-14 又去掉了卡片顶部那段压降告警（`sagBanner`）：它是
                    // 一整块红底长句，而「压降偏低」这件事下面那个读数已经用变色表达
                    // 了，两者叠在一起是同一个信号的两次广播。
                    //
                    // 唯一损失的是「这个数是拟合的还是单次采样的」这个出处提示，
                    // 它仍然在「通路电阻」那个读数的脚注里（`fitted over the whole
                    // contract` / `from one sample`），只是不再展开解释。
                }
            } else if snapshot.isWirelessInput || snapshot.adapterIsWireless {
                EmptyNote(text: "Wireless charging has no cable and no input-current sensor, so there is nothing to measure.",
                          systemImage: "wave.3.right")
            } else {
                EmptyNote(text: "Waiting for the phone to draw enough to measure a drop. Below about 150 mA there is nothing to divide.",
                          systemImage: "chart.xyaxis.line")
            }
        }
    }

    /// The resistance to show, and whether it came from the fit or from one sample.
    /// The fit wins when it exists: it needs no reference voltage, so it is the
    /// better number whenever the current has moved enough to produce one.
    private var resistance: (milliohms: Double, fitted: Bool)? {
        if let estimate = monitor.pathResistance { return (estimate.milliohms, true) }
        if let single = snapshot.inputPathMilliohms { return (single, false) }
        return nil
    }

    /// The snapshot knows the electrical signature; heat, a hold and a nearly-full
    /// battery are the innocent explanations for the same low draw, and only the
    /// monitor knows about those.
    private var isSagging: Bool {
        guard snapshot.isInputSagging, !monitor.thermalState.isThrottling,
              !snapshot.isChargingOnHold else { return false }
        return (snapshot.percent ?? 0) <= 90
    }

    /// Deliberately coarse bands. The number includes the charger's output impedance
    /// and both sets of contacts, so a precise threshold would be false precision —
    /// what is being separated here is "unremarkable" from "worth swapping the cable".
    private func resistanceTint(_ milliohms: Double) -> Color {
        switch milliohms {
        case ..<200: .mwBattery
        case ..<400: .primary
        default: .mwLoss
        }
    }
}

/// One advertised PD profile. A row rather than a plain `Text` so the active one can
/// carry the accent tint and the filled radio.
struct ProfileRow: View {
    let profile: PDProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(AppFont.text(13))
                .foregroundStyle(isActive ? Color.mwAccent : Color.mwMuted.opacity(0.5))
            Text(verbatim: profile.label)
                .mwMono(size: 13, weight: isActive ? .semibold : .regular)
            Spacer()
            Text(String(format: "%.0f W", profile.watts))
                .mwReadout(size: 14, weight: .semibold)
                .foregroundStyle(isActive ? Color.mwAccent : Color.mwMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.mwAccent.opacity(0.12) : Color.mwMuted.opacity(0.06))
        )
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
