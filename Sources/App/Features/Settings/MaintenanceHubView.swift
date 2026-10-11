import SwiftUI

/// 「维护」分页 —— 原来藏在右上角齿轮里的三页（维护 / 清理 / 频段）收成这一页的分段。
///
/// ── 为什么搬出来 ────────────────────────────────────────────────────────────
///
/// 它们本来就在齿轮里，问题是**没人找得到**：三行菜单挂在导航栏右上角，进去是盖满全屏的
/// 一层，返回只能点左上角。其中「频段」是唯一会写坏系统状态的一页，却排在菜单第二行、
/// 与「关于」这种纯信息页并列。搬到分页栏上之后它们一级可达，而齿轮没有内容可装 ——
/// 整个删掉。
///
/// ── 分段内容的约定 ──────────────────────────────────────────────────────────
///
/// 三个分段**各自带滚动容器**（维护是 `Form`，清理与频段是 `ScrollView`），
/// 所以外壳用 `PageHubScaffold` 而不是 `PageScaffold`。理由见 `PageHubScaffold` 的说明。
struct MaintenanceHubView: View {

    @State private var page: MaintenanceSegment = .maintenance

    /// 「频段」那一项是否出现。与 `BandPanels` 读的是同一个键 ——
    /// 频段页里的「隐藏这一页」写的就是它。
    ///
    /// 关掉之后**没有地方能再打开**，这是故意的：一个能随手关掉又能随手打开的开关
    /// 挡不住误触。见 `BandPanels` 里第 4 层警告的说明。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    var body: some View {
        PageHubScaffold(
            title: page.title,
            glow: .mwAccent,
            header: {
                Picker("Maintenance", selection: $page) {
                    ForEach(visibleSegments) { segment in
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
                case .bands: BandPanels()
                }
            }
        )
        // 频段页里的「隐藏这一页」把开关关掉之后，分段栏里就没有它了 ——
        // 但选中态还停在它上面，`Picker` 会渲染成「三个里一个都没选」。
        // 这里把它挪回维护：开关一关，用户眼前立刻就是维护页，不会看到一段空档。
        .onChange(of: showBandEditor) { visible in
            if !visible, page == .bands {
                page = .maintenance
            }
        }
    }

    private var visibleSegments: [MaintenanceSegment] {
        showBandEditor
            ? MaintenanceSegment.allCases
            : MaintenanceSegment.allCases.filter { $0 != .bands }
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

/// 「维护」页的三个分段。顺序是明确要求的：维护 → 清理 → 频段。
///
/// 频段排最后不是随意的：它风险最高，不该紧挨着「清理」那种点一下就好的动作。
enum MaintenanceSegment: Int, CaseIterable, Identifiable {
    /// 重启设备 / 注销 / 关温控 / 网络唤醒 / 语言。
    case maintenance
    /// 磁盘缓存扫描与清理。
    case clean
    /// 基带频段读写 —— 全 App 唯一会写坏系统状态的一页。
    case bands

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .maintenance: return "Maintenance"
        case .clean: return "Clean"
        case .bands: return "Bands"
        }
    }

    /// 只有频段带记号。
    var icon: String? {
        switch self {
        case .bands: return "exclamationmark.shield.fill"
        case .maintenance, .clean: return nil
        }
    }
}
