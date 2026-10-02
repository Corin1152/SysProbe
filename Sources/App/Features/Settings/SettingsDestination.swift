import SwiftUI

/// 设置菜单能打开的三页。
///
/// 真值在 `AppState.settingsDestination` 上 —— 由 `RootView` 用
/// `fullScreenCover(item:)` 呈现，见 `SettingsDestinationHost` 里那段说明。
nonisolated enum SettingsDestination: String, Identifiable {
    case maintenance
    case bands
    case about

    var id: String { rawValue }
}

/// 设置子页的宿主：一个属于自己的 `NavigationStack`，外加左上角那个返回按钮。
///
/// ── 为什么不能用 `NavigationLink` ───────────────────────────────────────────
///
/// 齿轮挂在 `PageScaffold` 里，那是**每个分页各自**的 `NavigationStack`，
/// 而 `TabView` 在它们**外面**。push 进去的子页因此盖不住底部分页栏 ——
/// 栏还在，而且点了不跳转：那个选中态属于外层的 `TabView`，而屏幕上呈现的是
/// 内层栈推出来的视图，两者对不上号。
///
/// 所以改成由 `RootView` 用 `fullScreenCover` 呈现这一层：它盖住的是**整个窗口**，
/// 底栏自然被盖住；返回只有左上角这一个按钮，点它才回到主页面、底栏随之恢复。
///
/// ── 为什么语言要在这里再喂一次 ───────────────────────────────────────────────
///
/// 译文是按**环境里的 `locale`** 挑的（`RootView` 只在 `tabs` 上喂了一句）。
/// `fullScreenCover` 开出的是另一条视图分支，不保证继承那一句，所以这里显式再喂一次 ——
/// 否则切语言后整页会退成英文，而返回主页面又是好的，症状很像「只有设置页坏了」。
struct SettingsDestinationHost: View {
    let destination: SettingsDestination
    /// 关闭自己。由 `RootView` 传进来 —— 真值在 `AppState` 上，这一层不持有它。
    let close: () -> Void

    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    // 左上角返回。刻意**不用** `DismissAction`（`@Environment(\.dismiss)`）：
                    // 关闭动作要写回 `AppState.settingsDestination`，而那才是这层呈现的
                    // 唯一真值 —— 交给系统环境去 dismiss，状态与界面会各走一路。
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { close() } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                    }
                }
        }
        .environment(\.locale, app.language.locale)
    }

    /// 三页各自决定自己的标题样式（`navigationTitle` / `navigationBarTitleDisplayMode`），
    /// 这里不统一设 —— 维护页本来就是 `.inline`，别把它改成大标题。
    @ViewBuilder
    private var content: some View {
        switch destination {
        case .maintenance: MaintenanceView()
        case .bands: BandEditorView()
        case .about: AboutView()
        }
    }
}
