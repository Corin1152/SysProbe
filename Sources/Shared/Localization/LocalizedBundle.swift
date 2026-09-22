import Foundation
import ObjectiveC

/// `Bundle.main` 的替身。
///
/// **为什么需要替换类而不是别的做法。** 全 App 的文案都是以字面量形式写的 ——
/// `Text("Battery")`、`EmptyNote(text: "…")`、`String(localized: "Wireless")` ——
/// 而这三条路径最终都会落到
/// `Bundle.main.localizedString(forKey:value:table:)`。把 `Bundle.main` 的类换成这个
/// 子类，就能让**所有已经写好的调用点**跟着运行时选的语言走，一个都不用改；
/// 否则就得给每个调用点手工塞一个语言参数，几百处。
///
/// **为什么不走 `.lproj`。** 工程由 XcodeGen 从 `project.yml` 生成，没有 Xcode 工程
/// 文件可以勾选本地化；文案放在 Swift 里，资源打包、`knownRegions`、`CFBundleLocalizations`
/// 这些环节就全都不存在了，扩展进程也天然能拿到同一份表。
///
/// **为什么不调 `super`。** 我们一个 `.strings` 文件都不带，所以「键不在表里」时的正确
/// 返回值就是 `value ?? key` —— 这正是 NSBundle 找不到键时的行为。绕开 `super` 还顺带
/// 避免了在换了类的实例上调回 NSBundle 实现（那会读原类的实例变量）。
nonisolated final class LocalizedBundle: Bundle {

    /// 当前语言。`nonisolated(unsafe)`：读它的地方是 `localizedString` 这个
    /// nonisolated 的 ObjC 覆盖点，够不到主 actor；写入只发生在主 actor 上的
    /// `AppState`，一读一写都是原子地换一个枚举值，没有撕裂的可能。
    nonisolated(unsafe) static var language: AppLanguage = .systemPreferred

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        Strings.translation(for: key, language: Self.language) ?? value ?? key
    }
}

/// 一次性把 `Bundle.main` 的类换掉。
///
/// 幂等，且要在任何界面渲染之前调用 —— 见 `SysProbeApp.init` 与
/// `TodayViewController.viewDidLoad`。
nonisolated enum LocalizationBootstrap {

    /// `static let` 的初始化是惰性的、线程安全的，正好用来做这件事的「只跑一次」。
    private static let installed: Void = {
        object_setClass(Bundle.main, LocalizedBundle.self)
    }()

    static func install() {
        _ = installed
    }
}
