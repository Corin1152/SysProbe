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
                // 靠的就是这一句。挂在这里而不是 `tabs` 里面，设置面板（sheet）才继承得到。
                .environment(\.locale, app.language.locale)
                // 设置面板挂在 `tabs` 外面，而 `tabs` 会随语言换 identity —— 挂在里面的话，
                // 用户在设置页切完语言，面板会被自己触发的重建关掉。
                .sheet(isPresented: $app.showingSettings) { SettingsView() }
                // 负一屏那一下点击会带 `sysprobe://open` 进来（见
                // `TodayViewController.openApp`）。这里只把设置面板收起来 ——
                // 用户是来看数据的，不该一进来就压着一个模态。分页不重置：
                // 停在用户上次看的那一屏更自然。
                .onOpenURL { _ in app.showingSettings = false }
                // 采样的生命周期单独放进一个零尺寸视图。
                //
                // 独立出来是为了把每秒一次的 `PowerSnapshot` 发布挡在 `RootView` 之外：
                // 这里 body 里是整棵 `TabView` 加一个 sheet 修饰符，让它跟着每秒重算，
                // 既白费功夫，也会让设置面板在呈现动画里被反复重建。
                .overlay(
                    MonitorLifecycle()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                )
        }
    }

    /// 打开设置面板。以普通闭包往下传，而不是让每页都去观察 `AppState`。
    ///
    /// 观察 `AppState` 的代价在这里是实打实的：`showingSettings` 一变，三个分页
    /// （各自一棵 `NavigationStack` + `ScrollView` + 面板树）会在**同一帧**里各重算
    /// 一次 —— 而这一帧恰好就是设置面板开始做呈现动画的那一帧。齿轮是唯一需要这个
    /// 动作的地方，那就只把动作传下去，别把状态传下去。
    ///
    /// 类型写成 `@MainActor () -> Void` 而不是 `() -> Void`：闭包体里要写
    /// `app.showingSettings`，而 `AppState` 是主 actor 隔离的。
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
    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            HardwareView(onOpenSettings: openSettings)
                .tabItem { Label("Hardware", systemImage: "cpu") }
                .tag(0)
            DashboardView(onOpenSettings: openSettings)
                .tabItem { Label("Power", systemImage: "bolt.fill") }
                .tag(1)
            AdapterView(onOpenSettings: openSettings)
                .tabItem { Label("Adapter", systemImage: "powerplug.fill") }
                .tag(2)
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .onAppear {
                monitor.start()
                hardware.start()
            }
            // iOS 16: the two-parameter `onChange(of:initial:)` is iOS 17-only, so the
            // first run is done explicitly in `onAppear`.
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    monitor.start()
                    hardware.start()
                case .background:
                    monitor.pause()
                    hardware.pause()
                default:
                    break
                }
            }
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
///
/// 设置入口在这里，不在某个分页里 —— 三个分页共用同一个齿轮按钮，设置面板本身由
/// `RootView` 持有（见 `AppState.showingSettings`）。
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var glow: Color = .mwAccent
    /// 打开设置面板。
    ///
    /// **普通属性，不是 `@EnvironmentObject AppState`。** 观察 `AppState` 就意味着
    /// `showingSettings` / `selectedTab` / `language` 任何一个变化都会让三个分页各重算
    /// 一次；而按下齿轮这件事恰好发生在设置面板开始做呈现动画的那一帧。齿轮只需要
    /// 一个动作，不需要那份状态。
    var onOpenSettings: @MainActor () -> Void
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey,
         glow: Color = .mwAccent,
         onOpenSettings: @escaping @MainActor () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.onOpenSettings = onOpenSettings
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
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(.mwAccent)
                    .accessibilityLabel(Text("Settings"))
                }
            }
        }
    }
}
