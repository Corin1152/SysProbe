import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var hardware: HardwareMonitor
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
            // 设置面板挂在 `tabs` 外面，而 `tabs` 会随语言换 identity —— 挂在里面的话
            // 用户在设置页切完语言，面板会被自己触发的重建关掉。
            .sheet(isPresented: $app.showingSettings) { SettingsView() }
    }

    /// 语言一变，整棵分页树换 identity。
    ///
    /// 文案是在 `body` 求值时从 `Bundle.main` 查出来的，已经求过值的分页不会自己重算，
    /// 所以必须强制重建。`selection` 绑在 `app.selectedTab` 上，重建不会把用户踢回第一页。
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
        .environment(\.locale, app.language.locale)
        // iOS 16: the two-parameter `onChange(of:initial:)` is iOS 17-only, so the
        // first run is done explicitly in `onAppear`.
        .onAppear {
            monitor.start()
            hardware.start()
            UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
        }
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
        .id(app.language)
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
