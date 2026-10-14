import Combine
import SwiftUI

/// 「频段刷新」分段。
///
/// 与「频段锁定」并列在「频段」分页下 —— 两者读的是同一套基带状态，放在一起才说得清
/// 「锁了哪几个频段」与「什么时候刷新」的关系。
///
/// ── 它执行的是「刷新」，不是「重启」，也不是「换频段」 ──────────────────────────
///
/// 到点了执行 `sysprobe_refresh_modem()` —— 上游 CellularInfo 的「刷新蜂窝网络信号」
/// 同款（`_CTServerConnectionResetModem`），让 modem 重载并重新注册，**CommCenter
/// 进程不动**。它既不是杀掉蜂窝服务（「频段锁定」分段顶部那个「重启」按钮），也不改
/// 允许频段。代价仍然是掉网数秒，所以默认关闭、且默认只写日志。
struct AutoRefreshPanels: View {

    @StateObject private var controller = BandAutoRefreshController()
    /// 后台那条路的状态。单例由 `RootView` 起的看门狗喂，这里只是读它。
    @ObservedObject private var daemon = BandRefreshDaemonBridge.shared
    /// 界面上的值。改完立刻 `save()` —— 引擎每拍重新 `load()`，所以不用重开开关。
    @State private var config = BandAutoRefreshConfig.load()
    @State private var slot = 1

    // MARK: - 倒计时的本地时钟
    //
    // ── 为什么界面不能直接显示数据源给的 `remaining`（2026-10-14 修）──────────
    //
    // 那个值是**拍报**，不是连续值：
    //
    //   · 后台模式下，守护进程写状态文件，而 App 侧的看门狗**每 10 秒**才回读一次
    //     （`BandRefreshDaemonBridge.startWatchdog`）—— 界面拿到的 `remaining`
    //     因此 10 秒才变一次。用户看到的就是「倒计时 10 秒才跳一下」，而这与倒计时
    //     本身没有任何关系。
    //   · 前台模式下，`remaining` 跟着**采样间隔**更新，而那个间隔用户能调到 30 秒。
    //
    // 这里改成记「拿到剩余秒数的那一刻 + 当时的秒数」，之后由本地的每秒时钟相减外推。
    // 数据源多久刷新一次都不影响走字 —— 这是修复的全部依据。

    /// 倒计时锚点。`nil` = 当前不在倒计时（待机 / 已暂停 / 未触发）。
    @State private var countdownAnchor: CountdownAnchor?

    /// 本地时钟。只做一件事：每秒变一次，把 body 重算一遍，让外推的剩余秒数跟着走。
    @State private var now = Date()

    /// 每秒一拍的时钟源。
    ///
    /// `.common` 而不是 `.default`：`ScrollView` 滚动时 run loop 会切到 tracking mode，
    /// `.default` 的定时器在滚动期间不触发 —— 倒计时就会「一滚就僵住」。
    ///
    /// 放 `static let`：`autoconnect()` 的 publisher 在最后一个订阅者移除时会自己断开，
    /// 视图消失不会留下跑着的定时器；而写成实例属性的话，body 每次重算都要新建一个。
    private static let secondTick = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                actionPanel
                statusPanel
                if !displayedLog.isEmpty {
                    logPanel
                }
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .task {
            // **必须丢到 detached 里跑**：`preferredSlot()` 里是几次**同步 XPC**
            // （`sysprobe_slot_has_sim` 每次两下、`sysprobe_preferred_data_slot` 一下），
            // 而 `.task` 跑在主 actor 上 —— 留在主线程会卡住进这一分段的第一帧。
            // 与 `BandPanels` 同一条理由。
            let preferred = await Task.detached { BandService.preferredSlot() }.value
            slot = preferred
            syncExecutor()
            // 进来先把倒计时锚点立起来 —— `onChange` 只在下一次**变化**时触发，
            // 少了这一下，进来时已经在倒计时的话第一秒显示的是数据源原值。
            resetCountdownAnchor()
            // 幂等：它已经在跑就什么都不做。放在这里而不是只靠 RootView，
            // 是为了让「刚装完第一次进这一页」也能立刻知道守护进程在不在。
            BandRefreshDaemonBridge.shared.startWatchdog()
            BandRefreshDaemonBridge.shared.refreshState()
        }
        // 锚点跟着数据源走：它一报新的剩余秒数，就以那一刻重新起算。
        .onChange(of: countdownSource) { _ in resetCountdownAnchor() }
        // 每秒把 body 重算一遍，让外推出来的剩余秒数跟着走。见 `secondTick` 与
        // `countdownAnchor` 的说明 —— 这是「倒计时每秒递减」的全部机制。
        .onReceive(Self.secondTick) { now = $0 }
        // 参数一改就落盘，并**同步下发**给守护进程 —— 它每轮重读配置，
        // 所以改完立刻生效，不用重启进程、也不用重开开关。
        .onChange(of: config) { newValue in
            newValue.save()
            BandRefreshDaemonBridge.shared.writeConfig(newValue, slot: slot)
        }
        // 只有「换执行体」才需要动前台那条定时器：阈值之类的参数它自己会重读。
        .onChange(of: config.backgroundDaemon) { _ in syncExecutor() }
        // 开关本身也要跟着：关着的时候那条定时器**完全不排拍**（`start` 里的守卫），
        // 所以打开它必须重新 `start` 一次，否则界面上「开了」却一动不动。
        .onChange(of: config.enabled) { _ in syncExecutor() }
        // 切走分段就停表。后台模式关着时 App 退后台本来也会被挂起；
        // 这里补的是「还在 App 里但不在这一页」那一段。
        //
        // 倒计时的每秒时钟不用在这里停：它是 `onReceive` 的订阅，视图消失时自己断。
        .onDisappear {
            controller.stop()
        }
    }

    /// 前台定时器与后台守护进程**二选一**。
    ///
    /// 两个都开着会在同一次弱信号里刷两次 —— 它们读同一份阈值、各自计时，
    /// 而用户看到的只是「掉网特别频繁」。
    private func syncExecutor() {
        if config.backgroundDaemon {
            controller.stop()
        } else {
            controller.start(slot: slot)
        }
    }

    // MARK: - 参数

    private var actionPanel: some View {
        // 标题不叫「自动刷新」：导航栏标题已经是它了（分段名），面板再写一遍会重复。
        Panel("Parameters", systemImage: "arrow.clockwise") {
            VStack(alignment: .leading, spacing: 10) {
                toggle("Enabled", isOn: $config.enabled)
                // 前置开关（2026-10-14 要求）：连着 Wi-Fi 时暂停，断开自动恢复。
                //
                // 紧挨着「启用」放，因为它管的就是「这个功能什么时候该让路」——
                // 与下面那些阈值不是一个层级的东西。默认开，见
                // `BandAutoRefreshConfig.pauseOnWiFi` 的说明。
                //
                // 后台模式下**同样生效**：这一项会随配置一起下发到守护进程
                // （见 `BandRefreshDaemonBridge.writeConfig`），判定在那边重跑一遍。
                toggle("Pause on Wi-Fi", isOn: $config.pauseOnWiFi)
                // 只有包里真的有守护进程时才给出这一项 —— 否则它是「能点、点了什么都不发生」，
                // 而这件事在界面上完全看不出来。
                if daemon.bundled {
                    toggle("Run in background", isOn: $config.backgroundDaemon)
                }
                toggle("Log only (do not refresh)", isOn: $config.dryRun)

                // 触发方向不再可选（2026-10-14）：只有「RSRP 低于阈值」一种 ——
                // 这个功能的存在理由就是信号变弱时重载 modem。
                stepper(value: $config.thresholdDbm, in: -125...(-70), step: 1,
                        label: "Trigger threshold",
                        valueText: "\(config.thresholdDbm) dBm")
                stepper(value: $config.dwellSec, in: 0...120, step: 5,
                        label: "Sustained for",
                        valueText: Strings.text("%lld s", Int(config.dwellSec)))
                stepper(value: $config.cooldownSec, in: 30...1800, step: 30,
                        label: "Cooldown",
                        valueText: Strings.text("%lld s", Int(config.cooldownSec)))
                stepper(value: $config.sampleIntervalSec, in: 1...30, step: 1,
                        label: "Sample every",
                        valueText: Strings.text("%lld s", Int(config.sampleIntervalSec)))

                // 「信号弱于 -100 且持续 20 秒」比四行开关更能说明它在等什么。
                Text(verbatim: summary)
                    .font(AppFont.text(12))
                    .foregroundStyle(Color.mwMuted)
            }
            .onChange(of: config) { newValue in
                newValue.save()
            }
        }
    }

    private var summary: String {
        let base = "RSRP < \(config.thresholdDbm) dBm for \(Int(config.dwellSec))s → refresh, then wait \(Int(config.cooldownSec))s"
        // 前置开关开着时把这件事说在参数摘要里 —— 否则「怎么一直不动手」没有解释。
        guard config.pauseOnWiFi else { return base }
        return base + " · " + Strings.text("paused while Wi-Fi is connected")
    }

    // MARK: - 状态

    /// 状态区读谁，取决于现在用哪个执行体。
    ///
    /// 两条路的字段形状不一样（前台是枚举、后台是守护进程写死的英文 phase），
    /// 在这里归一成两三个值，下面那些行就不用各写一遍分支。
    private var displayedRsrp: Int? {
        config.backgroundDaemon ? daemon.state.lastRsrp : controller.lastRsrp
    }

    private var displayedLog: [String] {
        let lines = config.backgroundDaemon ? daemon.state.log : controller.log
        // 两条路的日志要在这里归一成同一种语言：前台那条路本来就是本地化过的中文；
        // 守护进程那一侧写的是英文原文（它进程里没有本地化能力），逐行翻过来。
        // 见 `displayLine` —— 翻译只发生在界面上，状态文件里的原文不动。
        return config.backgroundDaemon ? lines.map(Self.displayLine) : lines
    }

    /// 把守护进程报回来的日志行翻成界面文案。
    ///
    /// ── 为什么要单独翻一遍 ────────────────────────────────────────────────────
    ///
    /// 守护进程是一个 clang 直编的裸可执行文件，不带 `.lproj`，进程里也没有本地化
    /// 能力 —— 它写进状态文件的是英文字面量。前台那条路（`BandAutoRefreshController`）
    /// 用的是 `Strings.text(...)`，本来就是中文。两条路显示的同一件事却不一样语言，
    /// 用户看着会以为后台那条坏了。
    ///
    /// **翻译只发生在界面上，状态文件保持英文原文** —— 那是对着真机日志排查问题时
    /// 唯一能核对的凭据，跟着界面一起改会让两边对不上。
    ///
    /// 做法是按行为前缀映射到文案表里**已有的那些键**（前台那条路用的正是同一批），
    /// 所以前后台说的是同一句话。认不出的行原样返回：守护进程以后新增行为不至于
    /// 显示成空白。
    private static func displayLine(_ line: String) -> String {
        // 行首是 "HH:mm:ss "，后面才是内容。
        guard let split = line.firstIndex(of: " ") else { return translated(line) }
        let stamp = String(line[line.startIndex...split])
        return stamp + translated(String(line[line.index(after: split)...]))
    }

    /// 日志里**除 RSRP 以外**的部分：去掉时间戳，按前缀映射到本地化文案。
    private static func translated(_ body: String) -> String {
        let payload: String = {
            let words = body.components(separatedBy: " ")
            return words.count >= 2 ? words[1] : ""
        }()
        if body.hasPrefix("dry-run ") {
            return Strings.text("dry-run %@ dBm → would refresh", payload)
        }
        if body.hasPrefix("refreshed at ") {
            return Strings.text("refreshed at %@ dBm", payload)
        }
        if body.hasPrefix("refresh failed at ") {
            return Strings.text("refresh failed at %@ dBm", payload)
        }
        if body == "paused · Wi-Fi connected" {
            return Strings.text("paused · Wi-Fi connected")
        }
        if body == "resumed · Wi-Fi disconnected" {
            return Strings.text("resumed · Wi-Fi disconnected")
        }
        return body
    }

    /// 界面显示哪一侧的 Wi-Fi 状态。
    ///
    /// 两条执行体各判各的：前台是 `controller` 每拍顺带查一次，后台是守护进程写在
    /// 状态文件里的那一份（那时 App 内那条定时器是停着的，自己不会去查）。
    private var displayedWifi: Bool {
        config.backgroundDaemon ? daemon.state.wifiConnected : controller.wifiConnected
    }

    private var statusPanel: some View {
        Panel("Current network", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 10) {
                row("Slot", Strings.text("Slot %d", slot))
                row("RSRP", displayedRsrp.map { "\($0) dBm" } ?? "—")
                row("State", phaseText)
                // 这一行是前置开关唯一的「看得见」的凭据：开关开着却没暂停时，
                // 要么是这里显示未连接，要么是暂停逻辑没生效 —— 两者分得开。
                //
                // 只在开关开着时显示：关着的时候这一行没有解释力（功能根本没开，
                // 暂停与否都不是它决定的），而这一页的每一行都在回答「为什么它没动」。
                if config.pauseOnWiFi {
                    row("Wi-Fi", displayedWifi ? Strings.text("Connected") : Strings.text("Not connected"))
                }
                if config.backgroundDaemon {
                    row("Background service", daemonAliveText)
                }
                if let at = lastRefreshText {
                    row("Last refresh", at)
                }
            }
        }
    }

    private var lastRefreshText: String? {
        let date = config.backgroundDaemon ? daemon.state.lastRefreshAt : controller.lastRefreshAt
        return date.map { Self.timeFormatter.string(from: $0) }
    }

    /// 数据源报回来的「剩余秒数」。`nil` = 当前不在倒计时（待机 / 已暂停 / 未触发）。
    ///
    /// **它只用来立锚点，不用来直接显示** —— 见 `countdownAnchor` 头上那段说明。
    private var countdownSource: Double? {
        if config.backgroundDaemon {
            guard daemon.state.alive else { return nil }
            switch daemon.state.phase {
            case "armed", "cooling": return daemon.state.remaining
            default: return nil
            }
        }
        switch controller.phase {
        case .armed(let remaining), .cooling(let remaining): return remaining
        default: return nil
        }
    }

    /// 以「现在」重新起算倒计时锚点。数据源一报新的剩余秒数就调一次。
    private func resetCountdownAnchor() {
        guard let remaining = countdownSource else {
            countdownAnchor = nil
            return
        }
        countdownAnchor = CountdownAnchor(at: Date(), remaining: remaining)
    }

    /// 当前该显示的剩余秒数 = 锚点记下的秒数 − 本地时钟走过的部分。
    ///
    /// 夹到 0：数据源下一拍到来之前若已经走完，显示 `0 s left` 而不是负数。
    private var displayedRemaining: Double? {
        guard let anchor = countdownAnchor else { return nil }
        let left = anchor.remaining - now.timeIntervalSince(anchor.at)
        return left > 0 ? left : 0
    }

    /// 倒计时读数的整秒数。锚点还没立起来（进页面那一帧）时退回数据源原值。
    private func secondsLeft(_ fallback: Double) -> Int {
        Int((displayedRemaining ?? fallback).rounded(.up))
    }

    private var phaseText: String {
        if config.backgroundDaemon {
            // 守护进程写的是英文 phase 字符串（它进程里没有本地化），在这里翻。
            switch daemon.state.phase {
            case "armed":
                return Strings.text("Triggered · %lld s left", secondsLeft(daemon.state.remaining))
            case "cooling":
                return Strings.text("Cooling down · %lld s left", secondsLeft(daemon.state.remaining))
            case "paused":
                return Strings.text("Paused · Wi-Fi connected")
            case "idle":
                return Strings.text("Watching")
            default:
                return Strings.text("Idle")
            }
        }
        switch controller.phase {
        case .idle:
            return controller.lastRsrp == nil
                ? Strings.text("Idle")
                : Strings.text("Watching")
        case .paused:
            return Strings.text("Paused · Wi-Fi connected")
        case .armed(let remaining):
            return Strings.text("Triggered · %lld s left", secondsLeft(remaining))
        case .cooling(let remaining):
            return Strings.text("Cooling down · %lld s left", secondsLeft(remaining))
        }
    }

    /// 守护进程到底在不在跑。
    ///
    /// 这一行存在的理由：它是唯一能把「没拉起来」「拉起来但被 CommCenter 拒了」
    /// 与「在跑但还没到触发条件」分开的地方 —— 三者界面上都表现为「日志是空的」。
    private var daemonAliveText: String {
        guard daemon.bundled else { return Strings.text("Not available") }
        guard config.enabled else { return Strings.text("Idle") }
        return daemon.state.alive ? Strings.text("Running") : Strings.text("Starting")
    }

    private var logPanel: some View {
        Panel("Recent activity", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(displayedLog.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(AppFont.text(11, weight: .regular))
                        .foregroundStyle(Color.mwMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 上面两行是**警告**（掉网 / 通话中断 / 只在什么条件下跑），走红色。
            Group {
                Text("Refreshing reloads the modem and re-registers on the network. Cellular service drops for a few seconds; ongoing calls may drop. It does not change your locked bands.")
                Text(config.backgroundDaemon
                     ? "Runs in a separate root process, so it keeps working after you leave the app. It stops when the phone restarts — open SysProbe once to bring it back."
                     : "Only runs while this page is in the foreground — the app has no background modes.")
            }
            .font(AppFont.text(11))
            .foregroundStyle(Color.mwDanger)

            // 前置开关的说明。它是**行为说明**不是警告，所以不跟着上面走红色 ——
            // 一屏红色文字里多一句正常说明，只会让人以为它也出了什么问题。
            if config.pauseOnWiFi {
                Text("While Wi-Fi is connected the countdown and the refresh are held, and it resumes by itself once Wi-Fi drops. Applies to background mode as well.")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 控件

    private func toggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(AppFont.text(13))
    }

    /// `V: Strideable` 而不是 `BinaryInteger`：阈值与间隔里既有 `Int` 也有 `Double`
    /// （`Stepper` 自己的泛型约束就是 `Strideable`，`step` 的类型是 `V.Stride`）。
    /// 左标签右值 —— 只有一串数字的 stepper 看不出它在调什么。
    private func stepper<V: Strideable>(value: Binding<V>, in range: ClosedRange<V>,
                                        step: V.Stride, label: LocalizedStringKey,
                                        valueText: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(AppFont.text(13))
                    .foregroundStyle(Color.mwMuted)
                Spacer(minLength: 8)
                Text(verbatim: valueText)
                    .font(AppFont.text(13, weight: .semibold))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(AppFont.text(13))
                .foregroundStyle(Color.mwMuted)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(AppFont.text(13, weight: .semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 倒计时锚点：拿到剩余秒数的那一刻，以及那一刻的剩余值。
    ///
    /// `nonisolated`：它只是一对值，不碰任何 UI 状态；默认的 MainActor 隔离会让
    /// `Equatable` 的合成实现与协议要求（`nonisolated`）对不上，Swift 6 语言模式下
    /// 直接编译不过。
    nonisolated private struct CountdownAnchor: Equatable {
        let at: Date
        let remaining: Double
    }
}
