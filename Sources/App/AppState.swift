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

    @Published var language: AppLanguage {
        didSet { applyLanguage() }
    }

    @Published var selectedTab = 0

    init() {
        // 第一次启动跟随系统语言，之后跟随用户自己的选择。
        language = AppLanguage.stored ?? .systemPreferred
        // 注意：属性观察器在 `init` 里不触发，所以这里得显式落一次。
        applyLanguage()
    }

    private func applyLanguage() {
        AppLanguage.current = language
        AppLanguage.store(language)
    }
}
