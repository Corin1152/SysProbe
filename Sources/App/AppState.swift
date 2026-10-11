import SwiftUI

/// App 级状态：界面语言、当前分页。
///
/// 两样都放在 `RootView` 这一层，各有用意：
/// - **语言**：它是全 App 的唯一真相 —— `RootView` 把它转成环境里的 `\.locale`
///   （`Text("…")` 就按这个去 `.lproj` 里挑译文），`AppFont` 与 `Strings.text` 读的也是
///   同一个值。住在树根上才转得下去；
/// - **当前分页**：`.id` 重建 `TabView` 时靠它把用户留在原来那一页。
///
/// ── 2026-10-11：`settingsDestination` 删掉了 ────────────────────────────────
///
/// 它原来是「当前打开的设置子页」，配合 `RootView` 的 `fullScreenCover` 把
/// 维护 / 频段 / 清理 / 关于盖成全屏。这四页现在分别变成了「维护」分页里的三个分段
/// 与独立的「关于」分页，右上角齿轮整个删除 —— 没有全屏覆盖层，也就没有「当前打开
/// 的是哪一页」这个状态。
@MainActor
final class AppState: ObservableObject {

    /// 界面语言。**固定跟随系统，用户不可改**（2026-10-11 起）。
    ///
    /// 它仍然是 `@Published`，因为 `RootView` 拿它做两件事：喂给环境里的
    /// `\.locale`（`Text("…")` 按这个去 `.lproj` 里挑译文），以及当 `.id` 让整棵
    /// 分页树换 identity（换语言时字形要跟着换，见 `RootView.tabs` 的说明）。
    /// 这两条路径都还在，只是值不再来自用户的开关。
    ///
    /// 在 `init` 里定一次就够：iOS 在系统语言变更时会重启 App，不需要在运行期
    /// 盯着 `Locale.preferredLanguages` 变。负一屏扩展同理，见 `TodayViewController`。
    @Published private(set) var language: AppLanguage = .systemPreferred

    @Published var selectedTab = 0

    init() {
        // `AppFont` 与 `Strings.text` 读的是 `AppLanguage.current` 这个全局，
        // 而它得在第一帧之前就位 —— 见 `SysProbeApp.init` 里同一句话。
        AppLanguage.current = language
    }
}
