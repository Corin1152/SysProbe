import SwiftUI

/// App 级状态：界面语言、设置面板的呈现、当前分页。
///
/// 三样都放在 `RootView` 这一层，各有用意：
/// - **语言**：它是全 App 的唯一真相 —— `RootView` 把它转成环境里的 `\.locale`
///   （`Text("…")` 就按这个去 `.lproj` 里挑译文），`AppFont` 与 `Strings.text` 读的也是
///   同一个值。住在树根上才转得下去；
/// - **设置面板**：改成三页常驻之后，面板不再属于任何一个分页，提升到根上还顺带解决了
///   语言切换重建分页时会把 sheet 一起带走的问题；
/// - **当前分页**：`.id` 重建 `TabView` 时靠它把用户留在原来那一页。
@MainActor
final class AppState: ObservableObject {

    @Published var language: AppLanguage {
        didSet { applyLanguage() }
    }

    @Published var showingSettings = false
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
