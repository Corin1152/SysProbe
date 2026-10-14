import Foundation

/// 「自动刷新」的**后台**载体：拉起守护进程、下发配置、回读状态。
///
/// ── 为什么需要它 ────────────────────────────────────────────────────────────
///
/// App 内那条路（`BandAutoRefreshController`）靠 Swift 定时器轮询，而 `Info.plist`
/// **没有 `UIBackgroundModes`** —— 退后台即挂起，定时器停摆。要「切到后台也继续」，
/// 判定必须跑在另一个进程里。那就是 `Tools/BandRefreshDaemon.m`：由 App 用
/// `sysprobe_spawn_root_daemon` 以 root spawn 出来，自己带 `main()` 与循环。
///
/// ── 三个约定 ────────────────────────────────────────────────────────────────
///
/// 1. **路径与守护进程里的两个常量必须一字不差**。它们在两份源码里各写一份
///    （跨进程没有共享头文件的余地），改动时要两边一起改，否则配置写进去、
///    守护进程读不到 —— 症状是「开关能开、日志一行没有」。
/// 2. **配置只由 App 写、状态只由守护进程写**。两个进程 uid 不同（501 / 0），
///    谁创建的文件对方不一定改得动；单向写避开这一整类静默失败。
/// 3. **停守护进程只能靠配置里的 `enabled = NO`** —— 它忽略 SIGHUP / SIGTERM
///    （与 ChargeLimiterDaemon 一致），没有信号能杀它。
///
/// ── 判活 ────────────────────────────────────────────────────────────────────
///
/// 充电守护进程靠 1230 端口（`sysprobe_local_port_open`）判活，这里没有端口可探，
/// 改用**心跳**：守护进程每轮把时间戳写进状态文件，App 看它新不新鲜。
/// 有效期由守护进程自己算好写进去（`heartbeatValidity`）—— 采样间隔被调大之后，
/// App 侧写死一个常数会误判成「死了」，然后每 10 秒 spawn 一个。
///
/// 与充电那边一样，这里**不查进程表**：App 拿不到守护进程的 pid（spawn 出去之后
/// 没有保存），而且 uid 501 对 uid 0 的进程 `kill(pid, 0)` 返回的是 EPERM 而不是 0，
/// 查了也查不准。
final class BandRefreshDaemonBridge: ObservableObject {

    static let shared = BandRefreshDaemonBridge()

    // ── 与 Tools/BandRefreshDaemon.m 里的两个常量对应，改一处就要改另一处 ──
    static let configPath =
        "/var/mobile/Library/Preferences/com.corin.sysprobe.bandrefresh.plist"
    static let statePath =
        "/var/mobile/Library/Caches/sysprobe-bandrefresh-state.plist"

    /// 守护进程回报的状态。
    struct State: Equatable {
        /// 心跳是否新鲜 —— 也就是守护进程是否还在跑。
        var alive = false
        var phase = "stopped"
        /// `armed` / `cooling` 的剩余秒数。
        var remaining: Double = 0
        var lastRsrp: Int?
        var lastRefreshAt: Date?
        var log: [String] = []

        static let empty = State()
    }

    @Published private(set) var state = State.empty
    /// 包里有没有这个守护进程。没有的话界面上不该给出那个开关 ——
    /// 给了就是「能点、点了什么都不发生」。
    let bundled: Bool

    /// 文件路径。`nil` = 包里没有，此时一切操作都该退化成空操作。
    private let daemonPath: String?

    private var watchdog: Timer?
    /// 看门狗与状态回读都要读文件，放到自己的队列上。
    private let queue = DispatchQueue(label: "com.corin.sysprobe.bandRefreshDaemon")

    private init() {
        let path = Bundle.main.bundlePath + "/BandRefreshDaemon"
        let exists = FileManager.default.isExecutableFile(atPath: path)
        daemonPath = exists ? path : nil
        bundled = exists
    }

    // MARK: - 配置下发

    /// 把当前参数写成守护进程读的那份 plist。
    ///
    /// `enabled` 写的是**后台开关**而不是前台那个开关：这是这两个执行体的分工 ——
    /// 后台开着就交给守护进程，前台那条路同时停下（调用方负责），否则两边各自判定
    /// 会**刷两次**，而用户只会觉得「它怎么一直在掉网」。
    func writeConfig(_ config: BandAutoRefreshConfig, slot: Int) {
        let dict: [String: Any] = [
            "enabled": config.backgroundDaemon,
            "dryRun": config.dryRun,
            "direction": config.direction.rawValue,
            "thresholdDbm": config.thresholdDbm,
            "slot": slot,
            "dwellSec": config.dwellSec,
            "cooldownSec": config.cooldownSec,
            "sampleIntervalSec": config.sampleIntervalSec,
        ]
        // 原子写：守护进程每一轮开头都读它，写一半的 plist 会让它读成 nil，
        // 于是它按「关闭」处理并退出 —— 表现是「开了后台，过一会儿自己停了」。
        (dict as NSDictionary).write(toFile: Self.configPath, atomically: true)
    }

    // MARK: - 启停

    /// 开一次看门狗，App 活着期间一直跑。
    ///
    /// 10 秒一轮，与 `ChargeControlService` 里那条同一个节奏。作用是两件：
    /// 守护进程没起来就拉它起来；顺带把状态带回界面。
    ///
    /// **App 挂起之后它也会停** —— 那时守护进程仍在跑（这才是它存在的意义），
    /// 只是它万一崩了没人复活，直到用户再打开 App。手机重启同理。
    func startWatchdog() {
        guard bundled, watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.tick() }
        }
        // 不等第一轮：刚打开 App 就该知道它还在不在。
        queue.async { self.tick() }
    }

    func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func tick() {
        let config = BandAutoRefreshConfig.load()
        let current = loadState(interval: config.sampleIntervalSec)

        DispatchQueue.main.async { [weak self] in
            self?.state = current
        }

        // 只有「本该在跑却没在跑」才拉。关掉后台开关之后这里必须安静 ——
        // 否则每 10 秒 spawn 一个，它们又会各自因为 enabled=NO 立刻退出，
        // 留下一串僵尸（与 ChargeSpawn.c 里那条注释同一个坑）。
        guard config.backgroundDaemon, !current.alive else { return }
        guard let path = daemonPath else { return }
        _ = sysprobe_spawn_root_daemon(path)
    }

    /// 手动回读一次状态。页面出现时用，不然最多要等 10 秒才看到真实状态。
    func refreshState() {
        let interval = BandAutoRefreshConfig.load().sampleIntervalSec
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.loadState(interval: interval)
            DispatchQueue.main.async { self.state = s }
        }
    }

    // MARK: - 状态回读

    /// 读守护进程写的那份状态文件。读不到、或心跳过期，都算「没在跑」。
    private func loadState(interval: Double) -> State {
        guard let raw = NSDictionary(contentsOfFile: Self.statePath) as? [String: Any] else {
            return .empty
        }

        let beat = (raw["heartbeat"] as? NSNumber)?.doubleValue ?? 0
        // 有效期优先用守护进程自己算好的那份；读不到才按 App 侧的间隔现算，
        // 公式与守护进程里 `heartbeatValidity()` 一致。
        let validity = (raw["heartbeatValidity"] as? NSNumber)?.doubleValue
            ?? (interval * 4 + 10)

        var s = State()
        s.alive = beat > 0 && (Date().timeIntervalSince1970 - beat) < validity
        s.phase = (raw["phase"] as? String) ?? "stopped"
        s.remaining = (raw["remaining"] as? NSNumber)?.doubleValue ?? 0
        s.lastRsrp = (raw["lastRsrp"] as? NSNumber)?.intValue
        if let t = (raw["lastRefreshAt"] as? NSNumber)?.doubleValue, t > 0 {
            s.lastRefreshAt = Date(timeIntervalSince1970: t)
        }
        // 日志是守护进程生成的，它进程里没有本地化，所以是**英文原文**。
        // 刻意在界面上原样显示：翻成中文反而对不上真机日志。
        s.log = (raw["log"] as? [String]) ?? []

        // 进程自己写了 stopped 就别再报活着 —— 它退出前的最后一笔状态。
        if s.phase == "stopped" { s.alive = false }
        return s
    }
}
