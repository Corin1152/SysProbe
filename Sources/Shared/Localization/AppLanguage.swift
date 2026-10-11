import Foundation

/// 界面语言。**固定跟随系统**，用户不可切换（2026-10-11 起）。
///
/// 在那之前它存在 `UserDefaults` 里、维护页有一个选择器。删掉的原因很简单：
/// 这个 App 只有中英两套文案，而系统语言本来就表达了用户想要哪一种 ——
/// 一个只在两种语言之间选的开关，收益配不上它在维护页里占的那一区。
///
/// 负一屏扩展一直是这个行为（它读不到主 App 的 `UserDefaults`），现在两边一致了。
///
/// `CaseIterable` 保留：`Strings.bundles` 靠它把每个 `.lproj` 都挂进来。
nonisolated enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh-Hans"

    /// 当前界面语言。**运行期唯一的真相**：`AppFont` 用它决定字形，`Strings.text`
    /// 用它挑 `.lproj`，`RootView` 把它转成环境里的 `\.locale`。
    ///
    /// 为什么不是「让 `Bundle.main` 自己查」：SwiftUI 的 `Text("…")` 根本不走
    /// `Bundle.main.localizedString(forKey:value:table:)`，它按环境里的 locale 直接去
    /// bundle 的 `.lproj` 里挑。所以「当前是哪种语言」这件事得我们自己记着。
    ///
    /// `nonisolated(unsafe)`：写它的是主 actor 上的 `AppState`，读它的地方
    /// （`AppFont`、`Strings.text`）够不到主 actor。读写的都是一个枚举值，原子替换，
    /// 没有撕裂的可能。
    nonisolated(unsafe) static var current: AppLanguage = .systemPreferred

    var locale: Locale { Locale(identifier: rawValue) }

    /// 拉丁与中文的可用字形不同，字体设计要跟着语言走。见 `AppFont`。
    var prefersRoundedDesign: Bool {
        self == .english
    }

    /// 系统偏好语言推断出来的语言。**主 App 与扩展共用这一个入口。**
    ///
    /// 只在 `Locale.preferredLanguages` 里认中英两种：都不匹配时回英文。
    /// 两种都认不出来（比如系统是日语）也回英文 —— 本 App 只有这两套文案，
    /// 与其猜一个更接近的，不如用一个确定能读懂的。
    static var systemPreferred: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let lowered = identifier.lowercased()
            if lowered.hasPrefix("zh") { return .chinese }
            if lowered.hasPrefix("en") { return .english }
        }
        return .english
    }
}
