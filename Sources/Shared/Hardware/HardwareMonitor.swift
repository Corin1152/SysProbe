import Foundation
import Combine
import Darwin
import UIKit

// MARK: - 快照模型

struct CPUStats: Hashable {
    var model: String = "—"
    var physicalCores: Int = 0
    var logicalCores: Int = 0
    var frequencyMHz: Int = 0
    /// 0…1，整体占用
    var usage: Double = 0
    /// 0…1，每个逻辑核的占用
    var perCore: [Double] = []
}

struct MemoryStats: Hashable {
    var total: UInt64 = 0
    var wired: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    /// 已用 = wired + active + compressed，和 iOS 自己的口径一致
    var used: UInt64 { wired &+ active &+ compressed }
    var usage: Double {
        total == 0 ? 0 : min(1, Double(used) / Double(total))
    }
}

struct StorageStats: Hashable {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var used: UInt64 { total > free ? total - free : 0 }
    var usage: Double {
        total == 0 ? 0 : min(1, Double(used) / Double(total))
    }
}

struct NetworkStats: Hashable {
    var interfaceName: String = "—"
    var ipv4: String = "—"
    var receivedBytes: UInt64 = 0
    var sentBytes: UInt64 = 0
    /// 每秒速率，来自两次采样的差值
    var downloadBytesPerSecond: Double = 0
    var uploadBytesPerSecond: Double = 0
}

struct SystemStats: Hashable {
    var deviceName: String = "—"
    var modelIdentifier: String = "—"
    var systemVersion: String = "—"
    var kernelVersion: String = "—"
    var uptime: TimeInterval = 0
    var physicalMemory: UInt64 = 0
}

struct HardwareSnapshot: Hashable {
    var date: Date = .now
    var cpu = CPUStats()
    var memory = MemoryStats()
    var storage = StorageStats()
    var network = NetworkStats()
    var system = SystemStats()
}

// MARK: - 采样器

/// 每秒采一次 CPU / 内存 / 存储 / 网络 / 系统信息。
///
/// 全部走公开或半公开的 Mach / BSD 接口，只读，不写任何注册表：
/// - CPU 占用：`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，两次采样求差值
/// - 内存分项：`host_statistics64(HOST_VM_INFO64)`
/// - 存储容量：`URLResourceValues`
/// - 网络吞吐：`getifaddrs` 的 `if_data` 字节计数，两次采样求速率
/// - 系统信息：`sysctl` / `uname` / `ProcessInfo`
final class HardwareMonitor: ObservableObject {
    @Published private(set) var snapshot = HardwareSnapshot()

    private var ticker: AnyCancellable?
    private var previousTicks: [UInt64] = []
    private var previousCounters: [String: (rx: UInt64, tx: UInt64, date: Date)] = [:]
    private var lastInterface: String?
    /// 存储容量上一次真正去问文件系统的时间。见 `refresh`。
    private var lastStorageRead: Date = .distantPast
    private var cachedStorage = StorageStats()

    func start() {
        guard ticker == nil else { return }
        refresh()
        // 与 `PowerMonitor.start` 同样的理由：挂在 `.default` 模式上的 `Timer` 会在
        // 滚动期间自动让路，`Task.sleep` 不会。详见那边的注释。
        ticker = Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    func pause() {
        ticker?.cancel()
        ticker = nil
    }

    func refresh() {
        var next = HardwareSnapshot()
        next.date = .now
        next.cpu = Self.readCPU(previous: &previousTicks)
        next.memory = Self.readMemory()
        // 容量一次查询是一次文件系统往返，而数字几分钟都不会变。十秒问一次足够，
        // 中间直接复用上次的结果。
        if next.date.timeIntervalSince(lastStorageRead) > 10 {
            cachedStorage = Self.readStorage()
            lastStorageRead = next.date
        }
        next.storage = cachedStorage
        next.network = Self.readNetwork(previous: &previousCounters, lastInterface: &lastInterface)
        next.system = Self.readSystem()
        snapshot = next
    }

    // MARK: CPU

    /// 型号名、核心数、最高频率。
    ///
    /// 这些出厂就定死，一秒读一次 sysctl 是纯浪费 —— 每读一次是四次 `sysctlbyname`
    /// 加一次查表，而值永远一样。第一次用到时读一遍就够。
    private static let cpuIdentity: (model: String, physicalCores: Int, logicalCores: Int, frequencyMHz: Int) = {
        let machine = sysctlString("hw.machine") ?? ""
        // iOS 沙箱不暴露 `hw.cpufrequency*`，读不到就留 0，界面按「—」显示。
        // 编一个数字出来比留空更糟。
        return (cpuName(machine: machine),
                sysctlInt("hw.physicalcpu") ?? 0,
                sysctlInt("hw.logicalcpu") ?? 0,
                sysctlInt("hw.cpufrequency_max").map { $0 / 1_000_000 } ?? 0)
    }()

    private static func readCPU(previous: inout [UInt64]) -> CPUStats {
        var stats = CPUStats()
        stats.model = cpuIdentity.model
        stats.physicalCores = cpuIdentity.physicalCores
        stats.logicalCores = cpuIdentity.logicalCores
        stats.frequencyMHz = cpuIdentity.frequencyMHz

        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let result = host_processor_info(mach_host_self(),
                                         PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount,
                                         &cpuInfo,
                                         &infoCount)
        guard result == KERN_SUCCESS, let cpuInfo else {
            previous = []
            return stats
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: cpuInfo)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stateCount = Int(CPU_STATE_MAX)
        var ticks: [UInt64] = []
        ticks.reserveCapacity(Int(cpuCount) * stateCount)
        for core in 0..<Int(cpuCount) {
            for state in 0..<stateCount {
                ticks.append(UInt64(cpuInfo[core * stateCount + state]))
            }
        }

        // 第一次采样没有基线，占用一律报 0，只把基线留下。
        guard previous.count == ticks.count else {
            previous = ticks
            stats.perCore = Array(repeating: 0, count: Int(cpuCount))
            return stats
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stateCount
            var busy: UInt64 = 0
            var total: UInt64 = 0
            for state in 0..<stateCount {
                let now = ticks[base + state]
                let before = previous[base + state]
                let delta = now >= before ? now - before : 0
                total &+= delta
                if state != Int(CPU_STATE_IDLE) { busy &+= delta }
            }
            perCore.append(total == 0 ? 0 : Double(busy) / Double(total))
        }
        previous = ticks
        stats.perCore = perCore
        stats.usage = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
        return stats
    }

    // MARK: 内存

    private static func readMemory() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = ProcessInfo.processInfo.physicalMemory

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return stats }

        let page = systemPageSize()
        stats.free = UInt64(vmStats.free_count) &* page
        stats.active = UInt64(vmStats.active_count) &* page
        stats.inactive = UInt64(vmStats.inactive_count) &* page
        stats.wired = UInt64(vmStats.wire_count) &* page
        stats.compressed = UInt64(vmStats.compressor_page_count) &* page
        return stats
    }

    // MARK: 存储

    private static func readStorage() -> StorageStats {
        var stats = StorageStats()
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return stats }
        if let total = values.volumeTotalCapacity {
            stats.total = UInt64(total)
        }
        if let available = values.volumeAvailableCapacityForImportantUsage {
            stats.free = UInt64(available)
        } else if let available = values.volumeAvailableCapacity {
            stats.free = UInt64(available)
        }
        return stats
    }

    // MARK: 网络

    private static func readNetwork(
        previous: inout [String: (rx: UInt64, tx: UInt64, date: Date)],
        lastInterface: inout String?
    ) -> NetworkStats {
        var stats = NetworkStats()
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return stats }
        defer { freeifaddrs(addresses) }

        let now = Date()
        var candidates: [(name: String, ipv4: String, rx: UInt64, tx: UInt64)] = []

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = nullTerminatedString(at: entry.pointee.ifa_name)
            // 只要真实的网络接口，跳过虚拟隧道
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ipv4 = nullTerminatedString(host)
                var rx: UInt64 = 0
                var tx: UInt64 = 0
                if let data = entry.pointee.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                    rx = UInt64(networkData.ifi_ibytes)
                    tx = UInt64(networkData.ifi_obytes)
                }
                candidates.append((name, ipv4, rx, tx))
            }
        }

        // 优先沿用上一次选中的接口，避免多接口之间来回跳导致速率失真。
        let chosen = candidates.first { $0.name == lastInterface }
            ?? candidates.max { $0.rx + $0.tx < $1.rx + $1.tx }
        guard let chosen else { return stats }

        stats.interfaceName = chosen.name
        stats.ipv4 = chosen.ipv4
        stats.receivedBytes = chosen.rx
        stats.sentBytes = chosen.tx
        lastInterface = chosen.name

        if let before = previous[chosen.name] {
            let seconds = now.timeIntervalSince(before.date)
            if seconds > 0.2 {
                let down = chosen.rx >= before.rx ? Double(chosen.rx - before.rx) : 0
                let up = chosen.tx >= before.tx ? Double(chosen.tx - before.tx) : 0
                stats.downloadBytesPerSecond = down / seconds
                stats.uploadBytesPerSecond = up / seconds
            }
        }
        previous[chosen.name] = (chosen.rx, chosen.tx, now)
        return stats
    }

    // MARK: 系统

    /// 机型、系统版本、内核版本、物理内存 —— 同样是一秒读一次而从不改变的东西。
    private static let systemIdentity: SystemStats = {
        var stats = SystemStats()
        stats.deviceName = UIDevice.current.name
        stats.modelIdentifier = machineIdentifier()
        stats.systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        stats.kernelVersion = sysctlString("kern.osrelease") ?? "—"
        stats.physicalMemory = ProcessInfo.processInfo.physicalMemory
        return stats
    }()

    private static func readSystem() -> SystemStats {
        var stats = systemIdentity
        stats.uptime = ProcessInfo.processInfo.systemUptime
        return stats
    }

    // MARK: sysctl 辅助

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return nullTerminatedString(buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    /// 芯片名。
    ///
    /// iOS 上拿不到 CPU 型号：`machdep.cpu.brand_string` 是 macOS 专有的 sysctl，
    /// 沙箱里读不到。硬件信息 App 里这一栏要的是「这台机器装的是哪颗芯片」，那就只能
    /// 按机型标识推 —— 一张静态表而已，认不出来的机型老老实实显示机型标识本身，
    /// 不猜。设备族限定为 iPhone（TARGETED_DEVICE_FAMILY = 1），所以只列 iPhone。
    private static func cpuName(machine: String) -> String {
        let table: [String: String] = [
            "iPhone8,1": "Apple A9", "iPhone8,2": "Apple A9", "iPhone8,4": "Apple A9",
            "iPhone9,1": "Apple A10 Fusion", "iPhone9,2": "Apple A10 Fusion",
            "iPhone9,3": "Apple A10 Fusion", "iPhone9,4": "Apple A10 Fusion",
            "iPhone10,1": "Apple A11 Bionic", "iPhone10,2": "Apple A11 Bionic",
            "iPhone10,3": "Apple A11 Bionic", "iPhone10,4": "Apple A11 Bionic",
            "iPhone10,5": "Apple A11 Bionic", "iPhone10,6": "Apple A11 Bionic",
            "iPhone11,2": "Apple A12 Bionic", "iPhone11,4": "Apple A12 Bionic",
            "iPhone11,6": "Apple A12 Bionic", "iPhone11,8": "Apple A12 Bionic",
            "iPhone12,1": "Apple A13 Bionic", "iPhone12,3": "Apple A13 Bionic",
            "iPhone12,5": "Apple A13 Bionic", "iPhone12,8": "Apple A13 Bionic",
            "iPhone13,1": "Apple A14 Bionic", "iPhone13,2": "Apple A14 Bionic",
            "iPhone13,3": "Apple A14 Bionic", "iPhone13,4": "Apple A14 Bionic",
            "iPhone14,2": "Apple A15 Bionic", "iPhone14,3": "Apple A15 Bionic",
            "iPhone14,4": "Apple A15 Bionic", "iPhone14,5": "Apple A15 Bionic",
            "iPhone14,6": "Apple A15 Bionic", "iPhone14,7": "Apple A15 Bionic",
            "iPhone14,8": "Apple A15 Bionic",
            "iPhone15,2": "Apple A16 Bionic", "iPhone15,3": "Apple A16 Bionic",
            "iPhone15,4": "Apple A16 Bionic", "iPhone15,5": "Apple A16 Bionic",
            "iPhone16,1": "Apple A17 Pro", "iPhone16,2": "Apple A17 Pro",
            "iPhone17,1": "Apple A18 Pro", "iPhone17,2": "Apple A18 Pro",
            "iPhone17,3": "Apple A18", "iPhone17,4": "Apple A18", "iPhone17,5": "Apple A18",
        ]
        if let name = table[machine] { return name }
        return machine.isEmpty ? "—" : machine
    }

    private static func machineIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return Mirror(reflecting: info.machine).children.reduce(into: "") { result, element in
            guard let byte = element.value as? Int8, byte != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(byte))))
        }
    }
}
