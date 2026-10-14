import SwiftUI

/// 「电源」分页 —— 「功率 / 充电控制」两个分段。
///
/// ── 2026-10-14：从三个分段收成两个 ──────────────────────────────────────────
///
/// 「适配器」那一格去掉了：它去掉三张卡片之后剩下的「广播档位」与「线缆与连接」
/// 并进了「功率」分段（理由见 `DashboardPanels` 头上那段）。现在这条分段栏回答的是
/// 两个问题 —— **这一秒电从哪来、去了哪**，以及**怎么把它拦住**。
///
/// ── 分段内容的约定 ──────────────────────────────────────────────────────────
///
/// 每个分段**各自带滚动容器**，不套在这一层里 —— 理由见 `PageHubScaffold`。
/// 它们的 `PageScaffold` / 导航栈也都被去掉了：一页只能有一个导航栈，标题由这里按
/// 当前分段给。
///
/// 切换用 `switch` **条件渲染**，不是嵌套 `TabView`：后者会把几页一次性全建出来，
/// 等于几个页面同时跑每秒采样。
struct PowerHubView: View {

    /// **直接观察 `PowerMonitor`**（每秒发布一次）。
    ///
    /// ── 2026-10-14：从 `PowerContext` 改回来 ──────────────────────────────────
    ///
    /// 0.0.61 前后把它换成 `PowerContext`，为的是「外壳不要跟着每秒重算」。方向没错，
    /// 但当时是**和「非当前分段停止求值」一起改的**——那一套的代价（切换时分段内容
    /// 整页重建、再补一层淡入去盖它）比这点收益大得多，用户实机对比 0.0.56 的结论是
    /// 「56 版更流畅」。所以整体退回 0.0.56 的写法：外壳重算就重算，它只是几个
    /// label 和一层背景；换来的是分段内容**从切走那一刻起就一直在**，切回来是
    /// 已经画好的东西，不需要重建。
    ///
    /// 分段内容该实时还是实时 —— `DashboardPanels` 那些面板自己读 `PowerMonitor`。
    @EnvironmentObject private var monitor: PowerMonitor

    /// 右上角齿轮的回调，由 `RootView` 给。
    let openSettings: @MainActor () -> Void

    @State private var page: PowerSegment = .draw

    private var snapshot: PowerSnapshot { monitor.snapshot }

    var body: some View {
        PageHubScaffold(
            title: page.title,
            glow: glow,
            openSettings: openSettings,
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
                // 裸 `switch`，**不带 `.id(page)`** —— 与 0.0.56 一致。
                //
                // 0.0.63 加过一层 `.id(page)`（为了让内容一定跟着分段换）。代价是
                // 每次切换都**丢弃整棵子树再重建**：圆环、四行读数、档位表全部重新
                // 布局一遍，那一帧就是用户看到的卡顿。而它要修的那个问题
                // （「极小概率点了分段没反应」）在 0.0.63 换成自绘控件之后已经
                // 不存在了 —— 那本来是系统 `UISegmentedControl` 的选中态被外壳
                // 重算重置造成的，现在用的是系统分段控件但外壳不再拦截它的更新。
                switch page {
                case .draw: DashboardPanels()
                case .control: ChargeControlPanels()
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

/// 「电源」页的两个分段。
///
/// 顺序是明确要求的：功率 → 充电控制。从「电从哪来」到「怎么管它」，
/// 是一条能顺着读下去的线。
///
/// 「适配器」原本是第二格（2026-10-11 加的），2026-10-14 随内容并入「功率」而取消 ——
/// 见 `DashboardPanels` 头上那段。两个分段的文案键保持原样
/// （`"Power draw"` / `"Charge control"`，中文落到「功率」/「充电控制」）。
///
/// `title` 同时当分段标签与导航栏标题用 —— 一处定义，两处显示，不会漂移。
enum PowerSegment: Int, CaseIterable, Identifiable {
    /// 功率：圆环、电池、供电路径，以及从「适配器」迁来的广播档位 / 线缆与连接。
    case draw
    /// 充电控制 + 电池信息。
    case control

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        // 注意：**不是** "Power"。底部分页已经叫「电源」（键 "Power"），
        // 这里再叫一次会让「标题」与「分段标签」重名，用户看不出自己在哪一层。
        case .draw: return "Power draw"
        case .control: return "Charge control"
        }
    }

    /// 背景光晕 / 功率环的颜色。逐条沿用各分段**原来在自己页面里**的规则，
    /// 合并之后不做统一 —— 那会把「热到降频」这类信号抹掉。
    ///
    ///   · 功率：降频时红色；无线充电紫色；插着电青色；电池供电橙色（`mwLoss`）；
    ///   · 充电控制：电池绿。
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
        case .control:
            return .mwBattery
        }
    }
}
