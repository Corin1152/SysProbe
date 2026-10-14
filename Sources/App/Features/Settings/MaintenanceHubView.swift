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
                Picker("Maintenance", selection: $page) {
                    ForEach(MaintenanceSegment.allCases) { segment in
                        segmentLabel(segment).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            },
            content: {
                switch page {
                case .maintenance: MaintenancePanels()
                case .clean: CleanPanels()
                }
            }
        )
    }

    /// 分段标签。「频段」那一项多带一个盾牌图标 —— 它和「清理」只隔一次点击，
    /// 而它是唯一能把手机写进无服务状态的一页，值得在标签上就有个记号。
    ///
    /// 用 `Label` 而不是在文字里塞符号：`Label` 在分段控件里**可能只渲染文字**
    /// （iOS 对分段项图标的支持并不稳定），退化了就是纯文字，不会出问题；
    /// 而在文字里塞「⚠︎」是写死的，改不掉，还会跟着导航栏标题一起走。
    @ViewBuilder
    private func segmentLabel(_ segment: MaintenanceSegment) -> some View {
        if let icon = segment.icon {
            Label(segment.title, systemImage: icon)
        } else {
            Text(segment.title)
        }
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

    /// 分段标签上的图标。现在两个都没有 —— 带记号的那一个是「频段」，
    /// 它已经搬到自己的分页上去了。
    ///
    /// 这个字段留着是因为 `segmentLabel` 的写法：用 `Label` 而不是把符号塞进文字里
    /// （`Label` 在分段控件里可能只渲染文字，退化了就是纯文字，不会出问题）。
    var icon: String? {
        switch self {
        case .maintenance, .clean: return nil
        }
    }
}
