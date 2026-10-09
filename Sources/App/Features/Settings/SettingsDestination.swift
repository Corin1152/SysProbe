import SwiftUI

/// 设置菜单能打开的四页。
///
/// 真值在 `AppState.settingsDestination` 上 —— 由 `RootView` 挂在树根 `ZStack`
/// 里做成覆盖层呈现，见 `SettingsDestinationHost` 里那段说明。
nonisolated enum SettingsDestination: String, Identifiable {
    case maintenance
    case bands
    case clean
    case about

    var id: String { rawValue }
}

/// 设置子页的宿主：一个属于自己的 `NavigationStack`，外加左上角那个返回按钮，
/// 以及全屏「左滑返回」手势。
///
/// ── 为什么不能用 `NavigationLink` ───────────────────────────────────────────
///
/// 齿轮挂在 `PageScaffold` 里，那是**每个分页各自**的 `NavigationStack`，
/// 而 `TabView` 在它们**外面**。push 进去的子页因此盖不住底部分页栏 ——
/// 栏还在，而且点了不跳转：那个选中态属于外层的 `TabView`，而屏幕上呈现的是
/// 内层栈推出来的视图，两者对不上号。
///
/// 所以由 `RootView` 把这一层盖在**整个窗口**上（原来用 `fullScreenCover`，
/// 现在是树根 `ZStack` 覆盖层，见下），底栏自然被盖住；回到主页面有两条路：
/// 左上角的返回按钮（带动画滑出），以及全屏左滑手势（页面跟着手指滑出）。
///
/// ── 为什么外面还包一层 `SwipeBackContainer` ─────────────────────────────────
///
/// 原来返回只有左上角一个按钮；现在对齐系统 pop 的交互方式，加了**全屏左滑
/// 返回**手势（手势识别逻辑见 `SwipeBackContainer`）：横向右滑时整页跟手滑出，
/// 露出下层的主页面，松手过阈值即提交关闭。开启方式也从 `fullScreenCover`
/// 改成了树根 `ZStack` 覆盖层 —— 见 `RootView` 里那段说明（下层页面必须留在
/// 层级里，手势滑出时才有东西可露）。
///
/// ── 为什么语言要在这里再喂一次 ───────────────────────────────────────────────
///
/// 译文是按**环境里的 `locale`** 挑的。这层是 representable 的内容闭包，塞进
/// 独立的 `UIHostingController`，环境不会自动继承 —— `SwipeBackContainer`
/// 会把当前环境整包带过去（`\.self` 注入），这里再显式喂一次 locale 作为兜底，
/// 否则切语言后整页会退成英文，而返回主页面又是好的，症状很像「只有设置页坏了」。
/// 否则切语言后整页会退成英文，而返回主页面又是好的，症状很像「只有设置页坏了」。
struct SettingsDestinationHost: View {
    let destination: SettingsDestination
    /// 左上角返回按钮：带动画地把页面滑出（SwiftUI `transition` 接管动画）。
    let close: () -> Void
    /// 手势提交：页面已被手势滑出屏幕，直接摘层，不再补动画。
    let gestureClose: () -> Void

    @EnvironmentObject private var app: AppState

    var body: some View {
        SwipeBackContainer(enabled: true, mode: .cover, onCommit: gestureClose) {
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
        .ignoresSafeArea()
    }

    /// 四页各自决定自己的标题样式（`navigationTitle` / `navigationBarTitleDisplayMode`），
    /// 这里不统一设 —— 维护页本来就是 `.inline`，别把它改成大标题。
    @ViewBuilder
    private var content: some View {
        switch destination {
        case .maintenance: MaintenanceView()
        case .bands: BandEditorView()
        case .clean: CleanView()
        case .about: AboutView()
        }
    }
}
