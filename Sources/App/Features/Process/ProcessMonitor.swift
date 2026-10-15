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
//  ── 三层信息，逐层降级 ─────────────────────────────────────────────────────
//
//  1. **进程表**：`sysctl(KERN_PROC_ALL)` 的 `kinfo_proc`。公开接口，**零新增权限**
//     —— pid / ppid / 属主 / 状态 / 启动时间 / 进程名。
//  2. **可执行路径**：`proc_pidpath`（私有 API，要 `task_for_pid-allow`）。用来把
//     「进程名」翻成「应用名」，以及判断这个进程属于用户装的 App 还是系统自带。
//  3. **资源计数**：`proc_pidinfo(PROC_PIDTASKINFO)`（私有 API，同上）。拿 CPU
//     累计时间与常驻内存。
//
//  第 2、3 层**可能整条不通**（权限被拦、库不在）。那种情况下这一页仍然是一个
//  可用的进程查看器：名字退回进程名、分组全落进「系统」、CPU 与内存显示「—」。
//  报告顶部的 `resolved` 字段就是给这件事用的 —— 它是「这一趟有几个进程真的读到
//  了资源计数」，界面靠它区分「读不到」与「占用 0」，**绝不把 0 当数字摆出去**。
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
    /// 1 = 用户安装的 App（可执行文件在 Bundle 容器里），0 = 系统自带。
    ///
    /// 判据在 C 侧：可执行路径里含 `/var/containers/Bundle/Application/`。
    let userApp: Int
    /// CPU **累计**时间（用户态 + 系统态，纳秒）。读不到时为 0。
    ///
    /// 这是累计值而不是占用率 —— 差分在 `ProcessMonitor.updateCPUShare` 里做，
    /// 因为工具每次都是一次性进程，留不住上一次的读数。
    let cpuNanos: UInt64
    /// 常驻内存（字节）。读不到时为 0。
    let residentBytes: UInt64
    /// 内核口径的进程名。
    ///
    /// `p_comm` 是 `char[MAXCOMLEN + 1]`，iOS 上 `MAXCOMLEN` 是 16，所以**超过
    /// 16 字符的名字会被内核截断**。这是接口的硬限制 —— 完整名字走
    /// `proc_pidpath`（第 2 层），截断问题在那里不存在。
    let comm: String
    /// 从 `.app` 包里读出来的显示名（走本地化，中文环境下就是中文名）。
    /// 取不到时与 `comm` 相同；工具太旧、字段缺失时是空串。
    let name: String

    var id: Int { pid }

    var isUserApp: Bool { userApp == 1 }

    /// 界面上该显示的名字。`name` 为空（字段缺失）时退回 `comm` ——
    /// 与 C 侧「取不到显示名就保留进程名」是同一条规则，只是兜在两端各一层。
    var displayName: String {
        if !name.isEmpty { return name }
        return comm.isEmpty ? "—" : comm
    }

    /// 显示名与进程名不同时才值得把进程名也摆出来。
    ///
    /// 典型场景：一个 App 带着若干扩展进程，显示名都是主 App 名，
    /// 这时进程名（`…Widget` / `…Keyboard`）才是区分它们的唯一线索。
    var showsCommSeparately: Bool {
        !comm.isEmpty && comm != displayName
    }

    /// 这一条的资源计数是不是真的读到了。
    ///
    /// 用常驻内存判断而不是 `cpuNanos`：刚起来的进程 CPU 累计时间可以是 0
    /// （那是真实读数），而常驻内存不可能是 0 —— 任何活着的进程都有代码段。
    var hasResourceData: Bool { residentBytes > 0 }

    // 手写解码而不是靠合成：**一个字段缺失就让整份报告解不出来**是这一页最
    // 典型的故障形态（工具与 App 不同步、报告被截断）。除了 `pid` 之外全给
    // 默认值，让列表至少能显示出来。
    private enum CodingKeys: String, CodingKey {
        case pid, ppid, uid, status, started, userApp, cpuNanos, residentBytes, comm, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int.self, forKey: .pid)
        ppid = try c.decodeIfPresent(Int.self, forKey: .ppid) ?? 0
        uid = try c.decodeIfPresent(Int.self, forKey: .uid) ?? 0
        status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 0
        started = try c.decodeIfPresent(Double.self, forKey: .started) ?? 0
        userApp = try c.decodeIfPresent(Int.self, forKey: .userApp) ?? 0
        cpuNanos = try c.decodeIfPresent(UInt64.self, forKey: .cpuNanos) ?? 0
        residentBytes = try c.decodeIfPresent(UInt64.self, forKey: .residentBytes) ?? 0
        comm = try c.decodeIfPresent(String.self, forKey: .comm) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
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
    /// 这一趟里真的读到资源计数的进程数。0 = libproc 那条路整条不通，
    /// 界面据此把 CPU / 内存两列显示成「—」。
    let resolved: Int
    let processes: [ProcessEntry]

    private enum CodingKeys: String, CodingKey { case count, resolved, processes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        processes = try c.decode([ProcessEntry].self, forKey: .processes)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? processes.count
        resolved = try c.decodeIfPresent(Int.self, forKey: .resolved) ?? 0
    }
}

/// 一次采样的结果。比裸数组多带一个 `resolved` —— 界面要它来判断资源那两列
/// 该显示数字还是「—」。
nonisolated struct ProcessSample: Sendable {
    let entries: [ProcessEntry]
    let resolved: Int
}

// MARK: - 采样

/// 包内特权工具（`SysProbeRootTool`）的进程列表入口。
///
/// 与 `StorageCleaner` 同一条链路：同一个工具二进制、同一个 root persona 启动方式
/// （`ChargeSpawn.c`），只是走 `proc-list` 子命令。
nonisolated enum ProcessSampler {

    /// 一次采样的等待预算。
    ///
    /// 这一趟要遍历进程表、对每个进程调两次 libproc、读若干 `.app` 的 Info.plist
    /// （`CFBundleCreate` 有内部缓存，同一个 bundle 只读一次），再写一份几十 KB 的
    /// JSON。真机上几百个进程，正常在几十到一两百毫秒内返回。给 3 秒是留足余量 ——
    /// 设备被压住时这些调用都会变慢，而那个 1 秒的自检预算
    /// （`sysprobe_spawn_root_tool_sync`）在这种活上会把正常干活误判成超时。
    private static let timeoutMs: Int32 = 3_000

    /// 采样一次。
    ///
    /// 任何一步失败都返回 `nil` —— 调用方把它当「这一拍没拿到」处理，
    /// **保留上一拍的数据**，而不是把列表清空（那会让界面在偶发失败时闪一下空白）。
    static func sample() -> ProcessSample? {
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

        return ProcessSample(entries: report.processes, resolved: report.resolved)
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
/// ── 每一拍的开销 ────────────────────────────────────────────────────────────
///
/// 每一拍都要 `posix_spawn` 一个 root 子进程：遍历进程表（这台设备上三百多条）、
/// 对每个进程调 libproc、写一份几十 KB 的 JSON、再由 App 读回来并 `JSONDecoder`
/// 解一遍。按 1 Hz 算，那是「每秒起一个特权进程」。
///
/// ── 只在页面可见时采样 ─────────────────────────────────────────────────────
///
/// `start()` / `pause()` 由页面的 `onAppear` / `onDisappear` 驱动，`refresh()`
/// 自己还有一道 `isVisible` 闸门。**切到别的分页、或 App 退到后台，一拍都不跑。**
/// 这是这一页与硬件页最大的不同：那边采一次是两次 Mach 调用（几百微秒），
/// 这边要起进程。
///
/// 页面可见期间按 `interval` 自动刷新 —— 不是为了「实时」（进程表本来就不怎么变），
/// 而是因为 CPU 占用率**只能由两次读数求差**得到（见 `updateCPUShare`）。
/// 停在页面上不动时，3 秒的节奏刚好让那两列是活的。
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
    /// 最近一拍里读到资源计数的进程数。0 = 整条 libproc 路不通。
    @Published private(set) var resolvedCount = 0
    /// 每个进程的 CPU 占用率（0…1，**整机口径**：所有核加起来是 100%）。
    ///
    /// 只有「这一拍与上一拍之间」有基线的进程才在里面 —— 刚出现的进程不在，
    /// 界面显示「—」。整机口径与 Windows 任务管理器一致：四核机器上跑满一个核
    /// 是 25%，不是 100%。
    @Published private(set) var cpuShare: [Int: Double] = [:]

    private var ticker: AnyCancellable?
    /// 上一拍还没回来时置位，用来**丢拍**而不是让任务在队列上堆积。
    private var samplingInFlight = false
    /// 页面当前是否可见。`refresh()` 的第一道闸门 —— 定时器万一流失，
    /// 这一条也能保证不会在别的分页上偷偷起特权进程。
    private var isVisible = false
    /// 上一拍的 CPU 累计时间，按 pid 索引。
    ///
    /// **切走不清空**：再回来时用几秒前的读数做基线，第一拍就能给出占用率，
    /// 而不是先空三秒。间隔过大时会在 `updateCPUShare` 里主动丢掉（见那里的说明）。
    private var previousCPUNanos: [Int: UInt64] = [:]
    private var previousSampleTime: Date?

    /// 开始采样。已经在跑就什么都不做（幂等）—— 与 `HardwareMonitor.start` 一致，
    /// `onAppear` 与 `scenePhase` 两条路径都会调它。
    func start() {
        isVisible = true
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
        isVisible = false
        ticker?.cancel()
        ticker = nil
    }

    /// 跑一拍。手动刷新与定时器都走这里。
    func refresh() {
        // 页面不在前台就什么都不做。定时器在 `pause()` 里已经取消了，这一条是
        // 兜底：任何路径（未来的 scenePhase、别的调用方）都不会绕过它去起特权进程。
        guard isVisible else { return }

        // 上一拍还没回来就丢这一拍。采样本身是几十毫秒级，3 秒的节奏远宽于它；
        // 但设备被压住时遍历进程表也会变慢，那时丢一拍远好过让任务堆积 ——
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
                let now = Date()
                self.processes = result.entries
                self.resolvedCount = result.resolved
                // 先更新列表再算占用率：`updateCPUShare` 内部会把这拍的读数存成
                // 下一拍的基线，所以两件事的先后顺序只影响这一帧显示什么。
                self.updateCPUShare(with: result.entries, at: now)
                self.lastUpdated = now
                self.lastAttemptFailed = false
            } else {
                self.lastAttemptFailed = true
            }
            self.samplingInFlight = false
            self.isSampling = false
        }
    }

    /// 用两次采样的 CPU 累计时间差算占用率。
    ///
    /// ── 为什么差分必须在 App 侧做 ────────────────────────────────────────────
    ///
    /// `proc_pidinfo` 给的 `pti_total_user` / `pti_total_system` 是**进程自启动以来
    /// 的累计值**，不是占用率。要变成占用率只能「两次读数求差 ÷ 中间经过的墙钟时间」，
    /// 而工具每次都是一次性进程 —— 它退出时那次读数就没了，留不住基线。
    ///
    /// ── 分母为什么乘核数 ────────────────────────────────────────────────────
    ///
    /// 一个进程的 CPU 时间在多个核上可以并行累加，所以「一个核跑满」时
    /// `delta / elapsed` 是 1 而不是 1/N。乘上核数之后口径变成「整机 CPU 的占比」，
    /// 与 Windows 任务管理器一致（四核机器上跑满一核 = 25%），几列相加也才有意义。
    ///
    /// ── 两种间隔都要丢掉 ────────────────────────────────────────────────────
    ///
    /// · 太短（< 0.25 s）：差分会被调度噪声放大，随手连点两下刷新能刷出 100%；
    /// · 太长（> 120 s）：算出来的是「这段时间的平均占用」，与「此刻占用」不是
    ///   一回事，摆在任务管理器式的界面里会误导。
    ///
    /// 两种情况下都清空 `cpuShare`（那两列显示「—」），但**基线照常更新** ——
    /// 所以下一拍（3 秒后）就有数了，不需要用户做任何事。
    private func updateCPUShare(with entries: [ProcessEntry], at now: Date) {
        let previousTime = previousSampleTime
        let previous = previousCPUNanos

        // 先换基线，再算这一拍 —— 这样中途 `return` 的那些分支也不会让基线卡住。
        var baseline: [Int: UInt64] = [:]
        baseline.reserveCapacity(entries.count)
        for entry in entries {
            baseline[entry.pid] = entry.cpuNanos
        }
        previousCPUNanos = baseline
        previousSampleTime = now

        guard let previousTime else {
            cpuShare = [:]
            return
        }

        let elapsed = now.timeIntervalSince(previousTime)
        guard elapsed > 0.25, elapsed < 120 else {
            cpuShare = [:]
            return
        }

        let budget = elapsed * 1_000_000_000
            * Double(ProcessInfo.processInfo.activeProcessorCount)
        var shares: [Int: Double] = [:]
        shares.reserveCapacity(entries.count)
        for entry in entries {
            // 没有基线（刚出现的进程）、或累计时间倒退（pid 复用、计数器重置）
            // 就跳过 —— 那两列显示「—」，不编一个数字出来。
            guard let before = previous[entry.pid], entry.cpuNanos > before else { continue }
            shares[entry.pid] = min(1, Double(entry.cpuNanos - before) / budget)
        }
        cpuShare = shares
    }
}
