import SwiftUI

/// App 级状态：界面语言、设置面板的呈现、当前分页。
///
/// 三样都放在 `RootView` 这一层，各有用意：
/// - **语言**：改一次要重建整棵视图树（文案是在 `body` 求值时从 `Bundle.main` 取出来的，
///   已求过值的分页不会自己重算），所以它必须住在树根上；
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

    private static let languageKey = "appLanguage"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(AppLanguage.init(rawValue:))
        // 第一次启动跟随系统语言，之后跟随用户自己的选择。
        language = stored ?? .systemPreferred
        // 注意：属性观察器在 `init` 里不触发，所以这里得显式落一次。
        applyLanguage()
    }

    private func applyLanguage() {
        LocalizedBundle.language = language
        UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
    }
}
