import Foundation

/// 界面语言。
///
/// 存在 `UserDefaults` 里，切换后**不重启**即可生效。
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

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

    /// 用户上次选的语言。键名只写这一处，主 App 与设置页共用。
    private static let storageKey = "appLanguage"

    static var stored: AppLanguage? {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:))
    }

    static func store(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
    }

    /// 语言选择器里显示的名字，一律用该语言自己的写法。
    ///
    /// 刻意不走本地化：把「简体中文」翻成 "Simplified Chinese" 之后，一个只会中文的
    /// 用户反而找不到它 —— 语言选项是少数几种必须以自身语言呈现的字符串。
    var endonym: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// 拉丁与中文的可用字形不同，字体设计要跟着语言走。见 `AppFont`。
    var prefersRoundedDesign: Bool {
        self == .english
    }

    /// 系统偏好语言推断出来的语言。
    ///
    /// 给负一屏小组件用：扩展是独立进程，读不到主 App 的 `UserDefaults`（工程里没有
    /// App Group entitlement），所以它只能跟随系统语言。
    static var systemPreferred: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let lowered = identifier.lowercased()
            if lowered.hasPrefix("zh") { return .chinese }
            if lowered.hasPrefix("en") { return .english }
        }
        return .english
    }
}
