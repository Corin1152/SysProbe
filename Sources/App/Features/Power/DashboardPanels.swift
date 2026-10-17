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

    /// 电池卡片那一半静态信息的来源。
    ///
    /// 2026-10-15 之前它在 `ChargeControlPanels` 里（那是另一个分段）。两张电池卡片
    /// 合并成一张之后，这个依赖跟着搬了过来 —— 见 `batteryPanel`。
    @EnvironmentObject private var charge: ChargeControlService

    private var snapshot: PowerSnapshot { monitor.snapshot }
    private var plugged: Bool { snapshot.externalConnected }

    /// 光晕不在这一层：它属于页面外壳，由 `PowerView.glow` 给。
    ///
    /// ── 为什么是 `Group` 而不是 `VStack` ────────────────────────────────────
    ///
    /// 这一层的内容会被 `PowerView` 放进 `PageScaffold` 的 `LazyVStack`。`Group`
    /// 不产生布局容器，子视图会被展平成那个 `LazyVStack` 的直接元素 —— 每张卡片
    /// 因此仍是独立的懒加载单元。换成 `VStack` 就只剩一个元素，六张卡片
    /// （含功率环那层 `Canvas`）会在进页面那一帧全部建出来。
    var body: some View {
        Group {
            heroPanel
            if monitor.thermalState.isThrottling { throttleBanner }
            batteryPanel
            powerPathPanel
        }
    }

    /// 功率环的 tint。
    ///
    /// **与 `PowerView` 的整页光晕是同一个值** —— 它调的就是那个函数。
    /// 原来这两处在 `DashboardView` 里本来就是同一个 `glowColor`；拆成两个类型之后
    /// 如果各写一份，环的颜色会与背景对不上，看起来像坏了，而且不报任何错。
    private var ringTint: Color {
        PowerGlow.color(throttling: monitor.thermalState.isThrottling,
                        wirelessInput: snapshot.isWirelessInput,
                        externalConnected: plugged)
    }

    // MARK: Hero

    private var heroPanel: some View {
        // ── 2026-10-17：这一张单独缩小（按要求）────────────────────────────────
        //
        // 三处一起收，都是这一张自己的尺寸，不影响别的卡片：
        //   · 卡片内边距 14 → 12（`Panel` 的 `padding` 参数）；
        //   · 环与药丸之间 14 → 10、环上方留白 4 → 2；
        //   · 功率环 232 → 204。
        //
        // 只压环不压内边距的话，卡片两侧的空白会显得更宽 —— 环变小了、卡片却没
        // 变，看起来是「没居中」而不是「变小了」。
        Panel(padding: 12) {
            VStack(spacing: 10) {
                PowerRing(inputWatts: monitor.headline?.watts,
                          batteryWatts: plugged && snapshot.inputWatts != nil ? snapshot.batteryWatts : nil,
                          fullScale: fullScale,
                          caption: monitor.headline?.caption,
                          tint: ringTint,
                          size: 204)
                    .padding(.top, 2)

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

    /// 电池：实时读数 + 静态参数，**一张卡片**。
    ///
    /// ── 2026-10-15：与「充电控制」分段那张电池卡片合并 ────────────────────────
    ///
    /// 两张卡片说的是同一个东西的两面 —— 一张是「现在怎么样」（电量、电芯电压 /
    /// 电流 / 温度），一张是「这块电池是什么」（健康度、循环次数、容量、序列号）。
    /// 原来它们分在页面的两处，中间还隔着一次分段切换：想看「循环次数」要滚两次屏。
    ///
    /// **重复的两行去掉了。** 充电控制那张里的「Current」与「Voltage」就是这里的
    /// 「Cell current」与「Cell voltage」，只是取数路径不同（一个走守护进程给的电池
    /// 字典 `BatteryInfo`，一个走 `PowerSnapshot`）。按要求保留这一份、去掉那一份 ——
    /// 同一张卡片上出现两个同名读数是最容易让人怀疑「哪个才是对的」的写法。
    ///
    /// 「Boot voltage」**留着**：它不是电芯电压，而是开机那一刻记下的电池电压，
    /// 回答的是「这块电池这一轮开机时是什么状态」。与上面那个读数不是同一个量。
    private var batteryPanel: some View {
        Panel("Battery", systemImage: "battery.100",
              // 这个时刻来自守护进程给的电池字典，与功率那半边不是同一个源 ——
              // 它是「静态参数」那一半的新鲜度，标在卡片右上角正好。
              trailing: charge.battery.updateTime.map {
                  Text($0.formatted(date: .omitted, time: .standard))
              }) {
            // 12 → 10（2026-10-16，压卡片高度）：上半截与分隔线之间。
            VStack(spacing: 10) {
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

                // 一条分隔线把「现在怎么样」和「这块电池是什么」分开。它与
                // `MemoryCard` 里分隔读数与优化按钮用的是同一条线。
                Divider().overlay(Color.mwCardStroke)

                // 10 → 8（2026-10-16，压卡片高度）：六行之间共五处间隔，收 10 pt。
                //
                // 2026-10-17：这六行（健康度及以下）的值字号单独收到 14 —— 见
                // `ValueRow.valueSize`。标签不动（13），所以是「13 标签 / 14 值」。
                // 同一天值颜色也改成与标签同一种淡灰（`ValueRow.valueColor`）：
                // 这六项是静态参数，不是那三个实时读数，不该跟它们抢颜色。
                VStack(spacing: 8) {
                    ValueRow(title: "Health",
                             value: battery.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                             valueSize: 14)
                    ValueRow(title: "Cycle count",
                             value: battery.cycleCount.map { String($0) } ?? "—",
                             valueSize: 14)
                    ValueRow(title: "Design capacity",
                             value: battery.designCapacity.map { "\($0) mAh" } ?? "—",
                             valueSize: 14)
                    ValueRow(title: "Full charge capacity",
                             value: battery.nominalChargeCapacity.map { "\($0) mAh" } ?? "—",
                             valueSize: 14)
                    // 两个电压都是毫伏，跟原版前端一样除以 1000 显示。
                    ValueRow(title: "Boot voltage",
                             value: battery.bootVoltage.map { String(format: "%.2f V", Double($0) / 1000) } ?? "—",
                             valueSize: 14)
                    // ── 2026-10-16：Serial 不再走等宽 ──────────────────────────
                    //
                    // 它以前是唯一一个 `monospaced: true` 的行，走 `.monospaced`
                    // design（SF Mono）—— 与上面五行（`.default`）不是同一套字形，
                    // 同一列里混两种字形，看着就是「某一行跟别的不像」。
                    // 用户要求整列统一，这里去掉那个参数。
                    ValueRow(title: "Serial", value: battery.serial ?? "—", valueSize: 14)
                }
            }
        }
    }

    private var battery: BatteryInfo { charge.battery }

    // MARK: Power path（2026-10-15：广播档位与「线缆与连接」都并进来了）

    /// 供电路径 + 线缆与连接 + 当前协商到的档位，**一张卡片**。
    ///
    /// ── 2026-10-14：为什么把「广播档位」并进来 ────────────────────────────────
    ///
    /// 两张卡片答的是同一个问题的两半：这张说「进来多少、存下多少、路上丢了多少」，
    /// 档位那张说「充电器允许进来多少」。分开摆的时候，读的人要自己在脑子里把
    /// 「17 W 的档位」和「实际进来 14 W」对上 —— 而这两件事本来就该挨着看。
    ///
    /// ── 2026-10-15：为什么把「线缆与连接」也并进来，以及为什么常驻 ─────────────
    ///
    /// 那张卡片（`Cable and connection`）说的是**这条链路本身好不好**：通路电阻、
    /// 压降、路上丢了多少、取用了多少。它与上面四格是同一件事的两端 ——
    /// 一端是「进来多少」，一端是「为什么少了」。三张卡片说同一件事，收成一张。
    ///
    /// **整块内容现在常驻。** 原来它在未插充电器时画的是一句
    /// 「Plug in a charger to measure the path.」，等于把卡片变成一条提示；
    /// 现在读数照画，取不到的那一格显示「—」（`Metric` 对占位符有专门的处理：
    /// 字号缩到 0.7、颜色压灰，读起来就是「读不到」而不是「是 0」）。
    /// 只有一种情况仍然给整块提示：**无线充电** —— 那没有线缆、也没有输入电流
    /// 传感器，是物理上测不了，与「没插电」不是一回事。
    ///
    /// ── 为什么档位只显示命中的那一档 ──────────────────────────────────────────
    ///
    /// 充电器会广播一整张档位表（5V / 9V / 12V / 15V / 20V…），但**此刻真正在用**
    /// 的只有一档。把整张表列出来，用户得自己在里面找出带勾的那一行才知道「现在跑在
    /// 哪一档」；而这个页面要回答的正是「现在」。所以只显示 `negotiatedProfile`，
    /// 一行读完。
    ///
    /// 完整档位表不是没有价值 —— 它回答的是「这个充电器还能给多少」，
    /// 但那是个「换充电器之前」的问题，不是这一页主读数旁边该摆的东西。
    ///
    /// 这一行同样常驻：**没插充电器时它显示 `—` 与 `0 W`**（不是整块消失）。
    /// 0 W 是准确的 —— 没有合同，这一档能给的就是 0；左边留 `—` 而不是
    /// 「0.0 V × 0.00 A」，因为那会被读成「充电器报了一个 0 V 的档位」。
    private var powerPathPanel: some View {
        Panel("Power path", systemImage: "arrow.triangle.branch",
              // 百分号先落成 `String` 再插值，于是键是 `%@ of adapter` 而不是
              // `%lld% of adapter` —— 后者会把一个字面量 `%` 塞进格式串里，
              // 交给 `String(format:)` 解析是未定义行为。文案表也按 `%@` 写。
              trailing: snapshot.adapterUtilisation.map { utilisation in
                  let percent = "\(Int(utilisation * 100))%"
                  return Text("\(percent) of adapter")
              }) {
            // 12 → 10（2026-10-16，压卡片高度）：三段之间共两处间隔，收 4 pt。
            VStack(spacing: 10) {
                // ── 第一段：这一秒的电 ─────────────────────────────────────────
                //
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

                // ── 第二段：线缆与连接（2026-10-15 从同名卡片并进来）──────────────
                //
                // 分隔线在这里是必需的：上面四格是「进来多少」，这四格是
                // 「路上怎么了」，字号与灰度完全一样，不加线会被读成同一个读数组的
                // 续行。下面档位那一段同理。
                Divider().overlay(Color.mwCardStroke)

                // 四格读数在未插电时：**能算的报 0，算不了的报「—」**。
                //
                //   · 压降、路上损耗、取用量三项都正比于电流 —— 没电流就是 0，
                //     这是准确读数；
                //   · **通路电阻与电流无关**，0 mΩ 会被读成「这条线是理想导线」，
                //     是错的。所以那一格没测到就是「—」。
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Path resistance",
                           value: resistance.map { String(format: "%.0f", $0.milliohms) } ?? "—",
                           unit: resistance == nil ? nil : "mΩ",
                           tint: resistance.map { resistanceTint($0.milliohms) } ?? .primary,
                           footnote: resistance.map {
                               $0.fitted ? Text("fitted over the whole contract")
                                         : Text("from one sample")
                           },
                           size: 22)
                    Metric(caption: "Voltage drop",
                           value: voltageDropText,
                           unit: "V",
                           tint: isSagging ? .mwDanger : .primary,
                           // Copy with a measurement inside it, so the sentence
                           // is extracted and the number is not.
                           footnote: snapshot.usbInputVoltage.map { Text("\(String(format: "%.2f V", $0)) at the port") },
                           size: 22)
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Lost in the path",
                           value: pathLossText,
                           unit: "W",
                           tint: .mwLoss,
                           footnote: Text("at the current draw"),
                           size: 22)
                    Metric(caption: "Taking",
                           value: inputCurrentText,
                           unit: "%",
                           tint: (snapshot.inputCurrentUtilisation ?? 1) < 0.6 ? .mwLoss : .primary,
                           footnote: Text("of the current on offer"),
                           size: 22)
                }
                if snapshot.isWirelessInput || snapshot.adapterIsWireless {
                    EmptyNote(text: "Wireless charging has no cable and no input-current sensor, so there is nothing to measure.",
                              systemImage: "wave.3.right")
                }

                // ── 第三段：谈成的合同（常驻，未插电时 0）─────────────────────────
                //
                // 上面两段是读数（会动），这一段是协商结果（插着的时候基本不动）——
                // 放在一起而不加线的话，读的人会以为它也每秒在跳。
                Divider().overlay(Color.mwCardStroke)

                negotiatedSection
            }
        }
    }

    /// 谈成的合同那一段。三种状态，**都不留空**：
    ///
    ///   · 有协商结果 → `negotiatedRow(profile)`；
    ///   · 插着电但充电器没广播档位表（旧式 USB-A、部分无线充电板）→ 一句说明；
    ///   · 没插充电器 → `negotiatedRow(.zero)`，即 `0.0 V × 0.00 A` 与 `0 W`。
    @ViewBuilder
    private var negotiatedSection: some View {
        if let profile = snapshot.negotiatedProfile {
            negotiatedRow(profile)
        } else if plugged {
            EmptyNote(text: "This adapter published no PD profile menu. Legacy USB-A chargers and some wireless pads report only a single voltage and current.")
        } else {
            negotiatedRow(.zero)
        }
    }

    /// 当前命中的那一档 —— 一行，**不带单选框**。
    ///
    /// 原来这里是整张档位表，每行左边一个圆圈，命中的那个画成实心。只留一档之后，
    /// 「选中」这个状态就没有信息量了：整张卡片上只有它一个，再画个实心圆点等于
    /// 用图形把「就是它」重复一遍。
    ///
    /// 版式改成两段：左边是这一档的**形状**（电压 × 电流，充电器说的），
    /// 右边是它的**乘积**（瓦特，这一档能给出多少）。左右对齐之后，
    /// 「17 W」和上面「From charger 14.2 W」的差就是这一档还剩多少没用上。
    ///
    /// 参数是**非可选**的：没插充电器时调用点传 `.zero`，画出来就是
    /// `0.0 V × 0.00 A` 与 `0 W`（2026-10-15 按用户要求改，原来这里画的是 `—`）。
    /// 用空档而不是破折号，是为了让这一行在插拔前后的**格式完全一致** ——
    /// 破折号看起来像「读不到」，而这里的事实是「就是 0」。
    ///
    /// **保留这一行而不是整块换掉**，是因为它在这一页的位置本身就是信息
    /// （「这一档现在能给多少」）—— 整块消失会让卡片矮一截，插拔充电器时高度跟着跳。
    private func negotiatedRow(_ profile: PDProfile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: profile.label)
                .mwMono(size: 13, weight: .semibold)
            Spacer(minLength: 8)
            Text(String(format: "%.0f W", profile.watts))
                .mwReadout(size: 16, weight: .semibold)
                .foregroundStyle(Color.mwAccent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mwAccent.opacity(0.12))
        )
    }

    /// 压降。未插电时是准确的 0.00 V（没电流就没有压降）；插着但读不到才报「—」。
    private var voltageDropText: String {
        if let drop = snapshot.inputVoltageDropVolts { return String(format: "%.2f", drop) }
        return plugged ? "—" : "0.00"
    }

    /// 路上丢掉的功率 = I²R。电阻或电流任一项读不到就没得算 ——
    /// 未插电时电流本来就是 0，所以直接报 0。
    private var pathLossText: String {
        guard let resistance, let current = snapshot.usbInputCurrent else {
            return plugged ? "—" : "0"
        }
        return Formatting.watts(resistance.milliohms / 1000 * current * current)
    }

    /// 取用了充电器「能给的电流」的百分之多少。
    private var inputCurrentText: String {
        if let utilisation = snapshot.inputCurrentUtilisation {
            return String(format: "%.0f", utilisation * 100)
        }
        return plugged ? "—" : "0"
    }

    private var efficiencyTint: Color {
        guard let efficiency = snapshot.conversionEfficiency else { return .primary }
        return efficiency >= 85 ? .mwBattery : (efficiency >= 70 ? .mwLoss : .mwDanger)
    }

    // MARK: 线缆的读数（2026-10-15：从「Cable and connection」卡片迁入）

    /// The resistance to show, and whether it came from the fit or from one sample.
    /// The fit wins when it exists: it needs no reference voltage, so it is the
    /// better number whenever the current has moved enough to produce one.
    ///
    /// ── 为什么两种测法都要有 ────────────────────────────────────────────────
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
    /// the current, so there is nothing to fit a slope to. Hence both, with the
    /// readout's footnote saying which one it is showing.
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
