import SwiftUI

/// 第一屏：设备硬件信息。
///
/// **这个视图本身不观察任何采样对象。** 四张卡片各自观察 `HardwareMonitor` 里自己
/// 那一块（见 `HardwareCard`），优化按钮自己观察 `MemoryOptimizer`。原因见 `body`
/// 上那段说明：`HardwareMonitor` 每秒发布一次，观察它的视图整棵重算。
struct HardwareView: View {
    /// 右上角齿轮的回调，由 `RootView` 给 —— 见 `PageScaffold` 上那条注释：
    /// 传动作，不传 `AppState`。
    let openSettings: @MainActor () -> Void

    /// 第一屏所有**读数**的字号。
    ///
    /// 原来这一页混着 18 / 20 / 22 / 28 / 30 五档，同一个面板里两个数字不一样大，
    /// 看上去像是排版漏了。现在统一到一档，并把原来那几个偏大的缩下来 ——
    /// 缩，不是把小的放大：18 pt 与别的页（功率、适配器）的行高也合得上。
    ///
    /// 标签（`mwCaption`，11 pt）、芯片型号那一行（13 pt）与内存优化那两行等宽日志
    /// （`mwMono`，11 pt）是另一个层级，不在此列。
    ///
    /// `fileprivate` 而不是 `private`：内存优化那一块现在单独成类型
    /// （`OptimizeSection`，同文件），它也要用同一档字号 —— 两处不一致的话，
    /// 同一张卡片里会出现两种大小的读数。
    fileprivate static let valueSize: CGFloat = 18

    /// 内存卡片专用的一档。**比 `valueSize` 小**（2026-10-15）：内存卡三列
    /// 并排，列宽最窄，数值带上「 GB」后缀在 18pt 下偶尔换行；降到 15pt
    /// 留出余量。其余卡片（设备/CPU/存储）列数少，维持 18 不动。
    fileprivate static let memoryValueSize: CGFloat = 15

    var body: some View {
        PageScaffold("Hardware", glow: .mwAccent, openSettings: openSettings) {
            DeviceCard()
            CPUCard()
            MemoryCard()
            StorageCard()
        }
        // **这个视图不再观察 `hardware`，也不再观察 `optimizer`。**
        //
        // `hardware` 每秒发布一次，而本视图原来是它的观察者，于是**整页每秒重算
        // 一遍** —— 包括 `PageScaffold` 那层导航栈与滚动容器、四张卡片的全部结构，
        // 而真正在变的只有 CPU 那 8 条占用条和几行读数。用户报的「CPU 频率条
        // 不跟手」「页面动画变肉」正来自这里：整页重建摊在滚动与切换的同一批帧里。
        //
        // 现在把观察面拆到四张卡片里（各看自己那一块），本视图只剩「把五块拼起来」，
        // 每秒采样不再让它重算。`OptimizeSection` 同理（0.0.61 起就不在这里）。
    }

    // MARK: - 四张卡片（各自观察自己那一块）

    // 注意：这里开始到 `StorageCard` 结束为止都**仍然在 `HardwareView` 内部** ——
    // 它们是嵌套类型，不是文件顶层类型。`HardwareView` 的闭合括号在 StorageCard
    // 之后；`OptimizeSection` 则刻意留在 `HardwareView` 外面（同文件顶层私有类型）。

    /// 设备卡片：机型 / 系统 / 内核 / 运行时长 / 物理内存。
    ///
    /// 这一组里**只有「运行时长」是每秒变的**，其余四项出厂就定死。
    private struct DeviceCard: View {
        @EnvironmentObject private var hardware: HardwareMonitor

        // 整个 content 只用一次 `hardware.snapshot`：EnvironmentObject 的
        // wrappedValue 每解一次都要走一遍环境查找，散着写会重复付这个钱。
        var body: some View {
            let snap = hardware.snapshot
            Panel("Device", systemImage: "iphone") {
                VStack(alignment: .leading, spacing: 12) {
                    Metric(caption: "Model",
                           value: snap.system.modelIdentifier,
                           size: HardwareView.valueSize)
                    HStack(spacing: 14) {
                        Metric(caption: "System", value: snap.system.systemVersion, size: HardwareView.valueSize)
                        Metric(caption: "Kernel", value: snap.system.kernelVersion, size: HardwareView.valueSize)
                    }
                    HStack(spacing: 14) {
                        Metric(caption: "Uptime",
                               value: Formatting.duration(snap.system.uptime),
                               size: HardwareView.valueSize)
                        Metric(caption: "Physical memory",
                               value: Formatting.bytes(snap.system.physicalMemory),
                               size: HardwareView.valueSize)
                    }
                }
            }
        }
    }

    /// CPU 卡片：占用、物理核数、当前频率、每核占用条。
    ///
    /// **这是最贵的一张**：8 条每核占用条加一条频率读数，全都每秒变。
    private struct CPUCard: View {
        @EnvironmentObject private var hardware: HardwareMonitor

        private var snapshot: HardwareSnapshot { hardware.snapshot }

        /// 计数是文案的一部分（"8 cores" / "8 核"），所以走本地化插值而不是 verbatim。
        var trailing: Text? {
            Text("\(snapshot.cpu.logicalCores) cores")
        }

        var body: some View {
            Panel("CPU", systemImage: "cpu", trailing: trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: snapshot.cpu.model)
                    .font(AppFont.text(13, weight: .medium))
                    .foregroundStyle(Color.mwMuted)
                    .lineLimit(2)

                HStack(spacing: 14) {
                    Metric(caption: "Usage",
                           value: Formatting.number(snapshot.cpu.usage * 100),
                           unit: "%",
                           tint: .mwPower(snapshot.cpu.usage * 100),
                           size: HardwareView.valueSize)
                    Metric(caption: "Physical cores",
                           value: "\(snapshot.cpu.physicalCores)",
                           size: HardwareView.valueSize)
                    Metric(caption: "Frequency",
                           value: snapshot.cpu.frequencyMHz > 0 ? "\(snapshot.cpu.frequencyMHz)" : "—",
                           unit: snapshot.cpu.frequencyMHz > 0 ? "MHz" : nil,
                           size: HardwareView.valueSize)
                }

                if !snapshot.cpu.perCore.isEmpty {
                    Divider().overlay(Color.mwCardStroke)
                    Text("Per-core load")
                        .mwCaption()
                    // 核心多了就折成两列，免得一条条排到屏幕外。
                    let columns = snapshot.cpu.perCore.count > 8 ? 2 : 1
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                                             count: columns),
                              spacing: 8) {
                        ForEach(Array(snapshot.cpu.perCore.enumerated()), id: \.offset) { index, load in
                            BarRow(title: Text("Core \(index)"),
                                   detail: Formatting.percent(load * 100),
                                   fraction: load,
                                   tint: .mwPower(load * 100))
                        }
                    }
                }
            }
            }
        }
    }

    /// 内存卡片。优化按钮也在这里（它在内存面板里，见 0.0.59 起的布局）。
    private struct MemoryCard: View {
        @EnvironmentObject private var hardware: HardwareMonitor

        private var snapshot: HardwareSnapshot { hardware.snapshot }
        var trailing: Text? {
            Text(verbatim: Formatting.bytes(snapshot.memory.total))
        }

        var body: some View {
            Panel("Memory", systemImage: "memorychip", trailing: trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Metric(caption: "Used",
                           value: Formatting.bytes(snapshot.memory.used),
                           tint: .mwAccent,
                           size: HardwareView.memoryValueSize)
                    Metric(caption: "Available",
                           value: Formatting.bytes(snapshot.memory.available),
                           tint: .mwBattery,
                           size: HardwareView.memoryValueSize)
                    // 与 CPU-X 的 `Mem Free` 同一个口径（纯 `free_count`），
                    // 拿它去跟 CPU-X 对才对得上；「Available」比它多算了
                    // purgeable + speculative，所以天生更大。见 `MemoryStats`。
                    Metric(caption: "Free",
                           value: Formatting.bytes(snapshot.memory.free),
                           tint: .mwMuted,
                           size: HardwareView.memoryValueSize)
                }

                BarRow(title: Text("Memory usage"),
                       detail: Formatting.percent(snapshot.memory.usage * 100),
                       fraction: snapshot.memory.usage,
                       tint: snapshot.memory.usage > 0.85 ? .mwDanger : .mwAccent)

                HStack(spacing: 14) {
                    Metric(caption: "Wired", value: Formatting.bytes(snapshot.memory.wired), size: HardwareView.memoryValueSize)
                    Metric(caption: "Active", value: Formatting.bytes(snapshot.memory.active), size: HardwareView.memoryValueSize)
                    Metric(caption: "Compressed", value: Formatting.bytes(snapshot.memory.compressed), size: HardwareView.memoryValueSize)
                }

                Divider().overlay(Color.mwCardStroke)
                OptimizeSection { hardware.refresh() }
            }
            }
        }
    }

    /// 存储卡片。
    private struct StorageCard: View {
        @EnvironmentObject private var hardware: HardwareMonitor

        private var snapshot: HardwareSnapshot { hardware.snapshot }
        var trailing: Text? {
            Text(verbatim: Formatting.bytes(snapshot.storage.total))
        }

        var body: some View {
            Panel("Storage", systemImage: "internaldrive", trailing: trailing) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        Metric(caption: "Used", value: Formatting.bytes(snapshot.storage.used), tint: .mwLoss, size: HardwareView.valueSize)
                    Metric(caption: "Free", value: Formatting.bytes(snapshot.storage.free), tint: .mwBattery, size: HardwareView.valueSize)
                }
                BarRow(title: Text("Capacity"),
                       detail: Formatting.percent(snapshot.storage.usage * 100),
                       fraction: snapshot.storage.usage,
                       tint: .mwLoss)
            }
            }
        }
    }
}


/// 「内存优化」那一个按钮。
///
/// ── 为什么只剩一个按钮（2026-10-14 按要求精简）────────────────────────────────
///
/// 原来这里是三段：标题 + 百分比与已分配量、结果三档读数（Before / After /
/// Released）、按钮。按用户要求全部去掉，只留按钮本身。理由不只是「少几行字」：
///
///   · **结论归内存面板管** —— 优化一结束就会重读一次，「可用」涨了多少在 Memory
///     卡片上当场能看到，这里再摆一遍是重复；
///   · `MemoryOptimizer` 每 5% 发布一次进度，而它原来就挂在本页里 —— 那二十次发布
///     会把四张卡片一起拖着重算。现在受影响的只有这一个按钮。
///
/// ── 为什么它自己不知道「优化结束要刷新内存读数」──────────────────────────────
///
/// 那件事属于页面：优化一结束要立刻重读一次内存（面板本身一秒一采，而「可用」的
/// 峰值窗口只有那几秒，等下一个整秒采样时数值已经落回去了）。所以这里只把「结束了」
/// 这件事用回调抛出去，由 `MemoryCard` 决定做什么。
private struct OptimizeSection: View {

@EnvironmentObject private var optimizer: MemoryOptimizer

/// 一轮优化结束（成功或失败）时调用。
let onFinished: @MainActor () -> Void

/// 当前进度（0…1）。只在 running 态有意义。
private var runningProgress: Double {
    if case .running(let progress, _) = optimizer.phase { return progress }
    return 0
}

var body: some View {
    Button {
        optimizer.run()
    } label: {
        // 整键作进度条（2026-10-15 定稿，替代「中间细线」方案）：
        // 轨道 = accent 32% —— 视觉上正好就是原 disabled 的灰化观感，
        // 所以运行中不再需要额外的变淡处理；
        // 填充 = accent 实色，按 `MemoryOptimizer` 的 progress（每 5% 发布一次）
        // 从左向右扫过整键；「优化中…」文字浮于填充之上。
        // 空闲态 = accent 实色，与原 `.borderedProminent` 无差别。
        // 填充手画而不用 ProgressView：tinted 底色上轨道/填充色不可控。
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
            Text(optimizer.phase.isRunning ? "Optimising…" : "Optimise memory")
        }
        .font(AppFont.text(14, weight: .semibold))
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.mwAccent.opacity(optimizer.phase.isRunning ? 0.32 : 1))
                if optimizer.phase.isRunning {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.mwAccent)
                            .frame(width: max(16, geo.size.width * runningProgress))
                            .animation(.linear(duration: 0.3), value: runningProgress)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        )
    }
    .buttonStyle(.plain)
    .disabled(optimizer.phase.isRunning)
    .onChange(of: optimizer.phase) { phase in
        switch phase {
        case .finished, .failed: onFinished()
        default: break
        }
    }
}
}
