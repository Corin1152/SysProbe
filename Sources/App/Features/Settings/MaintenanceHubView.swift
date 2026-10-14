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

    @State private var page: MaintenanceSegment = .maintenance

    var body: some View {
        PageHubScaffold(
            title: page.title,
            glow: .mwAccent,
            openSettings: openSettings,
            header: {
                Picker("Maintenance", selection: $page) {
                    ForEach(MaintenanceSegment.allCases) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            },
            content: {
                // 裸 `switch`，**不带 `.id(page)`** —— 理由见 `PowerHubView` 里那段：
                // 加 identity 会让每次切换丢弃整棵子树再重建，而它要修的那个问题
                // （系统分段控件的选中态被外壳重算重置）已经不存在了。
                switch page {
                case .maintenance: MaintenancePanels()
                case .clean: CleanPanels()
                }
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
