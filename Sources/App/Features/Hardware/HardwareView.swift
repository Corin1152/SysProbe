import SwiftUI

/// 第一屏：设备硬件信息。
struct HardwareView: View {
    @EnvironmentObject private var hardware: HardwareMonitor
    @EnvironmentObject private var optimizer: MemoryOptimizer

    private var snapshot: HardwareSnapshot { hardware.snapshot }

    var body: some View {
        PageScaffold("Hardware", glow: .mwAccent) {
            devicePanel
            cpuPanel
            memoryPanel
            storagePanel
            networkPanel
        }
    }

    // MARK: 设备与系统

    private var devicePanel: some View {
        Panel("Device", systemImage: "iphone") {
            VStack(alignment: .leading, spacing: 12) {
                Metric(caption: "Model",
                       value: snapshot.system.modelIdentifier,
                       size: 20)
                HStack(spacing: 14) {
                    Metric(caption: "System", value: snapshot.system.systemVersion, size: 18)
                    Metric(caption: "Kernel", value: snapshot.system.kernelVersion, size: 18)
                }
                HStack(spacing: 14) {
                    Metric(caption: "Uptime",
                           value: Formatting.duration(snapshot.system.uptime),
                           size: 18)
                    Metric(caption: "Physical memory",
                           value: Formatting.bytes(snapshot.system.physicalMemory),
                           size: 18)
                }
            }
        }
    }

    // MARK: CPU

    private var cpuPanel: some View {
        Panel("CPU", systemImage: "cpu", trailing: Text(verbatim: "\(snapshot.cpu.logicalCores) cores")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: snapshot.cpu.model)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mwMuted)
                    .lineLimit(2)

                HStack(spacing: 14) {
                    Metric(caption: "Usage",
                           value: Formatting.percent(snapshot.cpu.usage * 100),
                           unit: "%",
                           tint: .mwPower(snapshot.cpu.usage * 100),
                           size: 30)
                    Metric(caption: "Physical cores",
                           value: "\(snapshot.cpu.physicalCores)",
                           size: 30)
                    Metric(caption: "Max frequency",
                           value: snapshot.cpu.frequencyMHz > 0 ? "\(snapshot.cpu.frequencyMHz)" : "—",
                           unit: snapshot.cpu.frequencyMHz > 0 ? "MHz" : nil,
                           size: 30)
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
                            BarRow(title: Text(verbatim: "Core \(index)"),
                                   detail: Formatting.percent(load * 100) + "%",
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
                           size: 30)
                    Metric(caption: "Available",
                           value: Formatting.bytes(snapshot.memory.free &+ snapshot.memory.inactive),
                           tint: .mwBattery,
                           size: 30)
                    Metric(caption: "Pressure",
                           value: Formatting.percent(snapshot.memory.usage * 100),
                           unit: "%",
                           tint: snapshot.memory.usage > 0.85 ? .mwDanger : .mwMuted,
                           size: 30)
                }

                BarRow(title: Text("Memory usage"),
                       detail: Formatting.percent(snapshot.memory.usage * 100) + "%",
                       fraction: snapshot.memory.usage,
                       tint: .mwAccent)

                HStack(spacing: 14) {
                    Metric(caption: "Wired", value: Formatting.bytes(snapshot.memory.wired), size: 18)
                    Metric(caption: "Active", value: Formatting.bytes(snapshot.memory.active), size: 18)
                    Metric(caption: "Compressed", value: Formatting.bytes(snapshot.memory.compressed), size: 18)
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
                    Text(verbatim: "\(Formatting.percent(progress * 100))%  ·  \(Formatting.bytes(allocated))")
                        .mwMono(size: 11)
                        .foregroundStyle(Color.mwAccent)
                case .finished:
                    Text("Done").mwMono(size: 11).foregroundStyle(Color.mwBattery)
                default:
                    EmptyView()
                }
            }

            switch optimizer.phase {
            case .running(let progress, _):
                ProgressView(value: progress)
                    .tint(.mwAccent)
            case .finished(let before, let after):
                let delta = Int64(after) - Int64(before)
                HStack(spacing: 14) {
                    Metric(caption: "Before", value: Formatting.bytes(before), size: 18)
                    Metric(caption: "After", value: Formatting.bytes(after), size: 18)
                    Metric(caption: delta >= 0 ? "Released" : "Change",
                           value: Formatting.bytes(UInt64(abs(delta))),
                           tint: delta >= 0 ? .mwBattery : .mwMuted,
                           size: 18)
                }
            case .failed(let reason):
                EmptyNote(text: LocalizedStringResource(stringLiteral: reason),
                          systemImage: "exclamationmark.triangle")
            case .idle:
                EmptyNote(text: "Allocates a large block of memory to force the system to reclaim cached pages, then releases it. It also clears this app's own caches. iOS does not let any app free another app's memory — the kernel does that itself — so treat this as a nudge, not a guarantee.")
            }

            Button {
                optimizer.run()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text(optimizer.phase.isRunning ? "Optimising…" : "Optimise memory")
                }
                .font(.system(size: 14, weight: .semibold))
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
                    Metric(caption: "Used", value: Formatting.bytes(snapshot.storage.used), tint: .mwLoss, size: 28)
                    Metric(caption: "Free", value: Formatting.bytes(snapshot.storage.free), tint: .mwBattery, size: 28)
                }
                BarRow(title: Text("Capacity"),
                       detail: Formatting.percent(snapshot.storage.usage * 100) + "%",
                       fraction: snapshot.storage.usage,
                       tint: .mwLoss)
            }
        }
    }

    // MARK: 网络

    private var networkPanel: some View {
        Panel("Network", systemImage: "wifi",
              trailing: Text(verbatim: snapshot.network.interfaceName)) {
            VStack(alignment: .leading, spacing: 12) {
                Metric(caption: "IPv4 address", value: snapshot.network.ipv4, size: 22)
                HStack(spacing: 14) {
                    Metric(caption: "Download",
                           value: Formatting.rate(snapshot.network.downloadBytesPerSecond),
                           tint: .mwAccent,
                           size: 20)
                    Metric(caption: "Upload",
                           value: Formatting.rate(snapshot.network.uploadBytesPerSecond),
                           tint: .mwWireless,
                           size: 20)
                }
                HStack(spacing: 14) {
                    Metric(caption: "Total received",
                           value: Formatting.bytes(snapshot.network.receivedBytes),
                           size: 18)
                    Metric(caption: "Total sent",
                           value: Formatting.bytes(snapshot.network.sentBytes),
                           size: 18)
                }
            }
        }
    }
}
