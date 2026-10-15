import SwiftUI

/// 「频段」分页 —— 2026-10-15 起是**单页**：频段锁定在上、自动刷新在下。
///
/// ── 从「分段 + 外壳」收成单页 ────────────────────────────────────────────────
///
/// 原来这一页是 `PageHubScaffold` + 两个分段（频段锁定 / 频段刷新），靠一个 `Picker`
/// 切。按要求取消分段，两段内容顺次排下来 —— 于是这一页与「硬件」页是同一种结构
/// （`PageScaffold` + 一串卡片）。`BandSegment` 那个枚举一并删掉。
///
/// 顺序即前提关系：**「锁哪些频段」是「什么时候重载 modem」的前提**，先说前者。
/// 顺带按同一次要求做了三件事：两张同名的「当前网络」卡片并成一张（见
/// `RefreshStatusRows`）、4G 频段卡片默认折叠（见 `BandPanels.bandPanel`）、
/// 刷新引擎的状态行落在「当前网络」卡片下半截。
///
/// ── 为什么这一层持有 `BandService` 与自动刷新的参数 ──────────────────────────
///
/// 两样都是**页面级**状态，不是某一段内容的：
///
///   · `BandService` 原来挂在 `BandPanels` 上。单页之后它还是只有一处用，但挂在
///     页面层之后，这一页以后再拆也不会重读一遍基带；
///   · 自动刷新的参数与引擎启停**必须**在页面层：下面那一组卡片在 `LazyVStack` 里
///     位于频段网格之后，进页面时根本不会被创建，挂在它 `.task` 上的定时器于是
///     永远不开始跑 —— 用户不滚下去就什么都看不到。详见 `AutoRefreshPanels` 类型头。
struct BandView: View {

    /// 右上角齿轮的回调，由 `RootView` 给。
    let openSettings: @MainActor (SettingsDestination) -> Void

    /// 频段会话：基带读回来的数据 + 当前卡槽。
    @StateObject private var bands = BandService()

    /// 自动刷新的参数。**持在这一层** —— 理由见类型头。
    @State private var refreshConfig = BandAutoRefreshConfig.load()

    /// 自动刷新的前台引擎。**共享实例**（见 `BandAutoRefreshController.shared`）：
    /// 「当前网络」卡片与「参数」卡片读的必须是同一份状态、同一条定时器 ——
    /// 两处各建一个实例就会有两个定时器各自计时、各自刷新。
    @ObservedObject private var refresh = BandAutoRefreshController.shared

    /// 当前数据卡槽。探一次，两边共用 —— 引擎按它读数，下发给守护进程的配置也带它。
    @State private var slot = 1

    var body: some View {
        PageScaffold("Bands", glow: .mwAccent, openSettings: openSettings) {
            BandPanels(service: bands, refreshConfig: refreshConfig)
            AutoRefreshPanels(config: $refreshConfig)
        }
        .task {
            // **必须丢到 detached 里跑**：`preferredSlot()` 里是几次**同步 XPC**
            // （`sysprobe_slot_has_sim` 每次两下、`sysprobe_preferred_data_slot` 一下），
            // 而 `.task` 跑在主 actor 上 —— 留在主线程会卡住进这一页的第一帧。
            let preferred = await Task.detached { BandService.preferredSlot() }.value
            slot = preferred
            // 引擎的启停归这一层：下面那一组卡片进页面时不会被创建（见类型头）。
            syncRefreshExecutor()
            // 幂等：它已经在跑就什么都不做。`RootView` 那边也起过一次 ——
            // 这里再调一次是为了让「刚装完第一次进这一页」也能立刻知道守护进程在不在。
            BandRefreshDaemonBridge.shared.startWatchdog()
            BandRefreshDaemonBridge.shared.refreshState()
        }
        // 参数一改就落盘，并**同步下发**给守护进程 —— 它每轮重读配置，
        // 所以改完立刻生效，不用重启进程、也不用重开开关。
        .onChange(of: refreshConfig) { newValue in
            newValue.save()
            BandRefreshDaemonBridge.shared.writeConfig(newValue, slot: slot)
        }
        // 只有「换执行体」才需要动前台那条定时器：阈值之类的参数它自己会重读。
        //
        // 与上面那条分开是必需的，不是重复：`start()` 会先 `stop()`，而 `stop()`
        // 会把正在累计的 `armedSince` 清掉 —— 若把这两件事合并成「任何参数变化都
        // 重排定时器」，用户在倒计时中调一下阈值就会把已经攒了几秒的持续时间抹掉。
        .onChange(of: refreshConfig.backgroundDaemon) { _ in syncRefreshExecutor() }
        // 开关本身也要跟着：关着的时候那条定时器**完全不排拍**（`start` 里的守卫），
        // 所以打开它必须重新 `start` 一次，否则界面上「开了」却一动不动。
        .onChange(of: refreshConfig.enabled) { _ in syncRefreshExecutor() }
        // 离开这一页就停表。App 退后台本来也会被挂起，这里补的是「还在 App 里
        // 但不在这一页」那一段。
        .onDisappear { refresh.stop() }
    }

    /// 前台定时器与后台守护进程**二选一**。
    ///
    /// 两个都开着会在同一次弱信号里刷两次 —— 它们读同一份阈值、各自计时，
    /// 而用户看到的只是「掉网特别频繁」。
    ///
    /// 「开关关掉」不用在这里再判一次：`refresh.start` 内部第一条就是 `guard
    /// config.enabled else { return }`，而它进来先 `stop()`，所以关着时它自己会停。
    private func syncRefreshExecutor() {
        if refreshConfig.backgroundDaemon {
            refresh.stop()
        } else {
            refresh.start(slot: slot)
        }
    }
}
