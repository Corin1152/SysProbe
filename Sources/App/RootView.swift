import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

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
        // 设置子页没有了 —— 原来齿轮里的四页全部搬到了分页栏上（见 `tabs`），
        // 树根上不再需要任何全屏覆盖层。
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
    /// 「适配器」与「智充」收进了「电源」页做分段，「维护 / 清理 / 频段」收进了
    /// 「维护」页做分段，「关于」独立成分页 —— 齿轮整个删掉，所有内容一级可达。
    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            HardwareView()
                .tabItem { Label("Hardware", systemImage: "cpu") }
                .tag(0)
            PowerHubView()
                .tabItem { Label("Power", systemImage: "bolt.fill") }
                .tag(1)
            MaintenanceHubView()
                .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
                .tag(2)
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(3)
        }
        .tint(.mwAccent)
        .id(app.language)
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

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
///
/// **右上角那个齿轮没有了**（2026-10-11）：它原来装的是「维护 / 频段 / 清理 / 关于」，
/// 现在这四页分别是「维护」分页里的三个分段与独立的「关于」分页 —— 齿轮没有内容可装，
/// 整个删掉。这一层因此只负责画布、光晕、滚动容器与标题。
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var glow: Color
    /// 标题样式。默认大标题；**带分段控件的分页要用 `.inline`** ——
    /// 大标题会占掉整整一行半的高度，而分段控件就压在它下面，两者叠起来第一屏
    /// 几乎看不到内容。见 `PageHubScaffold`。
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey,
         glow: Color = .mwAccent,
         titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.titleDisplayMode = titleDisplayMode
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mwCanvas
                Backdrop(glow: glow)
                ScrollView {
                    LazyVStack(spacing: 14) {
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
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    init(title: LocalizedStringKey,
         glow: Color = .mwAccent,
         @ViewBuilder header: @escaping () -> Header,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.header = header
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mwCanvas
                Backdrop(glow: glow)
                VStack(spacing: 0) {
                    header()
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    content()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
