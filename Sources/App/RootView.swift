import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            // 最底下一层不透明画布色。转场里任何一帧上层还没画上内容时，露出来的都是它，
            // 而不是窗口底色（浅色下白、深色下黑）—— 后者正是「闪一下」的来源。
            Color.mwCanvas.ignoresSafeArea()

            // 四个分页整体包一层全屏「左滑返回」手势：不在第一屏（硬件页）时，
            // 横向右滑切回第一屏。设置子页打开期间关掉（见 `enabled`）。
            SwipeBackContainer(
                enabled: app.settingsDestination == nil && app.selectedTab != 0,
                mode: .tab,
                onCommit: { app.selectedTab = 0 }
            ) {
                tabs
                    // 语言是喂给环境的，不是喂给 `Bundle.main` 的。
                    //
                    // SwiftUI 的 `Text("…")` 不看 `Bundle.main.localizedString(...)`，它按环境里
                    // 这个 `locale` 直接去 bundle 的 `.lproj` 里挑译文 —— 全 App 一起换语言，
                    // 靠的就是这一句。
                    .environment(\.locale, app.language.locale)
                    // 负一屏那一下点击会带 `sysprobe://open` 进来（见
                    // `TodayViewController.openApp`）。这里刻意**不动分页** ——
                    // 用户是来看数据的，停在上次看的那一屏更自然。
                    .onOpenURL { _ in }
            }
            .ignoresSafeArea()

            // 设置子页：**盖住整个窗口**（含底部分页栏），而不是推进某个分页内部的栈。
            //
            // ── 为什么从 `fullScreenCover` 改成树根覆盖层 ──────────────────────────
            //
            // 仍然是「盖住整个窗口、底栏被盖住」的呈现（原来用 `fullScreenCover`），
            // 但 `fullScreenCover` 的收起动画是系统下滑式，而它呈现后**下层的
            // 主页面会从视图层级里摘掉** —— 手势拖动时露出来的是黑底，做不出
            // 交互式 pop 那种「页面跟着手指滑出、下层主页面原样可见」的动画。
            // 挂在 `ZStack` 里，下层页面全程留在层级里，手势才能真滑出。
            //
            // 挂在树根而不是 `tabs` 里，原因不变：语言切换会按 `.id` 重建整棵
            // 分页树，挂在分页里的呈现会随之被关掉 —— 那个症状是「设置页自己消失了」。
            // 关闭途径有二：左上角返回按钮（带动画滑出，见 `SettingsDestinationHost`）
            // 与全屏左滑手势（页面先滑出、再摘层，见 `SwipeBackContainer`）。
            if let destination = app.settingsDestination {
                SettingsDestinationHost(
                    destination: destination,
                    close: {
                        withAnimation(.easeIn(duration: 0.3)) { app.settingsDestination = nil }
                    },
                    gestureClose: {
                        // 手势路径里页面已经滑出屏幕，直接摘层即可，不再补动画。
                        app.settingsDestination = nil
                    }
                )
                .transition(.move(edge: .trailing))
            }

            // 采样的生命周期单独放进一个零尺寸视图。
            //
            // 独立出来是为了把每秒一次的 `PowerSnapshot` 发布挡在 `RootView` 之外：
            // 这里 body 里是整棵 `TabView` 加一层设置覆盖，让它跟着每秒重算，
            // 既白费功夫，也会让设置页在呈现动画里被反复重建。
            MonitorLifecycle()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    /// 语言一变，整棵分页树换 identity。
    ///
    /// 译文由环境 locale 决定，换 locale 时 SwiftUI 会自己重算；但**字形**不是 ——
    /// `AppFont` 读的是 `AppLanguage.current` 这个全局（中文要退回 `.default` 设计，
    /// 否则汉字会掉回苹方 SC，与同行拉丁字重、基线都不齐）。换 identity 是最省事的
    /// 兜底，保证字形、字距、大小写跟译文一起换。`selection` 绑在 `app.selectedTab`
    /// 上，重建不会把用户踢回第一页。
    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            HardwareView()
                .tabItem { Label("Hardware", systemImage: "cpu") }
                .tag(0)
            DashboardView()
                .tabItem { Label("Power", systemImage: "bolt.fill") }
                .tag(1)
            AdapterView()
                .tabItem { Label("Adapter", systemImage: "powerplug.fill") }
                .tag(2)
            ChargeControlView()
                // 键用 "Smart charge" 而不是 "Charging"：后者是功率页的状态词，
                // 也用在电池信息页的面板标题上，共用一个键会把那两处一起改掉。
                .tabItem { Label("Smart charge", systemImage: "battery.100.bolt") }
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
/// `RootView` 自己 —— 那才是「进／出设置页闪一下」的源头之一。
struct MonitorLifecycle: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var hardware: HardwareMonitor
    /// 充电守护进程的看门狗也挂在这儿。
    ///
    /// 放在这里而不是 `ChargeControlView.onAppear`：那个页面要用户点进去才出现，
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
/// 设置入口在这里，不在某个分页里 —— 四个分页共用右上角同一个齿轮。
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var glow: Color = .mwAccent
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey,
         glow: Color = .mwAccent,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
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
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SettingsMenu()
                }
            }
        }
    }
}
