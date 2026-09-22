import Combine
import Foundation

/// 充电控制的运行时状态：守护进程活没活、当前配置、电池读数。
///
/// 三件事各有各的节奏，所以是三个独立的定时器，不是一个：
///
/// | 干什么 | 周期 | 为什么是这个周期 |
/// |---|---|---|
/// | 看 1230 端口、必要时把守护进程拉起来 | 10 秒 | 与 ChargeLimiter 原版一致。守护进程自己会忽略 SIGHUP/SIGTERM，所以**正常情况这里什么都不做** —— 它只在「App 被划掉、守护进程被系统回收、用户又打开 App」时才真正起作用 |
/// | 拉电池读数 | 1 秒 | 这一页显示的是一块电池的实时读数，跟 App 其它页一个节奏 |
/// | 拉配置 | 5 秒 | 配置只可能被「快捷指令」这类外部途径改，没必要一秒一问 |
///
/// ## 关于「App 被划掉之后还管不管用」
///
/// 管用，而且是**设计如此**。守护进程是独立进程，`main` 里对 TrollStore 环境
/// 显式 `signal(SIGHUP, SIG_IGN)` + `signal(SIGTERM, SIG_IGN)`（见 `daemon.mm`），
/// 系统拿它没办法；它自己挂在一条独立的 `NSRunLoop` 上，与 App 的生死无关。
/// 本类里的定时器只负责「发现它不在了就重新拉起来」，不是它的生命线。
@MainActor
final class ChargeControlService: ObservableObject {

    // MARK: Published

    @Published private(set) var config = ChargeConfig()
    @Published private(set) var battery = ChargeBatteryInfo()
    /// 1230 端口上有人在监听 —— 也就是守护进程活着。
    @Published private(set) var daemonRunning = false
    /// 至少成功读到过一次配置。界面靠它区分「还没读到」与「读到了，值恰好是默认」。
    @Published private(set) var loaded = false

    // MARK: Derived

    /// 守护进程没有被打进包里。本地直接 `xcodebuild`（不走 `scripts/build-ipa.sh`）
    /// 时会是这样 —— 那个二进制由构建脚本从上游 tipa 里取出来放进包根目录。
    var daemonBundled: Bool { daemonPath != nil }

    /// 包根目录下的守护进程路径。
    ///
    /// 它读的 web root 是 `NSBundle.mainBundle.bundlePath + "/www"`；对一个**裸可执行文件**
    /// 来说 `mainBundle.bundlePath` 就是它所在的目录，也就是 `SysProbe.app` —— 所以
    /// 二进制与 `www` 必须同时躺在包根目录，层级不能变（见 `project.yml`）。
    private var daemonPath: String? {
        let path = Bundle.main.bundlePath + "/ChargeLimiterDaemon"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: Timers

    private var watchdog: AnyCancellable?
    private var batteryTicker: AnyCancellable?
    private var configTicker: AnyCancellable?
    private var inFlight = false

    // MARK: Lifecycle

    /// 起搏。挂在 App 的采样生命周期上（见 `MonitorLifecycle`），跟着前台／后台走。
    func start() {
        // 先立刻查一次：多数情况下守护进程早就活着（它比 App 命长），
        // 界面一打开就该显示「运行中」，而不是等 10 秒。
        ensureDaemon()

        if watchdog == nil {
            watchdog = Timer.publish(every: 10, on: .main, in: .default)
                .autoconnect()
                .sink { [weak self] _ in
                    Task { @MainActor in self?.ensureDaemon() }
                }
        }

        if batteryTicker == nil {
            batteryTicker = Timer.publish(every: 1, on: .main, in: .default)
                .autoconnect()
                .sink { [weak self] _ in
                    Task { @MainActor in await self?.pollBattery() }
                }
        }

        if configTicker == nil {
            configTicker = Timer.publish(every: 5, on: .main, in: .default)
                .autoconnect()
                .sink { [weak self] _ in
                    Task { @MainActor in await self?.pollConfig() }
                }
        }

        // 先立刻读一次：定时器要等一个周期才第一次触发，而界面一打开就该有数。
        Task { @MainActor in
            await self.pollConfig()
            await self.pollBattery()
        }
    }

    /// 退到后台就停表。守护进程不受影响 —— 见类型头上的说明。
    func pause() {
        watchdog?.cancel(); watchdog = nil
        batteryTicker?.cancel(); batteryTicker = nil
        configTicker?.cancel(); configTicker = nil
    }

    // MARK: 守护进程

    /// 端口没人听就把守护进程拉起来。
    ///
    /// 重复调用是安全的：守护进程 `serve` 的第一件事就是查一次同一个端口，
    /// 已经有人在听就 `exit(0)`。所以就算这里和它自己的启动抢上了，也只会多一个
    /// 立刻退出的进程，不会有两个服务。
    private func ensureDaemon() {
        if sysprobe_local_port_open(Int32(ChargeBridge.port)) != 0 {
            daemonRunning = true
            return
        }
        daemonRunning = false

        guard let path = daemonPath else { return }
        // 返回 0 只说明进程起来了，端口还没绑上（要几百毫秒）。这里**不**改
        // `daemonRunning` —— 下一轮 10 秒的检查会把真实结果带回来。乐观地报「运行中」
        // 只会让界面在真正失败时骗人。
        _ = sysprobe_spawn_root_daemon(path)
    }

    // MARK: 读

    private func pollConfig() async {
        guard let fresh = await ChargeBridge.config() else {
            daemonRunning = false
            return
        }
        config = fresh
        loaded = true
        daemonRunning = true
    }

    private func pollBattery() async {
        // 一次只允许一个在飞：本地请求 2 秒超时，而这里一秒一问 —— 服务卡住时
        // 不设这道闸，请求会越堆越多。
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        guard let fresh = await ChargeBridge.batteryInfo() else {
            daemonRunning = false
            return
        }
        battery = fresh
        daemonRunning = true
    }

    // MARK: 写
    //
    // 一律**先改本地再发请求**：这些都是开关和滑块，本地立刻生效才有手感；
    // 万一写失败，5 秒后的那轮配置同步会把它改回来 —— 界面自己纠正，不用提示。

    func setEnable(_ on: Bool) {
        config.enable = on
        Task { _ = await ChargeBridge.set("enable", on) }
    }

    func setMode(_ mode: ChargeMode) {
        config.mode = mode
        Task { _ = await ChargeBridge.set("mode", mode.rawValue) }
    }

    func setUpdateFrequency(_ seconds: Int) {
        config.updateFrequency = seconds
        Task { _ = await ChargeBridge.set("update_freq", seconds) }
    }

    func setAction(_ action: ChargeAction) {
        config.action = action.rawValue
        Task { _ = await ChargeBridge.set("action", action.rawValue) }
    }

    func setChargeBelow(_ percent: Int) {
        config.chargeBelow = percent
        Task { _ = await ChargeBridge.set("charge_below", percent) }
    }

    func setChargeAbove(_ percent: Int) {
        config.chargeAbove = percent
        Task { _ = await ChargeBridge.set("charge_above", percent) }
    }

    func setTemperatureControl(_ on: Bool) {
        config.enableTemperature = on
        Task { _ = await ChargeBridge.set("enable_temp", on) }
    }

    func setTemperatureAbove(_ celsius: Int) {
        config.temperatureAbove = celsius
        Task { _ = await ChargeBridge.set("charge_temp_above", celsius) }
    }

    func setTemperatureBelow(_ celsius: Int) {
        config.temperatureBelow = celsius
        Task { _ = await ChargeBridge.set("charge_temp_below", celsius) }
    }

    func setPreferSmartBattery(_ on: Bool) {
        config.preferSmartBattery = on
        Task { _ = await ChargeBridge.set("adv_prefer_smart", on) }
    }

    func setPredictiveInhibit(_ on: Bool) {
        config.predictiveInhibit = on
        Task { _ = await ChargeBridge.set("adv_predictive_inhibit_charge", on) }
    }

    func setDisableInflow(_ on: Bool) {
        config.disableInflow = on
        Task { _ = await ChargeBridge.set("adv_disable_inflow", on) }
    }

    func setThermalMode(_ mode: CuffMode) {
        config.thermalMode = mode
        Task { _ = await ChargeBridge.set("adv_def_thermal_mode", mode.rawValue) }
    }

    func setPPMMode(_ mode: CuffMode) {
        config.ppmMode = mode
        Task { _ = await ChargeBridge.set("ppm_simulate_mode", mode.rawValue) }
    }

    func setLimitInflow(_ on: Bool) {
        config.limitInflow = on
        Task { _ = await ChargeBridge.set("adv_limit_inflow", on) }
    }

    /// 「正在充电」是即时动作，不走配置 —— 它直接对 IOPMPS 服务写 `ExternalConnected`。
    func setCharging(_ on: Bool) {
        battery.isCharging = on
        Task { _ = await ChargeBridge.setChargeStatus(on) }
    }

    func resetConfig() {
        Task { @MainActor in
            guard await ChargeBridge.resetConfig() else { return }
            await self.pollConfig()
        }
    }
}
