import SwiftUI

/// 右上角的齿轮。**点开就在齿轮下面展开三行菜单**，不再先推一页菜单出来。
///
/// 三行各自写一个 `AppState.settingsDestination`，由 `RootView` 用 `fullScreenCover`
/// 呈现成**覆盖全屏**的一层 —— 底部分页栏被盖住，返回只能走左上角的返回按钮。
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
                app.settingsDestination = .maintenance
            } label: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
            }

            if showBandEditor {
                Button {
                    app.settingsDestination = .bands
                } label: {
                    Label("Bands", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            Button {
                app.settingsDestination = .about
            } label: {
                Label("About", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .tint(.mwAccent)
        .accessibilityLabel(Text("Settings"))
    }
}
