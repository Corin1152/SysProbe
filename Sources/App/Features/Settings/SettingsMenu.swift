import SwiftUI

/// 右上角的齿轮。**点开就在齿轮下面展开三行菜单**，不再先推一页菜单出来。
///
/// 用 `Menu` 装 `NavigationLink`：`Menu` 自己负责「在齿轮下展开」这个呈现，而里面的
/// `NavigationLink` 会推进**当前分页**的 `NavigationStack` —— 四个分页各自有一个栈，
/// 所以从哪一页进的、返回到哪一页，都是对的。
///
/// 之前是「齿轮 → 设置面板（sheet）→ 三行菜单 → 再推一页」，三层才到内容；现在一层。
/// 顺带去掉的还有那个 sheet 带来的一堆约束：面板挂在分页里会在语言切换重建分页时被
/// 一起关掉，所以原来必须把它提到树根上（`RootView`）—— 现在没有 sheet 了。
struct SettingsMenu: View {
    /// 「频段」那一行是否显示。默认显示。
    ///
    /// 频段写错会导致无服务，所以那一页里留了一个关掉入口的开关。关掉之后菜单只剩
    /// 两行，而且**没有地方能再打开** —— 这是故意的：一个能被随手关掉、又能随手打开
    /// 的开关挡不住误触。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    var body: some View {
        Menu {
            NavigationLink {
                MaintenanceView()
            } label: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
            }

            if showBandEditor {
                NavigationLink {
                    BandEditorView()
                } label: {
                    Label("Bands", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            NavigationLink {
                AboutView()
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
