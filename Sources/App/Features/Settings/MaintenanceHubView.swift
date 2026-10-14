import SwiftUI

/// 「维护」分页 —— 原来藏在右上角齿轮里的几页收成这一页的分段。
///
/// ── 为什么搬出来 ────────────────────────────────────────────────────────────
///
/// 它们本来就在齿轮里，问题是**没人找得到**：几行菜单挂在导航栏右上角，进去是盖满全屏的
/// 一层，返回只能点左上角。搬到分页栏上之后一级可达。
///
/// ── 2026-10-14：「频段」搬走了 ──────────────────────────────────────────────
///
/// 它与「维护 / 清理」不是一路：唯一会写基带、能把手机写进「无服务」的一页，
/// 下面还多出一个「自动刷新」分段。现在它独占第 4 个分页（见 `BandHubView`），
/// 这一页回到两个分段。「隐藏这一页」关掉的是**整个分页**（在 `RootView` 里判），
/// 不是这里的某一格。
///
/// ── 分段内容的约定 ──────────────────────────────────────────────────────────
///
/// 两个分段**各自带滚动容器**（维护是 `Form`，清理是 `ScrollView`），
/// 所以外壳用 `PageHubScaffold` 而不是 `PageScaffold`。理由见 `PageHubScaffold` 的说明。
struct MaintenanceHubView: View {

    /// 右上角齿轮的回调，由 `RootView` 给。
    let openSettings: @MainActor () -> Void

    /// 这一页是不是当前选中的分页。见 `PageScaffold.isActive` —— 非当前分页会
    /// 停止求值内容，不然它会跟着每秒一次的采样一直重算（`DeferredContent`）。
    let isActive: Bool

    @State private var page: MaintenanceSegment = .maintenance

    var body: some View {
        PageHubScaffold(
            title: page.title,
            glow: .mwAccent,
            isActive: isActive,
            openSettings: openSettings,
            header: {
                // 自绘分段控件 —— 命中高度显式给定，切换不经过第二步同步。
                // 理由见 `SegmentedTabs` 类型头。
                SegmentedTabs(items: MaintenanceSegment.allCases, selection: $page, title: { $0.title })
            },
            content: {
                // `.id(page)`：给内容一个显式 identity，分段一切换就丢弃旧子树、
                // 构建新子树，不依赖 SwiftUI 对 `_ConditionalContent` 的自动判断 ——
                // 用户报过的「极小概率点了分段没反应」正是那条路径最坏情况下丢了
                // 一次更新（高亮变了、内容没变）。理由详注见 `PowerHubView`。
                Group {
                    switch page {
                    case .maintenance: MaintenancePanels()
                    case .clean: CleanPanels()
                    }
                }
                .id(page)
            }
        )
    }
}

/// 「维护」页的两个分段。2026-10-14 起「频段」不再是这里的一格 —— 它搬去了
/// 第 4 个分页（见 `BandHubView`）。
enum MaintenanceSegment: Int, CaseIterable, Identifiable {
    /// 重启设备 / 注销 / 关温控 / 网络唤醒 / 语言。
    case maintenance
    /// 磁盘缓存扫描与清理。
    case clean

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .maintenance: return "Maintenance"
        case .clean: return "Clean"
        }
    }
}
