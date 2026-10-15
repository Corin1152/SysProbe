import SwiftUI

/// 「电源」分页 —— 2026-10-15 起是**单页**：功率在上、充电控制在下。
///
/// ── 从「分段 + 外壳」收成单页 ────────────────────────────────────────────────
///
/// 原来这一页是 `PageHubScaffold` + 两个分段（功率 / 充电控制），靠一个 `Picker` 切。
/// 按要求取消分段，两段内容顺次排下来 —— 于是这一页与「硬件」页是同一种结构
/// （`PageScaffold` + 一串卡片）。
///
/// 一并去掉的还有 `PowerSegment` 那个枚举：它原来同时承担三件事（分段标签、
/// 导航栏标题、光晕配色）。现在只剩最后一件 —— 光晕，也就是 `PowerGlow`。
///
/// 「分段内容各自观察自己的采样对象」这件事没变（见 `DashboardPanels` /
/// `ChargeControlPanels` 的类型头）；不再有「切走就销毁」的问题，反而更简单了。
///
/// ── 为什么两个分段视图各自返回 `Group` 而不是 `VStack` ──────────────────────
///
/// `PageScaffold` 的内容被放进它自己的 `LazyVStack`。`Group` **不产生布局容器**，
/// 它的子视图会被展平成 `LazyVStack` 的直接元素 —— 于是每张卡片仍然是独立的懒加载
/// 单元，滚出屏幕的不会被建出来。换成 `VStack` 就只剩一个元素了：十几张卡片
/// （含功率环、8 条每核占用条）会在进页面那一帧全部建出来。
///
/// 间距不用管：`PageScaffold` 的 `LazyVStack` 给的是 14，与原来两个分段各自的
/// `LazyVStack` 是同一个数。
struct PowerView: View {

    /// 右上角齿轮的回调，由 `RootView` 给。
    let openSettings: @MainActor (SettingsDestination) -> Void

    /// 只读它来算整页光晕 —— 分段内容该实时还是实时，那些面板自己读 `PowerMonitor`。
    @EnvironmentObject private var monitor: PowerMonitor

    private var snapshot: PowerSnapshot { monitor.snapshot }

    var body: some View {
        PageScaffold("Power", glow: glow, openSettings: openSettings) {
            // 顺序即阅读顺序：先「电从哪来、去了哪」（功率），再「怎么把它拦住」（充电控制）。
            DashboardPanels()
            ChargeControlPanels()
        }
    }

    /// 背景光晕。规则住在 `PowerGlow` —— 功率环的 tint 用的是同一个函数，
    /// 两处对不上时看起来像坏了，而且不会有任何报错。
    private var glow: Color {
        PowerGlow.color(throttling: monitor.thermalState.isThrottling,
                        wirelessInput: snapshot.isWirelessInput,
                        externalConnected: snapshot.externalConnected)
    }
}

/// 电源页的背景光晕 / 功率环 tint。
///
/// 原来叫 `PowerSegment.glow(for:...)`，按分段给不同颜色（功率一套、充电控制一套）。
/// 收成单页之后只剩一套 —— 就是原来「功率」那一套：降频时红色、无线充电紫色、
/// 插着电青色、电池供电橙色。
///
/// **两个调用点，必须是同一个值**：`PowerView` 拿它当整页光晕，`DashboardPanels`
/// 拿它当功率环的 tint。这两处在更早的 `DashboardView` 里本来就是同一个
/// `glowColor`；拆开之后如果不共用，环的颜色会与背景对不上，看起来像是坏了。
enum PowerGlow {
    static func color(throttling: Bool, wirelessInput: Bool, externalConnected: Bool) -> Color {
        if throttling { return .mwDanger }
        if wirelessInput { return .mwWireless }
        return externalConnected ? .mwAccent : .mwLoss
    }
}
