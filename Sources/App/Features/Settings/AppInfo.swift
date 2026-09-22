import Foundation

/// 「关于 / 诊断」里显示的版本与扩展信息。
///
/// 存在的理由很实际：负一屏一直显示「无法载入」，而排查第一步就是确认
/// **装的是哪一版**、**扩展有没有被正确打进包里**。这两件事都能从 bundle 里直接读出来，
/// 比让用户去翻文件系统可靠 —— 显示出来的就是**这一版**的真实内容。
enum AppInfo {

    /// 主 App 的版本，例如 `0.0.1 (17)`。
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// 负一屏扩展的摘要。
    ///
    /// 读的是打进包里的那份 `Info.plist`，所以它反映的是**这一版**的真实内容 ——
    /// 如果这里显示的 bundle id 与预期不符，说明装的还是旧版本。
    static var widgetSummary: String {
        guard let plist = widgetInfoDictionary else { return Strings.text("not bundled") }
        let identifier = plist["CFBundleIdentifier"] as? String ?? "—"
        let short = plist["CFBundleShortVersionString"] as? String ?? "—"
        let extensionInfo = plist["NSExtension"] as? [String: Any]
        let point = extensionInfo?["NSExtensionPointIdentifier"] as? String
        // 只把两种点标识翻译成人话，其余原样显示 —— 认不出来的值本身就是线索。
        let kind: String
        switch point {
        case "com.apple.widget-extension": kind = "Today"
        case "com.apple.widgetkit-extension": kind = "WidgetKit"
        default: kind = point ?? "—"
        }
        return "\(kind) · \(short) · \(identifier)"
    }

    /// 扩展的 `Info.plist`。读不到就返回 nil —— 那说明扩展没被打进包里。
    ///
    /// 路径写死成 `PlugIns/TodayExtension.appex`：扩展的 `PRODUCT_NAME` 变了这里也要跟着改，
    /// 但那时 `widgetSummary` 会显示「not bundled」，一眼就能看出来。
    private static var widgetInfoDictionary: [String: Any]? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("PlugIns")
            .appendingPathComponent("TodayExtension.appex")
            .appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: url) as? [String: Any]
    }
}
