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
///   · 「频段锁定」—— 勾选允许哪些频段（`BandPanels`，2026-10-14 起四个动作按钮
///     从导航栏与页尾收成一排，放在页面顶部）；
///   · 「频段刷新」—— 信号到阈值就刷新蜂窝信号（`AutoRefreshPanels`）。
///
/// 两者读的是同一套基带状态，放在一起才说得清「锁了哪几个」与「什么时候刷新」。
///
/// ── 右上角 ────────────────────────────────────────────────────────────────
///
/// 只有一个齿轮，装「关于」，由外壳 `PageHubScaffold` 渲染。2026-10-14 之前频段页
/// 把外壳的齿轮关掉、自己在导航栏声明「保存 / 刷新 / 齿轮」三个按钮，为的是控制它们
/// 的顺序；现在那四个动作全部搬进了「频段锁定」分段内部（见 `BandPanels.actionRow`），
/// 这一层不再需要自定义工具栏。
///
/// ── 频段会话为什么在这一层 ──────────────────────────────────────────────────
///
/// 下面那个 `switch page` 是**条件渲染**：切分段会销毁另一个分段的视图、重建这一个。
/// `BandService` 原来挂在 `BandPanels` 里当 `@StateObject`，于是「切回来 = 重建一个
/// 服务 = 重新探卡槽 + 重读基带 + 整屏盖转圈 + 滚动位置归零」—— 用户看到的就是
/// 「进频段锁定页会强制刷新一次页面」。
///
/// 提到分页这一层之后，服务活得比分段久：切回来时 `bandInfo` / `availability` 都还在，
/// 第一帧就是完整数据，刷新在后台静默进行（见 `BandService.ensureLoaded`）。
/// 卡槽选择也一并记住了 —— 它原先也是 `BandPanels` 的 `@State`。
struct BandHubView: View {

    /// 右上角齿轮的回调，由 `RootView` 给。
    let openSettings: @MainActor () -> Void

    @State private var page: BandSegment = .lock

    /// 频段会话：基带读回来的数据 + 当前卡槽。见类型头上的说明。
    @StateObject private var bands = BandService()

    var body: some View {
        PageHubScaffold(
            title: page.title,
            glow: .mwAccent,
            openSettings: openSettings,
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
                case .lock: BandPanels(service: bands)
                case .autoRefresh: AutoRefreshPanels()
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
