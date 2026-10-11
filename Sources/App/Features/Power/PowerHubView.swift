import SwiftUI

/// 「电源」分页 —— 原来的「电源 / 适配器 / 智充」三页收成这一页的四个分段。
///
/// ── 为什么要合 ──────────────────────────────────────────────────────────────
///
/// 这三页回答的是同一件事的不同侧面：这一秒电从哪来、去了哪、怎么拦住它。
/// 拆成三个底部分页之后，想对照「适配器给了 5 V」和「充电控制在 40% 停」要横跨两页，
/// 而它们本来就该一起看。合成一页 + 分段控件，底部分页栏也腾出位置给了
/// 「维护」和「关于」（那两页原来藏在齿轮里）。
///
/// ── 分段内容的约定 ──────────────────────────────────────────────────────────
///
/// 四个分段**各自带滚动容器**，不套在这一层里 —— 理由见 `PageHubScaffold`。
/// 它们的 `PageScaffold` / 导航栈也都被去掉了：一页只能有一个导航栈，标题由这里按
/// 当前分段给。
///
/// 切换用 `switch` **条件渲染**，不是嵌套 `TabView`：后者会把四页一次性全建出来，
/// 等于四个页面同时跑每秒采样。
struct PowerHubView: View {

    @EnvironmentObject private var monitor: PowerMonitor

    @State private var page: PowerSegment = .draw

    private var snapshot: PowerSnapshot { monitor.snapshot }

    var body: some View {
        PageHubScaffold(
            title: page.title,
            glow: glow,
            header: {
                Picker("Power", selection: $page) {
                    ForEach(PowerSegment.allCases) { segment in
                        Text(segment.title).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            },
            content: {
                switch page {
                case .draw: DashboardPanels()
                case .adapter: AdapterPanels()
                case .control: ChargeControlPanels()
                case .battery: ChargeBatteryPanels()
                }
            }
        )
    }

    /// 背景光晕。规则住在 `PowerSegment.glow` —— 功率环的 tint 用的是同一个函数，
    /// 两处对不上时看起来像坏了。
    private var glow: Color {
        PowerSegment.glow(for: page,
                          throttling: monitor.thermalState.isThrottling,
                          wirelessInput: snapshot.isWirelessInput,
                          externalConnected: snapshot.externalConnected)
    }
}

/// 「电源」页的四个分段。
///
/// 顺序是明确要求的：功率 → 适配器 → 充电控制 → 电池信息。
/// 从「电从哪来」到「怎么管它」再到「电池本身是什么状态」，是一条能顺着读下去的线。
///
/// `title` 同时当分段标签与导航栏标题用 —— 一处定义，两处显示，不会漂移。
enum PowerSegment: Int, CaseIterable, Identifiable {
    /// 原 `DashboardView`（底部分页「电源」）。
    case draw
    /// 原 `AdapterView`（底部分页「适配器」）。
    case adapter
    /// 原「智充」页的分段 1。
    case control
    /// 原「智充」页的分段 2。
    case battery

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        // 注意：**不是** "Power"。底部分页已经叫「电源」（键 "Power"），
        // 这里再叫一次会让「标题」与「分段标签」重名，用户看不出自己在哪一层。
        case .draw: return "Power draw"
        case .adapter: return "Adapter"
        case .control: return "Charge control"
        case .battery: return "Battery info"
        }
    }

    /// 背景光晕 / 功率环的颜色。逐条沿用各分段**原来在自己页面里**的规则，
    /// 合并之后不做统一 —— 那会把「热到降频」这类信号抹掉。
    ///
    ///   · 功率：降频时红色；无线充电紫色；插着电青色；电池供电橙色（`mwLoss`）；
    ///   · 适配器：无线紫色，有线青色；
    ///   · 充电控制 / 电池信息：电池绿。
    ///
    /// **两个调用点，必须是同一个值**：`PowerHubView` 拿它当整页光晕，
    /// `DashboardPanels` 拿它当功率环的 tint。原来这两处在 `DashboardView` 里
    /// 就是同一个 `glowColor`；拆开之后如果不共用，环的颜色会与背景对不上，
    /// 看起来像是坏了 —— 而且不会有任何报错。
    static func glow(for segment: PowerSegment,
                     throttling: Bool,
                     wirelessInput: Bool,
                     externalConnected: Bool) -> Color {
        switch segment {
        case .draw:
            if throttling { return .mwDanger }
            if wirelessInput { return .mwWireless }
            return externalConnected ? .mwAccent : .mwLoss
        case .adapter:
            return wirelessInput ? .mwWireless : .mwAccent
        case .control, .battery:
            return .mwBattery
        }
    }
}
