import Foundation
import Combine

// ══════════════════════════════════════════════════════════════════════════════
//  进程列表（「进程」分页）
//
//  数据来自包内特权工具 `SysProbeRootTool` 的 `proc-list` 子命令 —— 采集那一侧
//  在 `Tools/RootTool.c`，报告是 JSON，写进 App tmp 目录里的一个路径。
//
//  ── 为什么必须借 root 子进程 ────────────────────────────────────────────────
//
//  主 App 是 mobile（uid 501），查不了别的进程。这不是推测：`Tools/RootTool.c`
//  的 `daemon-kill` 那段注释里记着实测结论 —— 「uid 501 查不了 root 进程，
//  `kill(pid,0)` 只会拿到 EPERM」。进程表同理，只能由 root 子进程去读。
//
//  ── 这一版只有「身份」，没有「资源」 ────────────────────────────────────────
//
//  `proc-list` 目前只报进程名 / PID / PPID / 属主 / 状态 / 启动时间 —— 全部来自
//  `sysctl(KERN_PROC_ALL)` 的 `kinfo_proc`，那是公开接口，零新增权限。
//  **CPU 与内存两列是空的**：它们要 `proc_pidinfo` / `proc_pid_rusage`（私有 API）
//  且取决于 task port 权限，得先在真机上验证过才敢上。界面上这两列显示「—」，
//  不编数字 —— 详见 `RootTool.c` 里 `proc-list` 那一节的文件头说明。
// ══════════════════════════════════════════════════════════════════════════════

// MARK: - 模型

/// 一个进程。字段与 `proc-list` 报告一一对应。
///
/// 标 `nonisolated` 的理由与 `HardwareMonitor` 里那组快照结构体相同：本工程设了
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不标就会被判成主 actor 隔离，
/// 而采样函数是 `nonisolated` 的 —— 它既不能返回它们、也不能接收它们。
nonisolated struct ProcessEntry: Identifiable, Hashable, Sendable, Decodable {
    let pid: Int
    /// 父进程 pid。0 表示没有父进程（launchd 就是 0）。
    let ppid: Int
    /// 属主 uid。0 = root，501 = mobile。
    let uid: Int
    /// `p_stat` 的原始取值（1…5）。映射成文案见 `ProcessState`。
    ///
    /// 刻意让 C 侧报数字而不是字符串：`SIDL` / `SRUN` 那些宏在 iOS 公开 SDK 里
    /// 不一定可见，而这几个数字是内核 ABI 的一部分，稳定得多。
    let status: Int
    /// 启动时刻（epoch 秒）。
    ///
    /// **可能是 0** —— `kinfo_proc.p_starttime` 在部分机型 / 系统版本上不被内核
    /// 填充。界面据此显示「—」，而不是把 1970 年摆出来。
    let started: Double
    /// 内核口径的进程名。
    ///
    /// `p_comm` 是 `char[MAXCOMLEN + 1]`，iOS 上 `MAXCOMLEN` 是 16，所以**超过
    /// 16 字符的名字会被内核截断**。这是接口的硬限制：完整可执行路径要走
    /// `proc_pidpath`（私有 API），同样在待验证那一档里。
    let comm: String

    var id: Int { pid }
}

/// 进程的运行状态。取值是 `kinfo_proc.p_stat` 的原始编码。
nonisolated enum ProcessState: Int, Sendable {
    /// `SIDL` —— fork 出来还没起来的进程。
    case idle = 1
    /// `SRUN` —— 可运行（含正在跑）。
    case running = 2
    /// `SSLEEP` —— 睡着等事件。绝大多数进程常态就是这个。
    case sleeping = 3
    /// `SSTOP` —— 被调试或挂起。
    case stopped = 4
    /// `SZOMB` —— 已退出、等父进程收尸。
    case zombie = 5
    /// 内核给了一个我们不认识的取值。**不并进 sleeping** ——
    /// 「读不出来」和「在睡觉」是两件事，界面上该分开。
    case unknown = 0

    init(raw: Int) {
        self = ProcessState(rawValue: raw) ?? .unknown
    }
}

/// 进程的属主类别。
///
/// iOS 上进程的 uid 分布是「系统服务一堆专用 uid + 用户 App 统一 501」，
/// 所以按 uid 逐个列出来没有意义。收成三档，界面才读得懂。
nonisolated enum ProcessOwner: Hashable, Sendable {
    /// uid 0。
    case root
    /// uid 501 —— 所有用户 App 都在这一档。
    case mobile
    /// 其余（系统守护进程各自的专用 uid，如 `_securityd` 是 92）。
    case system(uid: Int)

    init(uid: Int) {
        switch uid {
        case 0: self = .root
        case 501: self = .mobile
        default: self = .system(uid: uid)
        }
    }
}

/// `proc-list` 报告的解码模型。
nonisolated struct ProcessListReport: Decodable, Sendable {
    /// 工具报的条目数。与 `processes.count` 应当一致；不一致说明报告被截断了，
    /// 那种情况下 `JSONDecoder` 通常已经先一步失败，所以这里只留作诊断。
    let count: Int
    let processes: [ProcessEntry]
}

// MARK: - 采样

/// 包内特权工具（`SysProbeRootTool`）的进程列表入口。
///
/// 与 `StorageCleaner` 同一条链路：同一个工具二进制、同一个 root persona 启动方式
/// （`ChargeSpawn.c`），只是走 `proc-list` 子命令。
nonisolated enum ProcessSampler {

    /// 一次采样的等待预算。
    ///
    /// 这一趟只做一次 `sysctl` 加一次写文件，正常在几十毫秒内返回。给 3 秒是留足
    /// 余量 —— 设备被压住时 `sysctl` 也可能变慢，而那个 1 秒的自检预算
    /// （`sysprobe_spawn_root_tool_sync`）在这种活上会把正常干活误判成超时。
    private static let timeoutMs: Int32 = 3_000

    /// 采样一次。
    ///
    /// 任何一步失败都返回 `nil` —— 调用方把它当「这一拍没拿到」处理，
    /// **保留上一拍的数据**，而不是把列表清空（那会让界面在偶发失败时闪一下空白）。
    static func sample() -> [ProcessEntry]? {
        guard let toolPath = DeviceActions.toolPath else { return nil }
        let reportPath = makeReportPath()

        var status: Int32 = 0
        // 没有附加参数 —— 四个位全传 nil。`nil` 只允许出现在**尾部**，
        // 这里全是 nil 所以合法（见 `ChargeSpawn.h`）。
        let spawnResult = sysprobe_spawn_root_tool_sync_args(
            toolPath, "proc-list", reportPath, nil, nil, nil, timeoutMs, &status)
        guard spawnResult == 0, status == toolExitOK else {
            removeReport(reportPath)
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: reportPath)),
              let report = try? JSONDecoder().decode(ProcessListReport.self, from: data) else {
            removeReport(reportPath)
            return nil
        }
        removeReport(reportPath)

        return report.processes
    }

    /// 与 `Tools/RootTool.c` 的退出码 enum 对齐：0 = 成功。
    /// 3（非 root）/ 4（失败）在这里都归为「没拿到」，界面上由列表本身是否为空兜住。
    private static let toolExitOK: Int32 = 0

    /// 报告路径落在 App 自己的 tmp 目录里，用 UUID 命名。
    ///
    /// UUID 是为了在极端情况下（工具超时、报告没写成）**也不会读到上一次的旧报告** ——
    /// 与 `StorageCleaner` 同一套约定。
    private static func makeReportPath() -> String {
        let tmp = NSTemporaryDirectory() as NSString
        return tmp.appendingPathComponent("sysprobe-proc-\(UUID().uuidString).json")
    }

    private static func removeReport(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - 采样器

/// 「进程」分页的采样器。
///
/// ── 为什么是 3 秒，不是 1 秒 ────────────────────────────────────────────────
///
/// 每一拍都要 `posix_spawn` 一个 root 子进程：遍历进程表（这台设备上几百条）、
/// 写一份几十 KB 的 JSON、再由 App 读回来并 `JSONDecoder` 解一遍。按 1 Hz 算，
/// 那是「每秒起一个特权进程」，而进程列表本来就不是每秒都在变的东西。
/// 3 秒是开销与新鲜度之间的折中；要立刻看最新的，页面上有手动刷新。
///
/// ── 只在页面可见时采样 ─────────────────────────────────────────────────────
///
/// `start()` / `pause()` 由页面的 `onAppear` / `onDisappear` 驱动。
/// 用户没停在这一页时，一拍都不跑 —— 这是这一页与硬件页最大的不同：
/// 那边采一次是两次 Mach 调用（几百微秒），这边要起进程。
@MainActor
final class ProcessMonitor: ObservableObject {

    /// 采样间隔（秒）。见类型头上的说明。
    static let interval: TimeInterval = 3

    @Published private(set) var processes: [ProcessEntry] = []
    /// 最近一次**成功**采样的时刻。`nil` = 还没成功过。
    @Published private(set) var lastUpdated: Date?
    /// 最近一次采样是否失败。
    ///
    /// 与「列表是空的」是两件事：失败但列表非空说明这是旧数据（该提示「数据是旧的」），
    /// 失败且列表为空说明从来没拿到过（该提示「读不出来」）。界面要分开说。
    @Published private(set) var lastAttemptFailed = false
    /// 这一拍正在跑。手动刷新按钮据此显示进度。
    @Published private(set) var isSampling = false

    private var ticker: AnyCancellable?
    /// 上一拍还没回来时置位，用来**丢拍**而不是让任务在队列上堆积。
    private var samplingInFlight = false

    /// 开始采样。已经在跑就什么都不做（幂等）—— 与 `HardwareMonitor.start` 一致，
    /// `onAppear` 与 `scenePhase` 两条路径都会调它。
    func start() {
        guard ticker == nil else { return }
        refresh()
        // 与 `HardwareMonitor` / `PowerMonitor` 同样的理由：挂在 `.default` 模式上的
        // `Timer` 会在滚动期间自动让路，`Task.sleep` 不会。这一页有几百行，
        // 滚动时正好最不该被重算打断。
        ticker = Timer.publish(every: Self.interval, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    func pause() {
        ticker?.cancel()
        ticker = nil
    }

    /// 跑一拍。手动刷新与定时器都走这里。
    func refresh() {
        // 上一拍还没回来就丢这一拍。采样本身是几十毫秒级，3 秒的节奏远宽于它；
        // 但设备被压住时 `sysctl` 也会变慢，那时丢一拍远好过让任务堆积 ——
        // 堆积既让延迟越滚越大，刷出来的又都是过期数据。
        guard !samplingInFlight else { return }
        samplingInFlight = true
        isSampling = true

        Task { @MainActor in
            // 阻塞调用（起子进程并等它），必须放到主 actor 之外 ——
            // 与 `StorageCleaner` / `DeviceActions.probe` 同一条约定。
            let result = await Task.detached(priority: .utility) {
                ProcessSampler.sample()
            }.value

            // ── 正在滚动就让路 ──
            //
            // 这一贴是异步回来的，不受 run loop 模式约束，正好会落在滚动的某几帧里；
            // 而它会让整页 body 重算一遍（这一页是几百行）。丢掉这一拍而不是延后：
            // 下一拍 3 秒后就到。`samplingInFlight` 必须在这里复位，
            // 否则采样从此不再派发。
            guard !MainThreadPacing.isScrolling else {
                self.samplingInFlight = false
                self.isSampling = false
                return
            }

            if let result {
                self.processes = result
                self.lastUpdated = .now
                self.lastAttemptFailed = false
            } else {
                self.lastAttemptFailed = true
            }
            self.samplingInFlight = false
            self.isSampling = false
        }
    }
}
