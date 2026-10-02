import SwiftUI

/// App 级状态：界面语言、设置面板的呈现、当前分页。
///
/// 三样都放在 `RootView` 这一层，各有用意：
/// - **语言**：它是全 App 的唯一真相 —— `RootView` 把它转成环境里的 `\.locale`
///   （`Text("…")` 就按这个去 `.lproj` 里挑译文），`AppFont` 与 `Strings.text` 读的也是
///   同一个值。住在树根上才转得下去；
/// - **设置面板**：改成三页常驻之后，面板不再属于任何一个分页，提升到根上还顺带解决了
///   语言切换重建分页时会把 sheet 一起带走的问题；
/// - **当前分页**：`.id` 重建 `TabView` 时靠它把用户留在原来那一页；
/// - **设置子页**：四个设置页面是**全屏覆盖**呈现的（见 `SettingsDestinationHost`），
///   所以呈现的是谁必须住在树根上 —— 放在某个分页里的话，切语言重建分页时会把它
///   连带关掉，而用户看到的就是「设置页自己消失了」。
@MainActor
final class AppState: ObservableObject {

    @Published var language: AppLanguage {
        didSet { applyLanguage() }
    }

    @Published var selectedTab = 0

    /// 当前打开的设置子页。`nil` = 没打开，主页面与底部分页栏照常显示。
    @Published var settingsDestination: SettingsDestination?

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
