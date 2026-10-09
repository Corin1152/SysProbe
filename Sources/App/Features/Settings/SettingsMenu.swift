import SwiftUI

/// 右上角的齿轮。**点开就在齿轮下面展开菜单**，不再先推一页菜单出来。
///
/// 四行（频段被关掉时三行）各自写一个 `AppState.settingsDestination`，由 `RootView`
/// 盖成**覆盖全屏**的一层 —— 底部分页栏被盖住。赋值包在 `withAnimation` 里：
/// 覆盖层以系统 push 的样式从右缘滑入（`RootView` 上挂了对应的
/// `.transition(.move(edge: .trailing))`）。
///
/// 之前这里是 `Menu` 装 `NavigationLink`，推进**当前分页**的 `NavigationStack`。
/// 那样做有两个问题，都是这次改掉的：
///
///   1. `TabView` 在那层栈的**外面**，所以推出来的子页盖不住底部分页栏 —— 栏还在；
///   2. 而那个栏点了不跳转：选中态属于外层 `TabView`，屏幕上却是内层栈的视图。
///
/// 见 `SettingsDestinationHost` 类型头上的完整说明。
struct SettingsMenu: View {
    @EnvironmentObject private var app: AppState

    /// 「频段」那一行是否显示。默认显示。
    ///
    /// 频段写错会导致无服务，所以那一页里留了一个关掉入口的开关。关掉之后菜单只剩
    /// 两行，而且**没有地方能再打开** —— 这是故意的：一个能被随手关掉、又能随手打开
    /// 的开关挡不住误触。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    var body: some View {
        Menu {
            Button {
                open(.maintenance)
            } label: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
            }

            if showBandEditor {
                Button {
                    open(.bands)
                } label: {
                    Label("Bands", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            // 存储清理。与维护并列成页而不是塞进维护页：它有自己的扫描状态与
            // 一个可能很长的按 App 列表，塞进去会把维护页顶成「先滚过温控和
            // 重启才能看到清理」—— 两件事各自成页，菜单里各占一行。
            Button {
                open(.clean)
            } label: {
                Label("Clean", systemImage: "sparkles")
            }

            Button {
                open(.about)
            } label: {
                Label("About", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .tint(.mwAccent)
        .accessibilityLabel(Text("Settings"))
    }

    private func open(_ destination: SettingsDestination) {
        withAnimation(.easeOut(duration: 0.35)) {
            app.settingsDestination = destination
        }
    }
}
