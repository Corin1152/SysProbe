import Foundation

/// 「信号弱到某个程度就自动刷新蜂窝信号」的配置。
///
/// 存在 `UserDefaults` 里（`sysprobe.bandAutoRefresh.*`），App 重启保留。
///
/// ── 为什么要一个 `load()` / `save()`，而不是 `@AppStorage` ──────────────────────
///
/// `@AppStorage` 挂在 `ObservableObject` 上时**不会**触发 `objectWillChange`，
/// 界面不一定跟着变；而这里的值同时被**两处**读：界面上的控件，以及后台那条轮询
/// 定时器。让定时器每拍都从 `UserDefaults` 重新 `load()` 一次，顺带解决了另一件
/// 更要紧的事 —— **改完参数立刻生效**，不用重开开关或重进页面。
struct BandAutoRefreshConfig: Equatable {

    /// 判定是否交给**后台守护进程**。
    ///
    /// 关着的时候判定跑在 App 内（`BandAutoRefreshController` 的定时器），退后台即停；
    /// 开着的时候判定跑在 `BandRefreshDaemon` 里，App 挂起后照跑。
    ///
    /// 两者**互斥**，不能同时开：它们读同一份阈值、各自计时，同时跑会在同一次
    /// 弱信号里刷两次 —— 而用户看到的只是「掉网特别频繁」。所以打开这一个，
    /// 前台那条路就在调用方停掉（见 `AutoRefreshPanels`）。
    var backgroundDaemon = false

    /// 比较方向（2026-10-14 定稿）：只有「RSRP **低于**阈值」一种，而且不带等于。
    /// 这个功能的存在理由就是信号变弱时重载 modem，反向（信号好才刷新）没有场景；
    /// 等于也去掉了 —— RSRP 恰好落在阈值上的那一拍多等一秒没有意义，
    /// 少一个分支就少一处两套执行体（前台 / 守护进程）走偏的机会。
    var enabled = false
    /// 只写日志、不真的刷新。默认开着 —— 见类型头上的说明。
    var dryRun = true
    /// 触发阈值，dBm。默认 -100：LTE 在这个点上通常还能正常通话，
    /// 再往下（-110 之后）就接近脱网了。
    var thresholdDbm = -100
    /// 需要**连续**满足多久才动手，秒。
    ///
    /// 走动中的快衰落能造成 10–20 dB 的瞬时起伏，只看一拍会让阈值被反复越过。
    var dwellSec: Double = 20
    /// 一次刷新之后的冷却，秒。防乒乓的主闸门。
    var cooldownSec: Double = 300
    /// 采样间隔，秒。
    var sampleIntervalSec: Double = 2

    /// **前置开关**：连着 Wi-Fi 时暂停自动刷新。
    ///
    /// 默认**开**。这个功能的存在理由是「信号弱到快脱网、而蜂窝是唯一出路时，
    /// 把 modem 拉回来重注册」；连着 Wi-Fi 时蜂窝本来就不是出路 —— 这时候去重载
    /// modem 只会白掉几秒网，还可能把正在进行的 VoLTE 通话打断。
    ///
    /// **断开 Wi-Fi 后自动恢复**，不需要用户回来重新打开：判定每一拍都重读这一项与
    /// 实时的 Wi-Fi 状态（`sysprobe_wifi_connected()`）。暂停时只停「计时与动手」，
    /// RSRP 照采 —— 界面上仍然看得到当前信号，只是不会累积 `dwell`。
    ///
    /// 后台守护进程 `BandRefreshDaemon.m` 里有一份同样的判定 —— 改这里时改那边。
    var pauseOnWiFi = true

    // MARK: - 存取

    private enum Key {
        static let enabled = "sysprobe.bandAutoRefresh.enabled"
        static let dryRun = "sysprobe.bandAutoRefresh.dryRun"
        static let threshold = "sysprobe.bandAutoRefresh.thresholdDbm"
        static let dwell = "sysprobe.bandAutoRefresh.dwellSec"
        static let cooldown = "sysprobe.bandAutoRefresh.cooldownSec"
        static let interval = "sysprobe.bandAutoRefresh.sampleIntervalSec"
        static let background = "sysprobe.bandAutoRefresh.backgroundDaemon"
        static let pauseOnWiFi = "sysprobe.bandAutoRefresh.pauseOnWiFi"
    }

    static func load() -> BandAutoRefreshConfig {
        let d = UserDefaults.standard
        var c = BandAutoRefreshConfig()
        // `object(forKey:)` 判空而不是 `bool(forKey:)`：后者在键不存在时返回 false，
        // 与「用户显式关掉了」无法区分 —— 那会让默认值反过来覆盖用户的设置。
        if d.object(forKey: Key.enabled) != nil { c.enabled = d.bool(forKey: Key.enabled) }
        if d.object(forKey: Key.background) != nil { c.backgroundDaemon = d.bool(forKey: Key.background) }
        if d.object(forKey: Key.pauseOnWiFi) != nil { c.pauseOnWiFi = d.bool(forKey: Key.pauseOnWiFi) }
        if d.object(forKey: Key.dryRun) != nil { c.dryRun = d.bool(forKey: Key.dryRun) }
        if d.object(forKey: Key.threshold) != nil { c.thresholdDbm = d.integer(forKey: Key.threshold) }
        if d.object(forKey: Key.dwell) != nil { c.dwellSec = d.double(forKey: Key.dwell) }
        if d.object(forKey: Key.cooldown) != nil { c.cooldownSec = d.double(forKey: Key.cooldown) }
        if d.object(forKey: Key.interval) != nil { c.sampleIntervalSec = d.double(forKey: Key.interval) }
        // 采样间隔是定时器的周期，不能是 0（会变成忙等）。
        if c.sampleIntervalSec < 0.5 { c.sampleIntervalSec = 0.5 }
        if c.sampleIntervalSec > 60 { c.sampleIntervalSec = 60 }
        return c
    }

    func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: Key.enabled)
        d.set(backgroundDaemon, forKey: Key.background)
        d.set(pauseOnWiFi, forKey: Key.pauseOnWiFi)
        d.set(dryRun, forKey: Key.dryRun)
        d.set(thresholdDbm, forKey: Key.threshold)
        d.set(dwellSec, forKey: Key.dwell)
        d.set(cooldownSec, forKey: Key.cooldown)
        d.set(sampleIntervalSec, forKey: Key.interval)
    }

    /// 当前值是否满足条件：RSRP **低于**阈值（严格小于，等于不算）。
    ///
    /// RSRP **必须小于 0** 才参与判断：0 是「没读到」的哨兵值（见
    /// `CommCenterBridge.m` 里那条注释），少了这一句它会变成「信号极好」，
    /// 判定逻辑整个反过来。
    ///
    /// 守护进程 `BandRefreshDaemon.m` 里有一份同样的判定 —— 改这里时改那边。
    func matches(_ rsrp: Int) -> Bool {
        guard rsrp < 0 else { return false }
        return rsrp < thresholdDbm
    }
}

/// 自动刷新的驱动与判定。
///
/// ── 它做的是什么 ────────────────────────────────────────────────────────────
///
/// 到点了就调一次 `sysprobe_refresh_modem()`（= 上游 CellularInfo 的
///「刷新蜂窝网络信号」，底层是 `_CTServerConnectionResetModem`）。
/// 它**不改允许频段**，也不杀 CommCenter —— 只是让 modem 重载并重新注册。
///
/// ── 不做什么 ────────────────────────────────────────────────────────────────
///
/// 不做「择优」：`CTSignalStrengthMeasurements` 只有**服务小区**一份 RSRP，
/// 没有按频段或邻区分开的读数，所以拿不到「另一个频段此刻是多少 dBm」。
/// 这一版只回答「什么时候动手」，不回答「动完会更好吗」。
///
/// ── 只在页面前台跑 ──────────────────────────────────────────────────────────
///
/// `Info.plist` 没有 `UIBackgroundModes`，App 退后台就被挂起，定时器随之停摆。
/// 调用方在 `.onDisappear` 里 `stop()` 是同一件事的另一半：切到别的分段也该停。
final class BandAutoRefreshController: ObservableObject {

    enum Phase: Equatable {
        /// 没在计时、也没在冷却。
        case idle
        /// 连着 Wi-Fi，被前置开关按住了 —— 既不计时也不动手。
        case paused
        /// 条件已满足，正在累计持续时间。
        case armed(remaining: Double)
        /// 刚刷新过，冷却中。
        case cooling(remaining: Double)

        var title: String {
            switch self {
            case .idle: return Strings.text("Idle")
            case .paused: return Strings.text("Paused")
            case .armed: return Strings.text("Armed")
            case .cooling: return Strings.text("Cooling down")
            }
        }
    }

    /// 最近一次读到的 RSRP。读不到是 nil（不是 0）。
    @Published private(set) var lastRsrp: Int?
    @Published private(set) var phase: Phase = .idle
    /// 最新的在前。
    @Published private(set) var log: [String] = []
    @Published private(set) var lastRefreshAt: Date?
    /// 最近一拍里 Wi-Fi 是不是连着。
    ///
    /// 由采样那一拍顺带更新，不在视图里现查 —— `getifaddrs` 虽然只要几十微秒，
    /// 但那是每次 body 重算都要跑一次的量级，而 body 一秒重算一次。
    @Published private(set) var wifiConnected = false

    private var timer: Timer?
    private var queue = DispatchQueue(label: "com.corin.sysprobe.bandAutoRefresh")
    private var slot = 1
    private var armedSince: Date?
    private var cooldownUntil: Date?
    /// 上一拍是不是处于「连 Wi-Fi 暂停」—— 只为了在**切换**那一刻写一条日志，
    /// 而不是每拍刷屏。
    private var pausedForWiFi = false

    // MARK: - 生命周期

    func start(slot: Int) {
        stop()
        self.slot = slot
        // **关着就不排拍。**
        //
        // 2026-10-14 修的一条卡顿：这个定时器原来是「进页面就起」，之后每
        // `sampleIntervalSec`（默认 2 秒）做一次同步 XPC（`sysprobe_signal_sync`）
        // 外加一次 `@Published` 更新 —— 而功能本身可能一直是关着的。那是一次
        // 白烧的 XPC 往返，加上整页 body 每 2 秒重算一遍：正好撞在滚动的某一帧上
        // 就是一次掉帧。
        //
        // 打开开关时由调用方再调一次 `start`（见 `AutoRefreshPanels` 里那条
        // `.onChange(of: config.enabled)`）。
        guard BandAutoRefreshConfig.load().enabled else { return }
        // 配置每拍重读，所以这里只管把第一拍排上。
        scheduleNext()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        armedSince = nil
        cooldownUntil = nil
        // 连同「暂停中」的记忆一起清掉：下次 `start` 重新开表时，若仍连着 Wi-Fi，
        // 会在日志里重新记一条「paused」—— 那是新一轮观察的开始，不是重复。
        pausedForWiFi = false
        DispatchQueue.main.async { [weak self] in
            self?.phase = .idle
        }
    }

    private func scheduleNext() {
        let config = BandAutoRefreshConfig.load()
        // 关掉之后从这一拍起就停表，不再排下一拍 —— 见 `start` 里那条说明。
        //
        // 停在这里而不是 `tick` 里：那一拍已经在跑了，让它跑完（顺手把 phase 归位），
        // 由「排下一拍」这一个出口决定要不要继续。
        guard config.enabled else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.timer?.invalidate()
                self.timer = nil
                self.phase = .idle
            }
            return
        }
        let interval = TimeInterval(config.sampleIntervalSec)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                guard let self else { return }
                // 读数是一次同步 XPC（毫秒级），但基带正在重启时可能拖久一点，
                // 所以放到自己的串行队列上，不占主线程。
                self.queue.async { self.tick() }
            }
        }
    }

    // MARK: - 每一拍

    private func tick() {
        let config = BandAutoRefreshConfig.load()
        defer { scheduleNext() }

        guard config.enabled else {
            update { s in
                s.armedSince = nil
                s.phase = .idle
            }
            return
        }

        let raw = sysprobe_signal_sync(Int32(slot)) as? [String: Any]
        let rsrp = (raw?["rsrp"] as? NSNumber)?.intValue

        update { s in
            s.lastRsrp = rsrp
        }

        // ── 前置开关：连着 Wi-Fi 就暂停 ──
        //
        // 位置刻意放在「读数之后、冷却与阈值之前」：暂停时界面上要显示
        // 「Wi-Fi 已连接 · 已暂停」，而不是一条更早的冷却倒计时 —— 后者会让人
        // 以为它还在正常工作。
        //
        // 暂停的是**计时与动手**，不是读数：RSRP 照采，界面上仍看得到当前信号。
        // 判据本身在 `CommCenterBridge.m` 里，与守护进程共用同一份实现。
        let wifi = sysprobe_wifi_connected()
        update { s in
            s.wifiConnected = wifi
        }

        let paused = config.pauseOnWiFi && wifi
        if paused != pausedForWiFi {
            // 只在**切换**那一刻写日志，不然每拍一条会把 30 条日志刷满。
            pausedForWiFi = paused
            update { s in
                s.appendLog(paused
                            ? Strings.text("paused · Wi-Fi connected")
                            : Strings.text("resumed · Wi-Fi disconnected"))
            }
        }
        if paused {
            // 已计的时长清零：否则「Wi-Fi 断开」那一瞬间会拿一段与蜂窝无关的时间
            // 去凑 `dwell`，于是刚恢复就立刻刷一次。
            armedSince = nil
            update { s in
                s.armedSince = nil
                s.phase = .paused
            }
            return
        }

        // 读不到就什么都不做 —— 这一拍不能当成「信号变了」。
        guard let rsrp else { return }

        let now = Date()

        if let until = cooldownUntil, now < until {
            update { s in
                s.phase = .cooling(remaining: until.timeIntervalSince(now))
                s.armedSince = nil
            }
            return
        }
        cooldownUntil = nil

        guard config.matches(rsrp) else {
            update { s in
                s.armedSince = nil
                s.phase = .idle
            }
            return
        }

        let since = armedSince ?? now
        if armedSince == nil { armedSince = now }
        let elapsed = now.timeIntervalSince(since)

        if elapsed < config.dwellSec {
            update { s in
                s.phase = .armed(remaining: config.dwellSec - elapsed)
            }
            return
        }

        // ── 到点，动手 ──
        armedSince = nil
        cooldownUntil = now.addingTimeInterval(config.cooldownSec)
        let line: String
        if config.dryRun {
            line = Strings.text("dry-run %@ dBm → would refresh", "\(rsrp)")
        } else {
            let ok = sysprobe_refresh_modem()
            line = ok
                ? Strings.text("refreshed at %@ dBm", "\(rsrp)")
                : Strings.text("refresh failed at %@ dBm", "\(rsrp)")
        }
        update { s in
            s.lastRefreshAt = now
            s.phase = .cooling(remaining: config.cooldownSec)
            s.appendLog(line)
        }
    }

    /// 把对状态的改动收回主线程。
    ///
    /// 定时器跑在后台队列上，而这些都是 `@Published` —— 直接写会让 SwiftUI 在
    /// 后台线程上收通知。
    private func update(_ block: @escaping (BandAutoRefreshController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            block(self)
        }
    }

    private func appendLog(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        log.insert("\(stamp) \(line)", at: 0)
        if log.count > 30 { log = Array(log.prefix(30)) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
