import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
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
            // 采样与「常亮」的生命周期单独放进一个零尺寸视图。
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
        }
        .tint(.mwAccent)
        .id(app.language)
    }
}

/// 谁在什么时候采样、屏幕要不要常亮。
///
/// 一个零尺寸视图，挂在 `RootView` 的 overlay 上。它订阅 `PowerMonitor`（每秒发布
/// 一次），但重算的只是一个 `Color.clear`，代价可以忽略；关键是这份订阅不再传染给
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
                UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
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
            .onChange(of: shouldStayAwake) { awake in
                UIApplication.shared.isIdleTimerDisabled = awake
            }
    }

    /// Hold the screen on, but only while it is actually earning something: the app
    /// is in front and the phone is plugged in.
    private var shouldStayAwake: Bool {
        monitor.keepScreenAwakeWhileCharging
            && monitor.snapshot.externalConnected
            && scenePhase == .active
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
///
/// 设置入口在这里，不在某个分页里 —— 三个分页共用同一个齿轮按钮，设置面板本身由
/// `RootView` 持有（见 `AppState.showingSettings`）。
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    var glow: Color = .mwAccent
    @EnvironmentObject private var app: AppState
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
                        app.showingSettings = true
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
