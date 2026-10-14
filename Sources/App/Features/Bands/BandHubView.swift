import SwiftUI

/// 「频段」分页 —— 2026-10-14：从「维护」页的分段里搬出来，独占第 4 个分页。
///
/// ── 为什么搬 ────────────────────────────────────────────────────────────────
///
/// 它原本是「维护」页的第三个分段，与「维护 / 清理」并列。问题是它比另外两个重得多：
/// 唯一会写基带、能把手机写进「无服务」的一页，却排在一条分段栏的最后一格，
/// 而它自己下面还有一长串频段网格要滚。给它一个分页之后，两个分段各自有整屏空间。
///
/// ── 两个分段 ────────────────────────────────────────────────────────────────
///
///   · 「频段锁定」—— 勾选允许哪些频段（原 `BandPanels`，内容没动）；
///   · 「自动刷新」—— 信号到阈值就刷新蜂窝信号（新增，`AutoRefreshPanels`）。
///
/// 两者读的是同一套基带状态，放在一起才说得清「锁了哪几个」与「什么时候刷新」。
struct BandHubView: View {

    /// 右上角齿轮的回调，由 `RootView` 给。
    let openSettings: @MainActor () -> Void

    @State private var page: BandSegment = .lock

    var body: some View {
        PageHubScaffold(
            title: page.title,
            glow: .mwAccent,
            openSettings: openSettings,
            // 齿轮不在外壳渲染：trailing 区三个按钮（保存 / 刷新 / 齿轮）的顺序
            // 必须是「保存最左、齿轮最右」，而父子两处 `.toolbar` 合并时父级
            // 声明的排最左 —— 齿轮必须由内容层自己在分组末尾声明，见 `BandPanels`。
            showsGear: false,
            header: {
                Picker("Bands", selection: $page) {
                    ForEach(BandSegment.allCases) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            },
            content: {
                switch page {
                case .lock: BandPanels(openSettings: openSettings)
                case .autoRefresh: AutoRefreshPanels(openSettings: openSettings)
                }
            }
        )
    }
}

/// 「频段」页的两个分段。
///
/// 「频段锁定」排第一：它是**前提** —— 自动刷新只负责「什么时候重载 modem」，
/// 锁哪些频段由另一个分段决定。
enum BandSegment: Int, CaseIterable, Identifiable {
    /// 读写允许频段。
    case lock
    /// 信号到阈值自动刷新。
    case autoRefresh

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .lock: return "Band lock"
        case .autoRefresh: return "Band refresh"
        }
    }
}
