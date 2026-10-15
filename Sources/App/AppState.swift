import SwiftUI

/// 右上角齿轮下拉菜单里的两项。
///
/// ── 2026-10-15：从「只有一个关于」扩成两项 ──────────────────────────────────
///
/// 底部分页栏取消了「维护」那一格（页码收成 硬件 / 电源 / 频段 / 进程）。
/// 维护页剩下的东西分成两半：**改系统状态的**（重启设备 / 注销 / 网络唤醒）
/// 收进这里的 `.maintenance`；**动充电行为的**（关闭温控降频）搬去了电源页的
/// 基础卡片末尾。
///
/// 标题与图标住在这里而不是各个调用点：四个分页的外壳都要画同一个菜单
/// （`SettingsMenuButton`），各写一份必然会漂移。
enum SettingsDestination: String, Identifiable, CaseIterable {
    /// 重启设备 / 注销 / 网络唤醒。
    case maintenance
    /// 版本号与诊断。
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .maintenance: return "Maintenance"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .maintenance: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

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

    /// 界面语言。**固定跟随系统，用户不可改**（2026-10-11 起）。
    ///
    /// 它仍然是 `@Published`，因为 `RootView` 拿它做两件事：喂给环境里的
    /// `\.locale`（`Text("…")` 按这个去 `.lproj` 里挑译文），以及当 `.id` 让整棵
    /// 分页树换 identity（换语言时字形要跟着换，见 `RootView.tabs` 的说明）。
    /// 这两条路径都还在，只是值不再来自用户的开关。
    ///
    /// 在 `init` 里定一次就够：iOS 在系统语言变更时会重启 App，不需要在运行期
    /// 盯着 `Locale.preferredLanguages` 变。负一屏扩展同理，见 `TodayViewController`。
    @Published private(set) var language: AppLanguage = .systemPreferred

    @Published var selectedTab = 0

    /// 右上角齿轮下拉菜单里正在打开的那一项。`nil` = 没有弹层。
    ///
    /// ── 2026-10-15：从 `Bool` 换成这一组枚举 ────────────────────────────────
    ///
    /// 原来是 `showingSettings: Bool`，只装「关于」。这一版取消了「维护」分页，
    /// 它剩下的东西（重启设备 / 注销 / 网络唤醒）没有别处可去，全部收进齿轮的
    /// 第二个菜单项 —— 于是齿轮从一个直接动作变成一个 `Menu`，状态也就从
    /// 「开没开」变成「开的是哪一个」。
    ///
    /// 用 `Identifiable` 的枚举而不是两个 `Bool`：后者会出现「两个同时为真」这种
    /// 表达得出来、但不该存在的状态，而 `.sheet(item:)` 天然不允许。
    @Published var settingsSheet: SettingsDestination?

    init() {
        // `AppFont` 与 `Strings.text` 读的是 `AppLanguage.current` 这个全局，
        // 而它得在第一帧之前就位 —— 见 `SysProbeApp.init` 里同一句话。
        AppLanguage.current = language
    }
}
