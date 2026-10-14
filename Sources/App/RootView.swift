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
                // 「关于」挂在这里，不在 `tabs` 里面 —— `tabs` 会随语言换 identity，
                // 挂里面的话用户在关于页切完语言，弹层会被自己触发的重建关掉。
                .sheet(isPresented: $app.showingSettings) { AboutView() }
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

    /// 打开“关于”弹层。
    ///
    /// 以普通闭包往下传，而不是让每页都去观察 `AppState`：观察 `AppState` 就意味着
    /// `showingSettings` / `selectedTab` / `language` 任何一个变化都会让四个分页各重算
    /// 一次 —— 而这一帧恰好就是弹层开始做呈现动画的那一帧。齿轮只需要一个动作。
    private var openSettings: @MainActor () -> Void {
        { app.showingSettings = true }
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
    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            HardwareView(openSettings: openSettings, isActive: app.selectedTab == 0)
                .tabItem { Label("Hardware", systemImage: "cpu") }
                .tag(0)
            PowerHubView(openSettings: openSettings, isActive: app.selectedTab == 1)
                .tabItem { Label("Power", systemImage: "bolt.fill") }
                .tag(1)
            MaintenanceHubView(openSettings: openSettings, isActive: app.selectedTab == 2)
                .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
                .tag(2)
            if showBandEditor {
                BandHubView(openSettings: openSettings, isActive: app.selectedTab == 3)
                    .tabItem { Label("Bands", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(3)
            }
        }
        .tint(.mwAccent)
        .id(app.language)
        // 分页消失时选中态可能还停在 3 上 —— 挪回维护，免得分页栏显示成「一个都没选」。
        .onChange(of: showBandEditor) { visible in
            if !visible, app.selectedTab == 3 {
                app.selectedTab = 2
            }
        }
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
}

/// 只在「这一页真的在屏幕上」时才求值它的内容。
///
/// ── 为什么需要它 ────────────────────────────────────────────────────────────
///
/// `TabView` 会把切走的分页留在视图树里 —— 那正是它保留滚动位置与状态的方式，
/// 也是「切回来还在原处」的原因。代价是：分页里的视图**照旧每秒重算**，因为它们
/// 观察着 `PowerMonitor` / `HardwareMonitor` / `ChargeControlService` 这些每秒发布
/// 一次的对象。
///
/// 于是用户停在硬件页时，电源页（六个面板 + 圆环）、频段页（40 多个频段格子）、
/// 充电页仍在各自每秒把 body 跑一遍 —— 三页加起来十几毫秒，正好是一帧的时间。
/// 表现就是「不管在哪一页，滑动和切分段都偶尔顿一下」。
///
/// ── 为什么是等高占位，而不是干脆不渲染 ──────────────────────────────────────
///
/// 直接不渲染，滚动容器的内容高度会塌成 0，切回来时 `ScrollView` 会把偏移量钳回
/// 顶部 —— 那是用户看得见的行为变化。记住上一次的高度、用等高占位顶住，切回来时
/// 布局与滚动位置都不动。
///
/// 高度只在**可见期间**记录（`onAppear` 记首次、`onChange` 跟变化）—— 切走之后
/// 内容不再求值，那时没有更好的时机。它是近似值，而它只影响「切走期间占位多高」，
/// 不影响切回来之后的内容。
struct DeferredContent<Content: View>: View {

    /// 这一页现在在不在屏幕上。
    let isVisible: Bool

    @ViewBuilder var content: () -> Content

    @State private var height: CGFloat = 0

    var body: some View {
        if isVisible {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { height = proxy.size.height }
                            // 只在高度真的变了才写：读数每秒在变，但高度几秒都不动一下，
                            // 所以这一句平时一次都不触发。
                            .onChange(of: proxy.size.height) { newValue in height = newValue }
                    }
                )
        } else {
            Color.clear.frame(height: height)
        }
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
///
/// 2026-10-14：**齿轮回来了**，它装的是「关于」（版本 / 发布日期 / 诊断）。
/// 10-11 那次重排把第 4 个分页给了「关于」，现在那个位置让给「频段」，
/// 关于回到弹层里 —— 与 0.0.30 之前一致。
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var glow: Color
    /// 这一页现在是不是选中的那个分页。
    ///
    /// 由 `RootView` 按 `selectedTab` 给。**不用 `onAppear` / `onDisappear` 判**：
    /// 那一对回调的触发时机取决于 `TabView` 什么时候创建分页的视图，而这里要的是
    /// 确定的答案 —— 非当前分页必须**停止求值内容**，否则它会跟着每秒一次的采样
    /// 一直重算（详见 `DeferredContent`）。
    var isActive: Bool = true
    /// 标题样式。默认大标题；**带分段控件的分页要用 `.inline`** ——
    /// 大标题会占掉整整一行半的高度，而分段控件就压在它下面，两者叠起来第一屏
    /// 几乎看不到内容。见 `PageHubScaffold`。
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode
    /// 打开“关于”弹层。**普通属性，不是 `@EnvironmentObject AppState`** ——
    /// 观察 `AppState` 会让 `showingSettings` 一变就把整页重算一次，而那一帧恰好
    /// 就是弹层开始做呈现动画的那一帧。齿轮只要一个动作，不要那份状态。
    var openSettings: @MainActor () -> Void
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey,
         glow: Color = .mwAccent,
         isActive: Bool = true,
         titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large,
         openSettings: @escaping @MainActor () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.isActive = isActive
        self.titleDisplayMode = titleDisplayMode
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
                    LazyVStack(spacing: 14) {
                        DeferredContent(isVisible: isActive) { content() }
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
                    Button { openSettings() } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(.mwAccent)
                    .accessibilityLabel(Text("Settings"))
                }
            }
        }
    }
}

/// 带分段控件的分页外壳。导航栈 + 画布 + 一个常驻的分段控件，滚动交给各分段自己。
///
/// ── 为什么不能直接用 `PageScaffold` ──────────────────────────────────────────
///
/// `PageScaffold` 的内容是被塞进它**自己的** `ScrollView` 里的。而分段的内容里
/// 有 `Form`（维护页）与 `ScrollView`（功率 / 适配器 / 清理 / 频段页）—— 它们各自
/// 就是一个滚动容器。套进去会变成滚动套滚动：内层滚不动、外层抢手势，界面上表现为
/// 「这一页滑不动」，而且不报任何错。
///
/// 所以这一层只提供「导航栈 + 画布 + 分段控件」，**滚动交给分段自己**。
///
/// ── 标题为什么是 `.inline` ──────────────────────────────────────────────────
///
/// 分段控件必须紧贴标题下方（这是这一页的主导航）。用大标题的话，标题本身就占掉
/// 一行半，加上分段控件，第一屏能看到的正文只剩一小半。`.inline` 把标题缩成导航栏里
/// 的 17pt，分段控件直接压在栏下面 —— 这才是「进去就能看到更多内容」。
///
/// 标题随分段变：由调用方按当前分段给出 `title`，不是常量。
struct PageHubScaffold<Header: View, Content: View>: View {
    let title: LocalizedStringKey
    var glow: Color
    /// 这一页现在是不是选中的那个分页。见 `PageScaffold.isActive`。
    var isActive: Bool = true
    /// 打开“关于”弹层。与 `PageScaffold` 同一个齿轮，同一条理由：
    /// 传动作，不传 `AppState`。
    var openSettings: @MainActor () -> Void
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    init(title: LocalizedStringKey,
         glow: Color = .mwAccent,
         isActive: Bool = true,
         openSettings: @escaping @MainActor () -> Void,
         @ViewBuilder header: @escaping () -> Header,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.isActive = isActive
        self.openSettings = openSettings
        self.header = header
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mwCanvas
                // 与 `PageScaffold` 同一条理由：整屏 `Canvas` 要能被跳过。
                Backdrop(glow: glow).equatable()
                VStack(spacing: 0) {
                    header()
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    // 只有选中的分页才求值分段内容 —— 见 `DeferredContent`。
                    DeferredContent(isVisible: isActive) { content() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { openSettings() } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(.mwAccent)
                    .accessibilityLabel(Text("Settings"))
                }
            }
        }
    }
}
