import SwiftUI

/// 第一屏：设备硬件信息。
struct HardwareView: View {
    @EnvironmentObject private var hardware: HardwareMonitor
    @EnvironmentObject private var optimizer: MemoryOptimizer

    private var snapshot: HardwareSnapshot { hardware.snapshot }

    /// 第一屏所有**读数**的字号。
    ///
    /// 原来这一页混着 18 / 20 / 22 / 28 / 30 五档，同一个面板里两个数字不一样大，
    /// 看上去像是排版漏了。现在统一到一档，并把原来那几个偏大的缩下来 ——
    /// 缩，不是把小的放大：18 pt 与别的页（功率、适配器）的行高也合得上。
    ///
    /// 标签（`mwCaption`，11 pt）、芯片型号那一行（13 pt）与内存优化那两行等宽日志
    /// （`mwMono`，11 pt）是另一个层级，不在此列。
    private static let valueSize: CGFloat = 18

    var body: some View {
        PageScaffold("Hardware", glow: .mwAccent) {
            devicePanel
            cpuPanel
            memoryPanel
            storagePanel
        }
        // 优化一结束就立刻重读一次内存。
        //
        // 面板本身是一秒一采的，而「可用」的峰值窗口只有那几秒 —— 等下一个整秒采样的
        // 时候，数值已经开始落回去了，看起来就像什么都没发生。
        .onChange(of: optimizer.phase) { phase in
            switch phase {
            case .finished, .failed: hardware.refresh()
            default: break
            }
        }
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
                optimizeSection
            }
        }
    }

    private var optimizeSection: some View {
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
            case .running(let progress, _):
                ProgressView(value: progress)
                    .tint(.mwAccent)
            case .finished(let before, let after, _):
                let delta = Int64(after) - Int64(before)
                HStack(spacing: 14) {
                    Metric(caption: "Before", value: Formatting.bytes(before), size: Self.valueSize)
                    Metric(caption: "After", value: Formatting.bytes(after), size: Self.valueSize)
                    Metric(caption: delta >= 0 ? "Released" : "Change",
                           value: Formatting.bytes(UInt64(abs(delta))),
                           tint: delta >= 0 ? .mwBattery : .mwMuted,
                           size: Self.valueSize)
                }
            case .failed(let reason):
                // `reason` 是运行期才知道的键（`MemoryOptimizer.Phase.failed`），
                // 走 `EmptyNote(key:)` 直接查表，不经过 SwiftUI 的解析。
                EmptyNote(key: reason, systemImage: "exclamationmark.triangle")
            case .idle:
                // 那段说明文字按用户要求去掉了：它把这块区域撑得很高，想说的其实只有
                // 一句「这是一次推动，不是保证」。按钮标题加上下方的
                // Before / After / Released，已经把做了什么、结果如何说清楚了。
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
