import Foundation
import Combine
import Darwin
import UIKit

// MARK: - 快照模型
//
// 这一组结构体全部标 `nonisolated`，不是随手加的：本工程设了
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不加就会被判成主 actor 隔离，
// 于是 `nonisolated` 的采样函数既不能返回它们、也不能接收它们。
// 它们本来就是纯数据（值类型、无可变共享状态），标 `nonisolated` 是它们本来的样子。

nonisolated struct CPUStats: Hashable {
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

nonisolated struct MemoryStats: Hashable {
    var total: UInt64 = 0
    var wired: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var compressed: UInt64 = 0
    /// `vm_statistics64.free_count` —— **完全空闲**的页。
    ///
    /// 这是 CPU-X 的 `Mem Free` 口径（它只取这一项），所以拿它去跟 CPU-X 比才对得上。
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
    /// `MemoryReclaimer.memoryPools()` 用的是同一套口径，两处必须一致，
    /// 否则优化报出来的数字跟面板对不上。
    ///
    /// **和 CPU-X 对不上，别拿它去对。** 拆开 ARMCPUZ 的内存页看过了，它报的
    /// `Mem Free` 就是 `vm_statistics64.free_count` 一项，不含 purgeable/speculative，
    /// 所以同一时刻它那个数会明显小于这里的「可用」（本机实测 87 MB 对 199 MB，
    /// 差值基本就是那两项）。想跟 CPU-X 对齐时看 `free`，不要看 `available` ——
    /// 界面上的 "Free" 指标就是为这个摆出来的。
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

    /// 只把**完全空闲**的页算作可用的占用率：`(总量 − free) / 总量`。
    ///
    /// 和 `usage` 的区别就是分母里那两项（purgeable + speculative）算不算数。
    /// 单看数值 `strictUsage` 必然更大，而且大得不少 —— 本机实测差出 100 MB 上下，
    /// 在 3 GB 的机器上就是三个百分点。
    ///
    /// 存在的理由只有一个：**跟 CPU-X 对得上**。负一屏那一格只放一个百分比加一个
    /// 「还剩多少」，两者必须出自同一口径才读得通；而那一格摆出来的目的就是拿去和
    /// CPU-X 比，所以它整个走 CPU-X 的口径（`free` + `strictUsage`），主 App 的
    /// 硬件页则两套口径并列，好让人看见差在哪。
    var strictUsage: Double {
        total == 0 ? 0 : min(1, Double(total > free ? total - free : 0) / Double(total))
    }
}

nonisolated struct StorageStats: Hashable {
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

nonisolated struct SystemStats: Hashable {
    var deviceName: String = "—"
    var modelIdentifier: String = "—"
    var systemVersion: String = "—"
    var kernelVersion: String = "—"
    var uptime: TimeInterval = 0
    var physicalMemory: UInt64 = 0
}

nonisolated struct HardwareSnapshot: Hashable {
    var date: Date = .now
    var cpu = CPUStats()
    var memory = MemoryStats()
    var storage = StorageStats()
    var system = SystemStats()
}

/// 采样过程中要跨帧保留的状态。
///
/// 从 `HardwareMonitor` 的实例属性里拆出来，是因为**计算整体搬到了后台队列上**：
/// 状态挂在那个 `@MainActor` 的实例上，就等于把它钉死在主线程。
nonisolated struct SamplingState {
    /// `readCPU` 上一次的 tick 计数。占用率靠两次采样差分。
    var previousTicks: [UInt64] = []
    /// 存储容量上一次真正去问文件系统的时间。见 `HardwareMonitor.sample`。
    var lastStorageRead: Date = .distantPast
    /// 上一次问到的容量。
    var cachedStorage = StorageStats()
}

// MARK: - 采样器

/// 每秒采一次 CPU / 内存 / 存储 / 系统信息。
///
/// 全部走公开或半公开的 Mach / BSD 接口，只读，不写任何注册表：
/// - CPU 占用：`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，两次采样求差值
/// - 内存分项：`host_statistics64(HOST_VM_INFO64)`
/// - 存储容量：`URLResourceValues`
/// - 系统信息：`sysctl` / `uname` / `ProcessInfo`
final class HardwareMonitor: ObservableObject {
    @Published private(set) var snapshot = HardwareSnapshot()

    private var ticker: AnyCancellable?
    /// 采样过程中要跨帧保留的状态（CPU tick 基线、容量缓存）。
    ///
    /// 标 `nonisolated(unsafe)` 是刻意的：本类是 `@MainActor` 的，而采样恰恰要跑到
    /// 主线程之外（见 `samplingQueue`）。**它只允许在 `samplingQueue` 上访问** ——
    /// 那是条串行队列，加上 `samplingInFlight` 的守卫，同一时刻只有一个采样在跑，
    /// 所以不存在并发读写。
    nonisolated(unsafe) private var samplingState = SamplingState()
    /// 一次采样还没回来时置位。用来**丢拍**，而不是让任务在队列上堆积。
    private var samplingInFlight = false
    /// 跑采样的串行队列。
    ///
    /// 搬离主线程的理由：`host_processor_info` / `host_statistics64` 是 Mach 调用，
    /// `CPUSharedMetrics.read` 是文件读加 JSON 解析，`readStorage` 更是一次文件系统
    /// 往返 —— 每秒把它们按顺序砸进主线程，就是在给每秒一次的触摸响应制造延迟。
    /// `qos: .utility` 是明确的：后台维护性工作，不跟 UI 抢资源。
    ///
    /// 这块逻辑**不碰 UIKit、不碰 `UIDevice`**（那是 `readSystem` 的事，它留在主线程，
    /// 见 `refresh`），所以整块可以安全地跑在这里。
    private let samplingQueue = DispatchQueue(label: "com.corin.sysprobe.sampling",
                                              qos: .utility)

    func start() {
        guard ticker == nil else { return }
        // 首拍**同步**跑完，之后每一拍才走 `samplingQueue`。
        //
        // 理由只有一个：`TodayViewController` 在 `viewDidAppear` 里同步读一次
        // `snapshot` 去铺首屏。异步的话那一帧拿到的还是全 0 的初始值，负一屏会先闪
        // 一下空白。这一次 Mach 调用（几百微秒）换掉那次闪烁是划算的 —— 而且它只
        // 发生在启动路径上，稳态里一次都不会有。
        //
        // 此刻 `ticker` 还没建起来，不可能有采样在飞，所以这里直接碰 `samplingState`
        // 是安全的（平时的约定是「只在 `samplingQueue` 上访问」）。
        var first = Self.sample(state: &samplingState)
        first.system = Self.readSystem()
        snapshot = first

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

    /// 每拍被 `Timer` 调一次。**只做两件必须在主线程做的事**：守卫、把结果赋给
    /// `snapshot`。真正的采样在 `samplingQueue` 上跑（见 `sample`）。
    func refresh() {
        // 上一拍还没回来就丢这一拍。
        //
        // 采样本身只要几百微秒，1 Hz 的节奏远宽于它；但设备被压住时
        // `host_processor_info` 也可能变慢。那时**丢一拍**远好过让任务在队列上堆积 ——
        // 堆积既会让延迟越滚越大，刷出来的又都是过期数据。
        guard !samplingInFlight else { return }
        samplingInFlight = true

        samplingQueue.async { [weak self] in
            guard let self else { return }
            let sampled = Self.sample(state: &self.samplingState)
            Task { @MainActor in
                var next = sampled
                // `UIDevice.current` 是主 actor 隔离的，只能在这里读。剩下的是静态
                // 快照加一次 `systemUptime`，留在主线程不构成开销。
                next.system = Self.readSystem()
                self.snapshot = next
                self.samplingInFlight = false
            }
        }
    }

    // MARK: 采样（后台）

    /// 一次完整采样。**不碰 UI、不碰 `UIDevice`**，所以整块跑在 `samplingQueue` 上。
    ///
    /// 跨帧状态通过 `state` 进出 —— 它是 `nonisolated(unsafe)` 的，只允许在这条
    /// 串行队列上访问。返回值里**不含** `system`：那一项要读 `UIDevice`，由调用方
    /// 在主线程补上。
    nonisolated private static func sample(state: inout SamplingState) -> HardwareSnapshot {
        var next = HardwareSnapshot()
        next.date = .now

        // 先照常采一次自己的 CPU —— 即使这次会用共享值，也必须推进 `readCPU` 的
        // tick 基线，否则一旦发布方停下、切回自采，第一次差分会因为基线太旧而算出
        // 一个离谱的占用。
        let ownCPU = readCPU(previous: &state.previousTicks)

        if let shared = CPUSharedMetrics.read(now: next.date) {
            // 走共享：数值来自 Statusbar（Helium）的 HUD，两个 App 显示同一个数。
            //
            // **这时不跑自己的忙循环探针。** 探针会把自己那个核顶到最高频，还会和
            // HUD 的探针互抢性能核 —— 多个探针同时跑，谁的读数都被污染。既然频率
            // 直接用共享文件里的值，就没有必要再自测一次。
            var cpu = ownCPU
            cpu.usage = shared.usage
            cpu.perCore = shared.perCore.isEmpty ? ownCPU.perCore : shared.perCore
            cpu.frequencyMHz = shared.frequencyMHz
            cpu.nominalFrequencyMHz = cpuIdentity.nominalFrequencyMHz
            next.cpu = cpu
        } else {
            // 回落：没有新鲜的共享文件（HUD 没在写）。
            //
            // **这里不再跑自己的忙循环探针。** 两个 App 各自跑探针会互抢性能核、
            // 还会把时钟顶高发热 —— 这正是要避免的。HUD 是常驻的、唯一采集者，
            // 正常情况下文件总是新鲜的；所以这里频率直接留 0，界面显示「—」，
            // 不再自测。
            var cpu = ownCPU
            cpu.nominalFrequencyMHz = cpuIdentity.nominalFrequencyMHz
            cpu.frequencyMHz = 0
            next.cpu = cpu
        }

        next.memory = readMemory()
        // 容量一次查询是一次文件系统往返，而数字几分钟都不会变。十秒问一次足够，
        // 中间直接复用上次的结果。
        if next.date.timeIntervalSince(state.lastStorageRead) > 10 {
            state.cachedStorage = readStorage()
            state.lastStorageRead = next.date
        }
        next.storage = state.cachedStorage
        return next
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
    nonisolated private static let cpuIdentity: (model: String, physicalCores: Int, logicalCores: Int, nominalFrequencyMHz: Int) = {
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
    nonisolated private static func nominalClockMHz(machine: String) -> Int? {
        clocks[machine]
    }

    nonisolated private static let clocks: [String: Int] = {
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

    nonisolated private static func readCPU(previous: inout [UInt64]) -> CPUStats {
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
                // **必须按无符号重解释，不能直接 `UInt64(...)`。**
                //
                // `processor_info_array_t` 的元素是 `integer_t`（有符号 32 位），但内核
                // 往里写的是 `natural_t` 的累计 tick。开机够久之后（idle tick 涨得最快）
                // 最高位会被置上，那个元素读出来就是**负数**，而 `UInt64(负数)` 在
                // Swift 里是**运行时 trap** —— 不是取到怪值，是整个采样线程崩掉。
                //
                // 用 `UInt32(bitPattern:)` 保留原字节再零扩展，这才是这段代码本来的
                // 意思：下面 `now >= before ? now - before : 0` 那句就是按无符号回绕写的。
                ticks.append(UInt64(UInt32(bitPattern: cpuInfo[core * stateCount + state])))
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

    nonisolated private static func readMemory() -> MemoryStats {
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

    nonisolated private static func readStorage() -> StorageStats {
        var stats = StorageStats()

        // 走 NSURL 的 `volumeAvailableCapacityForImportantUsage` 口径。
        //
        // 0.0.25 曾把这里换成 `statfs("/var")` + `f_bavail`，好让数字和 CPU-X 逐字节
        // 对得上。**0.0.26 按要求撤销了**：那一版报出来的「可用」明显偏小（`f_bavail`
        // 扣掉了 APFS 给系统留的那部分），跟设置里的「iPhone 储存空间」以及系统自己的
        // 提示都对不上，为了对齐一个第三方 App 而让自家的数字显得更紧张，不划算。
        //
        // `…ForImportantUsage` 是**乐观**口径（把系统认为「可清除」的空间也算进可用），
        // 比 `volumeAvailableCapacity` 大；这正是用户看到的「可用」该有的样子。
        // 代价是它和 CPU-X 对不上 —— 这是有意接受的，不再为了对齐去改口径。
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

    // MARK: 网络（已移除）
    //
    // 这里原来有一整块网络采样：接口地址（`getifaddrs`）、累计字节数与实时上下行
    // （`sysctl(NET_RT_IFLIST2)` 的 `if_msghdr2` + `if_data64`，64 位计数器 ——
    // 用 `ifa_data` 那个 32 位 `if_data` 会在 4 GB 回绕，是上一版「流量恒为 0 /
    // 一过 4 GB 就乱跳」的根因）。
    //
    // 0.0.26 按用户要求把硬件页最下方的 Network 卡片去掉了，但采样没停 —— 每秒
    // 仍然跑一次 `sysctl` 加一次 `getifaddrs`，结果没有任何消费方。0.0.27 把这
    // 部分整体删掉（含 `NetworkStats`、`HardwareSnapshot.network` 与两个采样
    // 计数器）。要恢复看 git 历史。
    //
    // **`NetworkKind` 枚举保留在文件顶部**：WakeControl 的 `WakeService` 靠它把
    // 接口收敛成「Wi-Fi / 蜂窝」并挑出口，删不得。

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

    nonisolated private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return nullTerminatedString(buffer)
    }

    nonisolated private static func sysctlInt(_ name: String) -> Int? {
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
    nonisolated private static func cpuName(machine: String) -> String {
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

    nonisolated private static func machineIdentifier() -> String {
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
