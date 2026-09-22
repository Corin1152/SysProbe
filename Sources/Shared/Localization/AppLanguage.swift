import Foundation

/// 界面语言。
///
/// 存在 `UserDefaults` 里，切换后**不重启**即可生效 —— 具体机制见
/// `LocalizedBundle`。
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

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
