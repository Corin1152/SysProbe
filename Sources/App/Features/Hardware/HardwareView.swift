import SwiftUI

/// 第一屏：设备硬件信息。
struct HardwareView: View {
    @EnvironmentObject private var hardware: HardwareMonitor

    /// 右上角齿轮的回调，由 `RootView` 给 —— 见 `PageScaffold` 上那条注释：
    /// 传动作，不传 `AppState`。
    let openSettings: @MainActor () -> Void

    /// 这一页是不是当前选中的分页。由 `RootView` 按 `selectedTab` 给。
    /// 非当前分页会**停止求值内容** —— 否则它会跟着每秒一次的采样一直重算，
    /// 见 `DeferredContent`。
    let isActive: Bool

    private var snapshot: HardwareSnapshot { hardware.snapshot }

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

    var body: some View {
        PageScaffold("Hardware", glow: .mwAccent, isActive: isActive, openSettings: openSettings) {
            devicePanel
            cpuPanel
            memoryPanel
            storagePanel
        }
        // **`optimizer` 的观察不在这里** —— 它整块搬进了 `OptimizeSection`。
        // 本视图只观察 `hardware`（一秒一次，本来就要显示实时读数），
        // 而优化进度一轮要变几十次：留在这里的话，那几十次会各自把整页重算一遍。
    }

    // MARK: 设备与系统

    private var devicePanel: some View {
        Panel("Device", systemImage: "iphone") {
            VStack(alignment: .leading, spacing: 12) {
                Metric(caption: "Model",
                       value: snapshot.system.modelIdentifier,
                       size: Self.valueSize)
                HStack(spacing: 14) {
                    Metric(caption: "System", value: snapshot.system.systemVersion, size: Self.valueSize)
                    Metric(caption: "Kernel", value: snapshot.system.kernelVersion, size: Self.valueSize)
                }
                HStack(spacing: 14) {
                    Metric(caption: "Uptime",
                           value: Formatting.duration(snapshot.system.uptime),
                           size: Self.valueSize)
                    Metric(caption: "Physical memory",
                           value: Formatting.bytes(snapshot.system.physicalMemory),
                           size: Self.valueSize)
                }
            }
        }
    }

    // MARK: CPU

    private var cpuPanel: some View {
        // 计数是文案的一部分（"8 cores" / "8 核"），所以走本地化插值而不是 verbatim；
        // 芯片型号是硬件名，照原样显示。
        Panel("CPU", systemImage: "cpu", trailing: Text("\(snapshot.cpu.logicalCores) cores")) {
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
                           size: Self.valueSize)
                    Metric(caption: "Physical cores",
                           value: "\(snapshot.cpu.physicalCores)",
                           size: Self.valueSize)
                    Metric(caption: "Frequency",
                           value: snapshot.cpu.frequencyMHz > 0 ? "\(snapshot.cpu.frequencyMHz)" : "—",
                           unit: snapshot.cpu.frequencyMHz > 0 ? "MHz" : nil,
                           size: Self.valueSize)
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

    // MARK: 内存

    private var memoryPanel: some View {
        Panel("Memory", systemImage: "memorychip",
              trailing: Text(verbatim: Formatting.bytes(snapshot.memory.total))) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Metric(caption: "Used",
                           value: Formatting.bytes(snapshot.memory.used),
                           tint: .mwAccent,
                           size: Self.valueSize)
                    Metric(caption: "Available",
                           value: Formatting.bytes(snapshot.memory.available),
                           tint: .mwBattery,
                           size: Self.valueSize)
                    // 与 CPU-X 的 `Mem Free` 同一个口径（纯 `free_count`），
                    // 拿它去跟 CPU-X 对才对得上；「Available」比它多算了
                    // purgeable + speculative，所以天生更大。见 `MemoryStats`。
                    Metric(caption: "Free",
                           value: Formatting.bytes(snapshot.memory.free),
                           tint: .mwMuted,
                           size: Self.valueSize)
                }

                BarRow(title: Text("Memory usage"),
                       detail: Formatting.percent(snapshot.memory.usage * 100),
                       fraction: snapshot.memory.usage,
                       tint: snapshot.memory.usage > 0.85 ? .mwDanger : .mwAccent)

                HStack(spacing: 14) {
                    Metric(caption: "Wired", value: Formatting.bytes(snapshot.memory.wired), size: Self.valueSize)
                    Metric(caption: "Active", value: Formatting.bytes(snapshot.memory.active), size: Self.valueSize)
                    Metric(caption: "Compressed", value: Formatting.bytes(snapshot.memory.compressed), size: Self.valueSize)
                }

                Divider().overlay(Color.mwCardStroke)
                // 优化那一块**单独成视图**：它观察 `MemoryOptimizer`，而进度一轮要变
                // 几十次。挂在 `HardwareView` 里的时候，每变一次整页都要重算一遍 ——
                // 而那几十次正好落在用户盯着进度条的那几秒里。详见 `OptimizeSection`。
                OptimizeSection { hardware.refresh() }
            }
        }
    }

    // MARK: 存储

    private var storagePanel: some View {
        Panel("Storage", systemImage: "internaldrive",
              trailing: Text(verbatim: Formatting.bytes(snapshot.storage.total))) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Metric(caption: "Used", value: Formatting.bytes(snapshot.storage.used), tint: .mwLoss, size: Self.valueSize)
                    Metric(caption: "Free", value: Formatting.bytes(snapshot.storage.free), tint: .mwBattery, size: Self.valueSize)
                }
                BarRow(title: Text("Capacity"),
                       detail: Formatting.percent(snapshot.storage.usage * 100),
                       fraction: snapshot.storage.usage,
                       tint: .mwLoss)
            }
        }
    }

    // MARK: 网络
    //
    // 这一页原来最下方还有一张 Network 卡片（接口地址、实时上下行、累计流量）。
    // 按用户要求去掉了：这一页的定位是「设备硬件」，而网络是链路状态、不是硬件；
    // 何况实时上下行只有盯着看才有意义，放在第一屏既占高度又要一秒一刷。
    //
    // `HardwareMonitor` 里对应的网络采样（`readNetwork` / `interfaceCounters` /
    // `ipv4Addresses`）在 0.0.27 一并删掉了 —— 视图没了之后它就没有消费方，
    // 每秒一次 `sysctl(NET_RT_IFLIST2)` 加一次 `getifaddrs` 纯属浪费。
    // 要恢复看 git 历史；`NetworkKind` 仍在（WakeService 依赖它）。
}

/// 「内存优化」那一块：进度、结果、按钮。
///
/// ── 为什么单独成类型 ────────────────────────────────────────────────────────
///
/// 它观察 `MemoryOptimizer`，而一轮优化的进度要变**几十次**（每分配一块就报一次）。
/// 挂在 `HardwareView` 里的时候，每变一次整页都要重算 —— 而那几十次正好落在用户
/// 盯着进度条的那几秒里，看起来就是「进度条一格一格地卡」。
///
/// 独立出来之后，重算范围缩到这一块：百分比与已分配量的那一行、结果三档读数、
/// 一个按钮。页面上那四个面板（含 8 条每核占用条）一次都不再跟着动。
///
/// ── 为什么没有进度条（2026-10-14）───────────────────────────────────────────
///
/// 按用户要求去掉了 `ProgressView`，只保留百分比数字与已分配量。理由是它把这一块
/// **从「几十行里变一行」拖成「一直在动」**：`ProgressView.value` 每收一次进度就会
/// 走一遍自己的动画与轨迹重绘，而进度一轮要发 20 次（5% 一档）；百分比数字是文本，
/// 一转就过，成本低一个量级。
///
/// ── 为什么它自己不知道「优化结束要刷新内存读数」──────────────────────────────
///
/// 那件事属于页面：优化一结束要立刻重读一次内存（面板本身一秒一采，而「可用」的
/// 峰值窗口只有那几秒，等下一个整秒采样时数值已经落回去了）。所以这里只把「结束了」
/// 这件事用回调抛出去，由 `HardwareView` 决定做什么。
private struct OptimizeSection: View {

    @EnvironmentObject private var optimizer: MemoryOptimizer

    /// 一轮优化结束（成功或失败）时调用。
    let onFinished: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Memory optimisation").mwCaption()
                Spacer(minLength: 8)
                switch optimizer.phase {
                case .running(let progress, let allocated):
                    Text(verbatim: "\(Formatting.percent(progress * 100))  ·  \(Formatting.bytes(allocated))")
                        .mwMono(size: 11)
                        .foregroundStyle(Color.mwAccent)
                case .finished(_, _, let allocated):
                    // 这一轮**实际**分配出去的量。和下面 Before / After 的差值分开摆：
                    // 前者是「顶了多大的压力」，后者是「真的逼出来多少」——
                    // 两个都摆出来，才不会把「尽力了但系统没吐」读成「什么都没干」。
                    HStack(spacing: 4) {
                        Text("Allocated")
                        Text(verbatim: Formatting.bytes(allocated))
                    }
                    .mwMono(size: 11)
                    .foregroundStyle(Color.mwBattery)
                default:
                    EmptyView()
                }
            }

            switch optimizer.phase {
            case .finished(let before, let after, _):
                let delta = Int64(after) - Int64(before)
                HStack(spacing: 14) {
                    Metric(caption: "Before", value: Formatting.bytes(before), size: HardwareView.valueSize)
                    Metric(caption: "After", value: Formatting.bytes(after), size: HardwareView.valueSize)
                    Metric(caption: delta >= 0 ? "Released" : "Change",
                           value: Formatting.bytes(UInt64(abs(delta))),
                           tint: delta >= 0 ? .mwBattery : .mwMuted,
                           size: HardwareView.valueSize)
                }
            case .failed(let reason):
                // `reason` 是运行期才知道的键（`MemoryOptimizer.Phase.failed`），
                // 走 `EmptyNote(key:)` 直接查表，不经过 SwiftUI 的解析。
                EmptyNote(key: reason, systemImage: "exclamationmark.triangle")
            default:
                // `.running`（进度百分比与已分配量已经在上面那一行显示）与 `.idle`
                // 都留空。原来这里 `.running` 会画一条 `ProgressView`，
                // 2026-10-14 按用户要求去掉，理由见类型头。
                EmptyView()
            }

            Button {
                optimizer.run()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text(optimizer.phase.isRunning ? "Optimising…" : "Optimise memory")
                }
                .font(AppFont.text(14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mwAccent)
            .disabled(optimizer.phase.isRunning)
        }
        .onChange(of: optimizer.phase) { phase in
            switch phase {
            case .finished, .failed: onFinished()
            default: break
            }
        }
    }
}
