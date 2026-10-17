import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

    /// 频段页里的「隐藏这一页」写的就是它。关掉之后第 4 个分页整体消失。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    var body: some View {
        ZStack {
            // 最底下一层不透明画布色。转场里任何一帧上层还没画上内容时，露出来的都是它，
            // 而不是窗口底色（浅色下白、深色下黑）—— 后者正是「闪一下」的来源。
            Color.mwCanvas.ignoresSafeArea()

            tabs
                // 语言是喂给环境的，不是喂给 `Bundle.main` 的。
                //
                // SwiftUI 的 `Text("…")` 不看 `Bundle.main.localizedString(...)`，它按环境里
                // 这个 `locale` 直接去 bundle 的 `.lproj` 里挑译文 —— 全 App 一起换语言，
                // 靠的就是这一句。挂在这里而不是 `tabs` 里面，全屏覆盖层（现在没有了）
                // 与任何浮层才继承得到。
                .environment(\.locale, app.language.locale)
                // 负一屏那一下点击会带 `sysprobe://open` 进来（见
                // `TodayViewController.openApp`）。这里刻意**不动分页** ——
                // 用户是来看数据的，停在上次看的那一屏更自然。
                .onOpenURL { _ in }
                // 齿轮菜单里的两个弹层都挂在这里，不在 `tabs` 里面 —— `tabs` 会随
                // 语言换 identity，挂里面的话用户在弹层里切完语言，弹层会被自己
                // 触发的重建关掉。
                //
                // 用 `.sheet(item:)` 而不是两个 `.sheet(isPresented:)`：同一时刻只可能
                // 有一个弹层，写成两个布尔就会出现「两个同时为真」这种表达得出来、
                // 但不该存在的状态。
                .sheet(item: $app.settingsSheet) { destination in
                    switch destination {
                    case .maintenance: MaintenanceSheet()
                    case .about: AboutView()
                    }
                }
                // 采样的生命周期单独放进一个零尺寸视图。
                //
                // 独立出来是为了把每秒一次的 `PowerSnapshot` 发布挡在 `RootView` 之外：
                // 这里 body 里是整棵 `TabView`，让它跟着每秒重算，既白费功夫，
                // 也会让分页切换的转场动画被反复打断。
                .overlay(
                    MonitorLifecycle()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                )
        }
        // 后台那条「自动刷新」的看门狗在 App 这一级起，不在频段页里 ——
        //
        // 它要的只是「用户打开 App 时顺手确认一下守护进程还在不在」，与当前在哪一屏
        // 无关。挂在分页里的话，用户停在「硬件」页时它根本不会跑，于是「手机重启后
        // 开一次 App 就能复活」这句话就不成立了 —— 而那正是没有 LaunchDaemon 自启时
        // 唯一的复活途径。
        //
        // 幂等：已经在跑就什么都不做。
        .task { BandRefreshDaemonBridge.shared.startWatchdog() }
        // 齿轮回来了 —— 它装的是「关于」（版本 / 发布日期 / 诊断）。
        // 2026-10-14：第 4 个分页让给了「频段」，关于回到这里，与 0.0.30 之前一致。
        //
        // **没有语言切换**：应用语言已改为随系统，界面上不再有这个入口。
    }

    /// 打开齿轮下拉菜单里的某一项。
    ///
    /// 以普通闭包往下传，而不是让每页都去观察 `AppState`：观察 `AppState` 就意味着
    /// `settingsSheet` / `selectedTab` / `language` 任何一个变化都会让四个分页各重算
    /// 一次 —— 而这一帧恰好就是弹层开始做呈现动画的那一帧。齿轮只需要一个动作。
    private var openSettings: @MainActor (SettingsDestination) -> Void {
        { app.settingsSheet = $0 }
    }

    /// 语言一变，整棵分页树换 identity。
    ///
    /// 译文由环境 locale 决定，换 locale 时 SwiftUI 会自己重算；但**字形**不是 ——
    /// `AppFont` 读的是 `AppLanguage.current` 这个全局（中文要退回 `.default` 设计，
    /// 否则汉字会掉回苹方 SC，与同行拉丁字重、基线都不齐）。换 identity 是最省事的
    /// 兜底，保证字形、字距、大小写跟译文一起换。`selection` 绑在 `app.selectedTab`
    /// 上，重建不会把用户踢回第一页。
    ///
    /// ── 2026-10-11：四分页重排 ──────────────────────────────────────────────
    ///
    /// 之前是「硬件 / 电源 / 适配器 / 智充」，右上角齿轮里另藏四页。现在
    /// 「适配器」与「智充」收进了「电源」页做分段，「维护 / 清理」收进了
    /// 「维护」页做分段。
    ///
    /// ── 2026-10-14：第 4 个分页换了内容 ──────────────────────────────────────
    ///
    /// 「频段」从「维护」的一个分段搬出来，独占第 4 个分页（两个分段：频段锁定 /
    /// 自动刷新）；腾出来的位置不再放「关于」—— 关于回到右上角齿轮里，与 0.0.30
    /// 之前一致。
    ///
    /// 「频段」分页受 `sysprobe.showBandEditor` 控制：频段页里的「隐藏这一页」
    /// 把开关关掉之后整个分页消失（原来它是消失一个分段）。
    ///
    /// ── 2026-10-15：新增第 5 个分页「进程」 ──────────────────────────────────
    ///
    /// 进程列表，对应 Windows 任务管理器的「进程」页：应用名 / CPU / 内存 /
    /// PID / 状态，按「用户应用」「系统」分成两组。它是**只读**的一页 ——
    /// 没有「结束进程」，理由见 `ProcessPanels` 类型头。
    ///
    /// 采样只在停在这一页时发生（`onAppear` / `onDisappear` 驱动），因为每一拍
    /// 都要起一个 root 子进程 —— 切到别的分页时一拍都不跑。
    ///
    /// ── 2026-10-15（第二轮）：页码收成 4 个，两个分段页变单页 ────────────────
    ///
    /// 用户明确要求的结果，四格：**硬件 / 电源 / 频段 / 进程**。
    ///
    /// 「维护」整格取消：它的三块内容按「改的是哪一类东西」拆到了别处 ——
    /// 重启设备 / 注销 / 网络唤醒进了齿轮下拉菜单（`MaintenanceSheet`），
    /// 关闭温控降频进了电源页「基础」卡片，清理并进了硬件页的存储卡片。
    /// 也就是说**没有丢掉任何功能，只是不再占一格**。
    ///
    /// 「电源」与「频段」各自从「分段 + 外壳」收成单页：分段控件那一层
    /// （`PageHubScaffold` + `PowerSegment` / `BandSegment`）整个去掉，
    /// 内容顺次排下来，和「硬件」页是同一种结构。
    ///
    /// 页码变化会**动到所有用户的肌肉记忆**，所以这是一次性的调整 ——
    /// 之后再往分页栏上加东西，要先问清楚值不值这个代价。
    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            HardwareView(openSettings: openSettings)
                .tabItem { Label("Hardware", systemImage: "cpu") }
                .tag(0)
            PowerView(openSettings: openSettings)
                .tabItem { Label("Power", systemImage: "bolt.fill") }
                .tag(1)
            // 频段页可以被用户隐藏（`BandPanels` 里的「隐藏这一页」）。隐藏之后
            // 分页栏是 3 格，进程页的 tag 3 仍然对得上 —— TabView 按 tag 选，
            // 不按位置。
            if showBandEditor {
                BandView(openSettings: openSettings)
                    .tabItem { Label("Bands", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(2)
            }
            ProcessPanels(openSettings: openSettings)
                .tabItem { Label("Processes", systemImage: "list.bullet.rectangle") }
                .tag(3)
        }
        .tint(.mwAccent)
        .id(app.language)
        // 频段页被隐藏时，选中态可能还停在 2 上 —— 挪回硬件，免得分页栏显示成
        // 「一个都没选」（那时四格全不高亮，看起来像界面坏了）。
        .onChange(of: showBandEditor) { visible in
            if !visible, app.selectedTab == 2 {
                app.selectedTab = 0
            }
        }
    }
}

/// 右上角齿轮 —— 一个下拉菜单，两项：维护 / 关于。
///
/// ── 2026-10-15：从「直接打开关于」变成菜单 ──────────────────────────────────
///
/// 「维护」分页取消之后，它剩下的东西（重启设备 / 注销 / 网络唤醒）收进了这里。
/// 所以齿轮不再是「一个动作」而是一个入口 —— 改回 `Button` 会让维护功能
/// 彻底没有入口，而且不会报任何错。
///
/// 抽成独立类型而不是在每个页面外壳里各写一遍：
/// 四个分页的外壳都要画同一个菜单，四份实现必然会漂移（一处加了新项、别处忘了）。
/// 菜单项本身也住在 `SettingsDestination` 里，标题与图标只有一处定义。
struct SettingsMenuButton: View {
    let openSettings: @MainActor (SettingsDestination) -> Void

    var body: some View {
        Menu {
            ForEach(SettingsDestination.allCases) { destination in
                Button {
                    openSettings(destination)
                } label: {
                    Label(destination.title, systemImage: destination.systemImage)
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .tint(.mwAccent)
        .accessibilityLabel(Text("Settings"))
    }
}

/// 谁在什么时候采样。
///
/// 一个零尺寸视图，挂在 `RootView` 的 overlay 上。它订阅 `PowerMonitor`（每秒发布
/// 一次），但重算的只是一个 `Color.clear`，代价可以忽略；关键是这份订阅不传染给
/// `RootView` 自己 —— 那才是「切分页闪一下」的源头之一。
struct MonitorLifecycle: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var hardware: HardwareMonitor
    /// 充电守护进程的看门狗也挂在这儿。
    ///
    /// 放在这里而不是某个分段的 `onAppear`：分段要用户点进去才出现，
    /// 而守护进程该在 App 一启动就确保活着 —— 用户装了这个 App 是为了让它一直管着
    /// 充电，不是为了每次打开都先点一下「充电」分页。
    @EnvironmentObject private var charge: ChargeControlService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .onAppear {
                monitor.start()
                hardware.start()
                charge.start()
                // 设备名兜底：本地读不到真名时借 root 工具读一次。
                //
                // **必须放在这里，而不是 `HardwareMonitor.start()`** —— 那条路要
                // `DeviceActions`，而它只编进主 App target；放进 `Shared` 里会让
                // 负一屏当场编不过（本轮踩过，见 `overrideDeviceName` 的注释）。
                Task { await resolveDeviceNameIfNeeded() }
            }
            // iOS 16: the two-parameter `onChange(of:initial:)` is iOS 17-only, so the
            // first run is done explicitly in `onAppear`.
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    monitor.start()
                    hardware.start()
                    charge.start()
                case .background:
                    monitor.pause()
                    hardware.pause()
                    // 只是停掉这边的定时器。守护进程是独立进程，App 退到后台
                    // 乃至被划掉都不影响它 —— 见 `ChargeControlService` 类型头上的说明。
                    charge.pause()
                default:
                    break
                }
            }
    }

    /// 把设备名那一格从通用名换成用户起的真名。
    ///
    /// 只在本地读到**通用名**（`iPhone` / `iPad`）时才跑：entitlement 一旦生效、
    /// 或者设备本来就不叫这两个名字，这条路就自动不再触发。用户真把设备命名为
    /// "iPhone" 时也只是多起一次子进程，读到的是同一个值 —— 无害。
    ///
    /// `DeviceActions.deviceName()` 是阻塞调用（起子进程并等它），所以丢 detached；
    /// 写回时已在主 actor 上（`body` 的 `Task` 继承 `MonitorLifecycle` 的隔离域）。
    private func resolveDeviceNameIfNeeded() async {
        let local = hardware.snapshot.system.deviceName
        guard local == "iPhone" || local == "iPad" else { return }
        let name = await Task.detached(priority: .utility) {
            DeviceActions.deviceName()
        }.value
        if let name { hardware.overrideDeviceName(name) }
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
///
/// 2026-10-14：**齿轮回来了**，它装的是「关于」（版本 / 发布日期 / 诊断）。
/// 10-11 那次重排把第 4 个分页给了「关于」，现在那个位置让给「频段」，
/// 关于回到弹层里 —— 与 0.0.30 之前一致。
///
/// 2026-10-15：齿轮从一个动作变成一个**菜单**（维护 / 关于），见
/// `SettingsMenuButton`。同一天 `PageHubScaffold`（分段页的外壳）被删掉了 ——
/// 电源页与频段页各自收成单页之后，已经没有任何页面需要它。
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var glow: Color
    /// 标题样式。默认大标题。
    ///
    /// 2026-10-15 之前这一项还有一个用途：带分段控件的分页要用 `.inline`，否则
    /// 大标题加上分段控件会把第一屏占满。分段页取消之后没有调用点再传它了，
    /// 但**保留**这个参数 —— 它是这个外壳本来就该有的一项，删掉只会让下一个
    /// 需要它的页面再改一遍外壳。
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode
    /// 内容栈的纵向间距。**默认 10**（2026-10-17 从 14 收到 10：用户要求
    /// 「所有页面的所有卡片之间的间隙调小」）。这是「卡片与卡片之间」唯一的量 ——
    /// 每张卡片自己的内边距在 `Panel` 里，不在这一层。
    ///
    /// 2026-10-15 才加这个参数，起因是进程页：那边几百行**每一行都是这个
    /// `LazyVStack` 的直接子视图**（`ForEach` 不包容器，为的是保住懒加载），
    /// 于是「页面级间距」直接变成了「行间距」。14 再叠上每行自身上下各 9 的
    /// 内边距，相邻两行的边框之间要空出 32 pt，用户反馈「行间隙太大」。
    /// 页面级间距是这里唯一能压的量，所以让它可配；进程页传 4。
    ///
    /// **频段页自己还包了一层 `VStack`**（`BandPanels`），那一层的间距必须与这里
    /// 相同，否则同一页会出现两种卡片间隙 —— 见 `BandPanels.body`。
    var spacing: CGFloat
    /// 打开“关于”弹层。**普通属性，不是 `@EnvironmentObject AppState`** ——
    /// 观察 `AppState` 会让 `showingSettings` 一变就把整页重算一次，而那一帧恰好
    /// 就是弹层开始做呈现动画的那一帧。齿轮只要一个动作，不要那份状态。
    var openSettings: @MainActor (SettingsDestination) -> Void
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey,
         glow: Color = .mwAccent,
         titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large,
         spacing: CGFloat = 10,
         openSettings: @escaping @MainActor (SettingsDestination) -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.titleDisplayMode = titleDisplayMode
        self.spacing = spacing
        self.openSettings = openSettings
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mwCanvas
                // `.equatable()` 不是装饰：这一层是整屏 `Canvas`，父 body 每次重算
                // 都会重新求值它，而 SwiftUI 比不了闭包、只能重画。详见 `Backdrop`。
                Backdrop(glow: glow).equatable()
                ScrollView {
                    LazyVStack(spacing: spacing) {
                        content()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    // Pinned to the container's width so nothing inside can widen the
                    // scroll content.
                    .mwContainerWidth()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(titleDisplayMode)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SettingsMenuButton(openSettings: openSettings)
                }
            }
        }
    }
}
