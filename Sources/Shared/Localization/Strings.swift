import Foundation

/// 界面文案表。
///
/// **键就是英文原文。** 两个理由：
///
/// 1. 全 App 的调用点一个字都不用改 —— `Text("Battery")` 本来就以 `"Battery"` 为键，
///    `Text("full in \(remaining)")` 的键就是 `"full in %@"`；
/// 2. 漏翻一条不会显示成裸键，而是退回英文，是能用的降级。
///
/// 译文本身在 `en.lproj` / `zh-Hans.lproj` 里 —— 那是**唯一**一份，Swift 这边不再
/// 另存一张字典，免得两边漂移。
///
/// **为什么必须是真实的 `.lproj`，而不是替换 `Bundle.main` 的类。**
/// 这一点值得写清楚，因为它反直觉：SwiftUI 的 `Text("…")`（字面量 → `LocalizedStringKey`）
/// **不走** `Bundle.main.localizedString(forKey:value:table:)`。它有一套独立的解析路径，
/// 按**环境里的 `locale`** 直接去 bundle 的 `.lproj` 里挑译文。所以老一套
/// 「`object_setClass(Bundle.main, …)` 换掉 Bundle 的类」对 SwiftUI 一个字都不生效 ——
/// 只有 `NSLocalizedString` / `String(localized:)` 那条路才会经过它。
///
/// 症状很好认：切换语言后只有**直接查表**的那几条（如设置页的「可用」）跟着变，
/// 其余 `Text("…")` 全部原地不动。
///
/// 结论：想让全 App 的字面量跟着语言走，只有两条路 —— 要么给每个调用点手工包一层，
/// 要么老老实实提供 `.lproj` 并把 `\.locale` 喂进环境（见 `RootView` 里那处
/// `.environment(\.locale,)`）。这里选后者。
///
/// 带参数的条目按 `LocalizedStringKey` 的插值规则写：`String` 是 `%@`，`Int` 是 `%lld`。
/// **键里不要出现裸的 `%`** —— 百分号要作为参数传进来（见 `AdapterView` 里那处
/// 适配器占比），否则得去赌 SwiftUI 有没有把字面量 `%` 转义成 `%%`。
nonisolated enum Strings {

    /// 当前语言下的文案，直接查 `.lproj`。
    ///
    /// 给「键在运行期才知道」的地方用：`DetailRow.transportName`、设置页的可用状态、
    /// `MemoryOptimizer` 的失败原因、图表 series 名。这些调用点本来就得先拿到一个
    /// `String`，而 `Text` 那条路要的是编译期字面量，套不上去。
    ///
    /// 未命中时返回原键 —— 也就是英文原文，和别处的降级行为一致。
    static func text(_ key: String) -> String {
        (bundles[AppLanguage.current] ?? .main)
            .localizedString(forKey: key, value: key, table: nil)
    }

    /// 各语言的 `.lproj` 包，进程内取一次。
    ///
    /// `static let` 的初始化是惰性的、线程安全的，正好用来做这件事；建完之后只读。
    /// 主 App 与扩展各有一份 —— 两边都是 `Bundle.main`，各自指向自己的包。
    nonisolated(unsafe) private static let bundles: [AppLanguage: Bundle] = {
        var map: [AppLanguage: Bundle] = [:]
        for language in AppLanguage.allCases {
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            map[language] = bundle
        }
        return map
    }()
}
