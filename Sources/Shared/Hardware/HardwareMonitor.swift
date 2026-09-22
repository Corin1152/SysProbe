import Foundation
import Combine
import Darwin
import UIKit

// MARK: - 快照模型

struct CPUStats: Hashable {
    var model: String = "—"
    var physicalCores: Int = 0
    var logicalCores: Int = 0
    /// 界面显示的主频（MHz）。
    ///
    /// **是实测值**，见 `CPUFrequency` 与 `CPUFrequencyProbe.c`：iOS 不给沙箱 App 读
    /// 主频的接口，所以在一段**周期数已知**的汇编循环上量时间反推。探针测不出、或结果
    /// 落在可信窗口之外时，回落成机型表里的标称主频。机型认不出来时为 0，界面显示「—」。
    var frequencyMHz: Int = 0
    /// 该机型芯片的标称主频（MHz）。只作参照与探针的校验基准，界面不直接显示。
    var nominalFrequencyMHz: Int = 0
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
    /// 内核随时可以丢弃的页（`purgeable_count`）。
    var purgeable: UInt64 = 0
    /// 预读进来、随时可以丢掉的页（`speculative_count`）。
    var speculative: UInt64 = 0

    /// 可用 = free + purgeable + speculative，也就是**内核此刻就能拿出来**给新分配的页。
    ///
    /// 刻意**不含 `inactive`** —— 这一条是这一版最重要的改动，值得写清楚。
    ///
    /// inactive 里的页多数确实可回收，但内核回收它们的同时就把 free 顶上去了：两者之和
    /// 在「逼出缓存」前后几乎不变（我们交还的那几百兆进了 free，而被顶掉的缓存本来就
    /// 在 inactive 里）。把它算进「可用」，优化前后读出来就是同一个数 ——
    /// 那正是「优化完已用/可用都没变化」的由来。所以这里看的是**此刻真能用的页**，
    /// 不是「理论上可回收的总量」。
    ///
    /// CPU-X 的内存清理报的也是 `Mem Free`（空闲内存），口径一致。
    ///
    /// `MemoryReclaimer.memoryPools()` 用的是同一套口径，两处必须一致，
    /// 否则优化报出来的数字跟面板对不上。
    var available: UInt64 { free &+ purgeable &+ speculative }

    /// 已用 = 总量 − 可用。与「可用」互补，两者相加恒等于总量 ——
    /// 这是「已用 / 可用」这一对指标在别处的一贯含义（macOS 活动监视器也是这么算的）。
    ///
    /// 下面 Wired / Active / Compressed 是**具名分项**，不是「已用」的全部：
    /// 差额落在 inactive / speculative 上。三个具名分项不该被读成「已用」的构成。
    var used: UInt64 { total > available ? total - available : 0 }
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

/// 承载流量的那条链路。
///
/// 存在的理由是**优先级**：iPhone 插着 SIM 卡时 `pdp_ip0` 也一直是 up 的、也一直有
/// IPv4 地址，所以「有没有地址」区分不出 Wi-Fi 和蜂窝；而按累计字节数挑同样会挑错 ——
/// 后台同步、推送常常悄悄走蜂窝，累计量比 Wi-Fi 还大。规则应当是确定的：
/// 连着 Wi-Fi 就显示 Wi-Fi，Wi-Fi 断了才轮到蜂窝。
nonisolated enum NetworkKind: Hashable, Sendable {
    case wifi
    case cellular

    /// 数字越小越优先。
    var priority: Int {
        switch self {
        case .wifi: return 0
        case .cellular: return 1
        }
    }

    /// 由接口名反推链路类型。认不出来的返回 nil，调用方直接跳过
    /// （虚拟隧道 `utun*`、AirDrop 的 `awdl0` 等都走这里）。
    init?(interfaceName: String) {
        if interfaceName.hasPrefix("en") {
            self = .wifi
        } else if interfaceName.hasPrefix("pdp_ip") {
            self = .cellular
        } else {
            return nil
        }
    }
}

struct NetworkStats: Hashable {
    /// 当前这条链路是 Wi-Fi 还是蜂窝。没有可用接口时为 nil。
    var kind: NetworkKind?
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
/// - 网络吞吐：`sysctl(NET_RT_IFLIST2)` 的 64 位字节计数，两次采样求速率
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
    private var tick = 0
    /// 实测主频（MHz）。`nil` 表示还没测到，界面回落成机型表的标称值。
    private var measuredFrequencyMHz: Int?
    /// 探针一次要占住一条核约 15–20 ms，同一时间只允许跑一次。
    private var frequencyProbeInFlight = false
    /// 探针跑的队列。它不碰 UI，只把最后那个 `Int?` 送回主 actor。
    private let frequencyQueue = DispatchQueue(label: "com.corin.sysprobe.cpufrequency",
                                               qos: .userInitiated)

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
        tick += 1
        // 实测主频每三秒一次。
        //
        // 探针要起线程、热身、再跑三轮计测，合计 15–20 ms 的满速忙循环。一秒一次是白
        // 烧电：频率不会那么快变，而三秒一次的代价不到 1% 的单核占用。
        if tick % 3 == 1 {
            refreshFrequencyIfNeeded()
        }

        var next = HardwareSnapshot()
        next.date = .now
        next.cpu = Self.readCPU(previous: &previousTicks)
        next.cpu.nominalFrequencyMHz = Self.cpuIdentity.nominalFrequencyMHz
        // 探针的结果优先；没测到（或结果不可信）就用机型表的标称值兜底。
        next.cpu.frequencyMHz = measuredFrequencyMHz ?? Self.cpuIdentity.nominalFrequencyMHz
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

    /// 型号名、核心数、标称主频。出厂就定死，第一次用到时读一遍就够 ——
    /// 一秒读一次 sysctl 是纯浪费，而值永远一样。
    ///
    /// **标称主频这一项以前是唯一的来源，而且读错了，值得写清楚。** 之前只读
    /// `sysctl hw.cpufrequency_max`，那是 macOS（Intel）专有的键；iOS 真机上它恒返回
    /// 失败，`sysctlInt` 给回 nil，界面就一直显示「—」。网上流传很广的那段
    /// `sysctl(mib, 2, &results, ...)` 取 `HW_CPU_FREQ` 是早期 iOS 的遗留代码 ——
    /// Apple 后来把主频这个内核变量对沙箱关掉了。
    ///
    /// 所以这里按机型查表拿**标称**主频，真实的当前主频由 `CPUFrequency` 实测
    /// （见那边与 `CPUFrequencyProbe.c` 的注释）。CPU-X 的界面把这两者并列：
    /// `CPU Design Speed`（设计主频）与 `CPU Current Speed`（当前主频）——
    /// 前者查表，后者实测。
    ///
    /// 静态数据，不猜、不编；认不出来的机型留 0，界面显示「—」。
    private static let cpuIdentity: (model: String, physicalCores: Int, logicalCores: Int, nominalFrequencyMHz: Int) = {
        let machine = sysctlString("hw.machine") ?? ""
        // 个别机型／系统版本上这个键仍然是通的，能读到就优先用它（那才是真正的
        // 内核口径），读不到再退回机型表。
        let fromKernel = sysctlInt("hw.cpufrequency_max").map { $0 / 1_000_000 }
            ?? sysctlInt("hw.cpufrequency").map { $0 / 1_000_000 }
        return (cpuName(machine: machine),
                sysctlInt("hw.physicalcpu") ?? 0,
                sysctlInt("hw.logicalcpu") ?? 0,
                fromKernel ?? nominalClockMHz(machine: machine) ?? 0)
    }()

    /// 芯片标称主频（性能核的最高频率，MHz），按机型标识查。
    ///
    /// 同一颗芯片装在很多机型上，所以按芯片分组写，展开成一张 `[机型: 主频]`。
    /// 数值取自公开的芯片规格。**只列有把握的** —— 认不出来的机型返回 nil、
    /// 界面显示「—」，比编一个数字出来好。设备族限定为 iPhone
    /// （`TARGETED_DEVICE_FAMILY = 1`），所以不列 iPad。
    private static func nominalClockMHz(machine: String) -> Int? {
        clocks[machine]
    }

    private static let clocks: [String: Int] = {
        let chips: [(machines: [String], megahertz: Int)] = [
            (["iPhone8,1", "iPhone8,2", "iPhone8,4"], 1850),                   // A9
            (["iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4"], 2340),      // A10 Fusion
            (["iPhone10,1", "iPhone10,2", "iPhone10,3",
              "iPhone10,4", "iPhone10,5", "iPhone10,6"], 2390),                // A11 Bionic
            (["iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone11,8"], 2490),  // A12 Bionic
            (["iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone12,8"], 2650),  // A13 Bionic
            (["iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4"], 3100),  // A14 Bionic
            (["iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5",
              "iPhone14,6", "iPhone14,7", "iPhone14,8"], 3230),                // A15 Bionic
            (["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5"], 3460),  // A16 Bionic
            (["iPhone16,1", "iPhone16,2"], 3780),                              // A17 Pro
            (["iPhone17,1", "iPhone17,2"], 4050),                              // A18 Pro
            (["iPhone17,3", "iPhone17,4", "iPhone17,5"], 4040),                // A18
        ]
        var table: [String: Int] = [:]
        for chip in chips {
            for machine in chip.machines { table[machine] = chip.megahertz }
        }
        return table
    }()

    private static func readCPU(previous: inout [UInt64]) -> CPUStats {
        var stats = CPUStats()
        stats.model = cpuIdentity.model
        stats.physicalCores = cpuIdentity.physicalCores
        stats.logicalCores = cpuIdentity.logicalCores
        // 频率不在这里填：它是实测值，由 `refresh` 补上（见那边的注释）。

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

    /// 在后台线程上跑一次实测，结果回主 actor。
    ///
    /// 探针是**阻塞**的（15–20 ms 的满速忙循环），放主线程上就是一次肉眼可见的卡顿，
    /// 所以整件事丢给一个专用队列；它不碰任何 UI，只把最后那个 `Int?` 送回来。
    ///
    /// 回主 actor 用 `Task { @MainActor in }` 而不是 `DispatchQueue.main.async`：
    /// 后者在 Swift 6 的类型系统里并不建立主 actor 隔离，直接写主 actor 属性会报错。
    private func refreshFrequencyIfNeeded() {
        guard !frequencyProbeInFlight else { return }
        frequencyProbeInFlight = true
        let nominal = Self.cpuIdentity.nominalFrequencyMHz
        frequencyQueue.async { [weak self] in
            let measured = CPUFrequency.measureMHz(nominalMHz: nominal)
            Task { @MainActor in
                guard let self else { return }
                self.measuredFrequencyMHz = measured
                self.frequencyProbeInFlight = false
            }
        }
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
        stats.purgeable = UInt64(vmStats.purgeable_count) &* page
        stats.speculative = UInt64(vmStats.speculative_count) &* page
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

    /// `<sys/socket.h>` / `<net/route.h>` 里的常量，以及 `if_msghdr2` 的字段偏移。
    ///
    /// 写成字面量而不是直接用那几个宏：`PF_ROUTE` 在头文件里是 `AF_ROUTE` 的别名
    /// （宏套宏），Swift 的宏导入对它并不可靠；`NET_RT_IFLIST2`、`RTM_IFINFO2` 同理，
    /// 一并写死更省事。偏移按 Darwin 的 ABI 写 —— 这几个结构自 64 位 Darwin 起没变过。
    private enum Route {
        /// `CTL_NET`
        static let ctlNet: Int32 = 4
        /// `PF_ROUTE`（= `AF_ROUTE`）
        static let pfRoute: Int32 = 17
        /// `NET_RT_IFLIST2`
        static let netRTIFList2: Int32 = 6
        /// `RTM_VERSION`
        static let rtmVersion: UInt8 = 5
        /// `RTM_IFINFO2`
        static let rtmIfInfo2: UInt8 = 0x12
        /// `IF_NAMESIZE`（= `IFNAMSIZ`）。宏套宏，同样写成字面量。
        static let ifNameSize = 16

        /// `struct if_msghdr2` 里 `ifm_data`（`struct if_data64`）的起始偏移。
        static let ifData64Offset = 32
        /// `struct if_data64.ifi_ibytes` 的绝对偏移。
        static let ifIBytesOffset = ifData64Offset + 64
        /// `struct if_data64.ifi_obytes` 的绝对偏移。
        static let ifOBytesOffset = ifData64Offset + 72
        /// 一条 `RTM_IFINFO2` 至少要有这么长才读得到两个计数器。
        static let minimumIfInfo2Length = ifOBytesOffset + 8
    }

    /// 各接口的累计字节数，来自 `NET_RT_IFLIST2`。
    ///
    /// **为什么不用 `getifaddrs` 的 `ifa_data`** —— 这正是「下载 / 上传与累计流量一直
    /// 是 0」的根因，值得写清楚：
    ///
    /// 1. `ifa_data` **只在 `AF_LINK` 那条记录上非空**。之前是在 `AF_INET` 记录上读它，
    ///    那里恒为 NULL，于是 `ifi_ibytes` / `ifi_obytes` 永远是 0 —— 地址显示得出来
    ///    （地址本来就走 `AF_INET`），流量却一直是零，症状正是「一半对一半不对」；
    /// 2. 即便读对了记录，`ifa_data` 指向的是 32 位的 `struct if_data`
    ///    （`ifi_ibytes` 是 `u_int32_t`），4 GB 就回绕 —— 累计流量根本没法用。
    ///
    /// `NET_RT_IFLIST2` 返回的是 `if_msghdr2` + `if_data64`：计数器 64 位，
    /// 也正是 `netstat` 在 64 位系统上走的那条路。
    private static func interfaceCounters() -> [String: (received: UInt64, sent: UInt64)] {
        var mib: [Int32] = [Route.ctlNet, Route.pfRoute, 0, 0, Route.netRTIFList2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var counters: [String: (received: UInt64, sent: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + Route.minimumIfInfo2Length <= length {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let version = raw.loadUnaligned(fromByteOffset: offset + 2, as: UInt8.self)
                let type = raw.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
                // 缓冲区是内核按 `ifm_msglen` 串起来的消息流。长度或版本走歪了就停 ——
                // 继续按偏移读下去只会读到垃圾。
                guard messageLength > 0, version == Route.rtmVersion else { break }

                if type == Route.rtmIfInfo2,
                   messageLength >= Route.minimumIfInfo2Length,
                   offset + Route.minimumIfInfo2Length <= length {
                    let index = UInt32(raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt16.self))
                    let received = raw.loadUnaligned(fromByteOffset: offset + Route.ifIBytesOffset,
                                                     as: UInt64.self)
                    let sent = raw.loadUnaligned(fromByteOffset: offset + Route.ifOBytesOffset,
                                                 as: UInt64.self)
                    var name = [CChar](repeating: 0, count: Route.ifNameSize + 1)
                    if if_indextoname(index, &name) != nil {
                        counters[nullTerminatedString(name)] = (received, sent)
                    }
                }
                offset += messageLength
            }
        }
        return counters
    }

    /// 各接口的 IPv4 地址，来自 `getifaddrs`。
    ///
    /// 地址与计数器分两个来源取，是因为它们本来就在两条不同的记录上：
    /// 地址在 `AF_INET` 记录，字节计数在 `AF_LINK`（或 `NET_RT_IFLIST2`）里。
    /// 硬凑到一次遍历里，就是上一版踩的那个坑。
    private static func ipv4Addresses() -> [String: String] {
        var result: [String: String] = [:]
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return result }
        defer { freeifaddrs(addresses) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = nullTerminatedString(at: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result[name] = nullTerminatedString(host)
            }
        }
        return result
    }

    private static func readNetwork(
        previous: inout [String: (rx: UInt64, tx: UInt64, date: Date)],
        lastInterface: inout String?
    ) -> NetworkStats {
        var stats = NetworkStats()
        let counters = interfaceCounters()
        let addresses = ipv4Addresses()
        guard !counters.isEmpty else { return stats }

        let now = Date()
        var candidates: [(name: String, kind: NetworkKind, ipv4: String, rx: UInt64, tx: UInt64)] = []
        for (name, counter) in counters {
            // 只认 Wi-Fi（`en*`）与蜂窝（`pdp_ip*`），虚拟隧道一律跳过。
            guard let kind = NetworkKind(interfaceName: name) else { continue }
            // 没有 IPv4 就不显示：这个面板要的是「现在走哪条路、地址是多少」，
            // 只有 IPv6 的接口放进来会让地址那一栏变成空白。
            guard let ipv4 = addresses[name] else { continue }
            candidates.append((name, kind, ipv4, counter.received, counter.sent))
        }

        // 选哪条链路：**先看类型，再看谁在跑流量。**
        //
        // 手机插着 SIM 卡时 `pdp_ip0` 一直是 up、也一直有地址，所以「有 IPv4」分不出
        // Wi-Fi 和蜂窝；按累计字节数挑同样会挑错 —— 后台同步、推送常常悄悄走蜂窝，
        // 累计量比 Wi-Fi 还大。规则改成确定的：连着 Wi-Fi 就是 Wi-Fi，断了才轮到蜂窝。
        //
        // 同一档内仍然优先沿用上次选中的接口，避免同档两个接口来回跳导致速率失真。
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.priority < rhs.kind.priority }
            let lhsSticky = lhs.name == lastInterface
            let rhsSticky = rhs.name == lastInterface
            if lhsSticky != rhsSticky { return lhsSticky }
            let lhsLoad = lhs.rx &+ lhs.tx
            let rhsLoad = rhs.rx &+ rhs.tx
            if lhsLoad != rhsLoad { return lhsLoad > rhsLoad }
            // `sorted(by:)` 不保证稳定，补一个确定的次序。
            return lhs.name < rhs.name
        }
        guard let chosen = ranked.first else { return stats }

        stats.kind = chosen.kind
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
