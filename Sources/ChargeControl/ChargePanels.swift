import SwiftUI

/// 「电源」页的下半截 —— 充电控制。**这是一段内容，不是页面。**
///
/// ## 为什么是原生界面，而不是守护进程托管的那份网页
///
/// 移植前评估过「把 web 前端改造成 SysProbe 的样子再塞进 WebView」，也照那个思路
/// 写了一份（随包发布的 `www/` 就是它）。真到落地时两个 WebView 都用不了：
///
/// - **WKWebView**：本 App 必须带 `com.apple.private.security.no-container`
///   （要 `posix_spawn` 一个 root 子进程，见 `Support/SysProbe.entitlements`），
///   而 iOS 16 起 WKWebView 要求 `container-required`，两者互斥 —— 这是
///   ChargeLimiter 作者自己在 `ui.mm` 里写下的结论；
/// - **UIWebView**：iOS 26 SDK 已把它从公开 API 里去掉，而 CI 跑在 Xcode 26 上，
///   编译都过不去。它没有替代品：这个 App 的场景就是不能用 WKWebView。
///
/// 所以这一段用 SwiftUI 重写。视觉与交互跟设计稿一致，而且直接复用了 App 自己的
/// `Panel` / `BarRow` / 配色与字体 —— 比嵌一层网页更贴合，也少一整套
/// 「WebView 加载失败 / 白屏 / 手势冲突」的失败模式。
///
/// `www/` 仍然随包发布：它是守护进程的 web root（删掉只会多一种失败模式），
/// 同时也是一道保险 —— 界面出问题时，在 Safari 里打开 `http://127.0.0.1:1230`
/// 依然能手动停充。关于页里有这个地址。
///
/// ── 2026-10-11 ──────────────────────────────────────────────────────────────
///
/// 这里原本还有一个 `ChargeControlView`（一个带两段 `Picker` 的独立分页「智充」）。
/// 现在「智充」这个名字没有了：这一段并入了 `PowerView`，外壳由它提供。
///
/// ── 2026-10-15 ──────────────────────────────────────────────────────────────
///
/// 电源页从「分段 + 外壳」收成单页（功率在上、这一段在下），于是这里**又去掉了一层
/// 滚动容器**：以前它自己套一个 `ScrollView`，是因为 `PageHubScaffold` 只提供画布；
/// 现在 `PageScaffold` 提供滚动，再套一层就是嵌套滚动 —— 症状是「这一页滑不动」，
/// 而且不报任何错。改成 `Group`，与 `DashboardPanels` 同一个形状、同一个理由
/// （见那边类型头关于 `Group` 与 `LazyVStack` 的说明）。
///
/// 同一天还搬走了两样：
///
///   · **「关闭温控降频」从维护页搬进来**，落在「基础」卡片末尾（`ThermalThrottlePanel`）；
///   · **电池卡片并进了功率页那一张**（`DashboardPanels.batteryPanel`）—— 两张卡片
///     说的是同一个东西的两面，分在两处、中间还隔着一次分段切换，看个「循环次数」
///     要滚两次屏。重复的「电压 / 电流」两行按要求只留了功率页那一份。

// ══════════════════════════════════════════════════════════════════════════════
//  电源页下半截：充电控制
// ══════════════════════════════════════════════════════════════════════════════

/// 电源页下半截 —— 充电控制。
///
/// 卡片顺序：基础（含智能停充 / 关温控降频）→ 容量阈值 → 温度控制。
/// 原来排在这里的「电池」「电池参数」两张卡片已经并进功率页的电池卡片，
/// 所以这一段收尾在「温度控制」上。
struct ChargeControlPanels: View {
    @EnvironmentObject private var charge: ChargeControlService

    /// 「容量阈值」与「温度控制」两张卡片的折叠开关（2026-10-15 新增）。
    ///
    /// **默认折叠**（同一天按要求从「默认展开」改成这样）。原来担心「收起之后
    /// 用户以为功能没了」，但收起态在标题行右侧写了当前区间
    /// （`20–80%` / `20–35°`），信息并没有丢 —— 而这两张卡加起来四根滑块、
    /// 纵向占掉小半屏，默认铺开会把这一页真正要看的东西（上面那几张读数卡）
    /// 挤出首屏。要调的人点一下标题就展开，这一次点击换来的是整页的可读性。
    ///
    /// 不持久化：与频段页、进程页的折叠一致，折叠是一次浏览里的临时姿态。
    @State private var thresholdsExpanded = false
    @State private var temperatureExpanded = false

    var body: some View {
        Group {
            ChargeServiceNote()

            basicsPanel
            thresholdsPanel
            temperaturePanel
        }
    }

    private var basicsPanel: some View {
        Panel("Basics", systemImage: "switch.2",
              trailing: charge.daemonRunning ? Text("Service running") : Text("Service stopped")) {
            VStack(spacing: 12) {
                ToggleRow("Enable", isOn: Binding(get: { charge.config.enable },
                                                  set: { charge.setEnable($0) }))

                // 关掉总开关时，下面这几项仍然可调 —— 守护进程照样收，只是不执行。
                // 这样用户可以先配好再打开，不必反过来。
                //
                // 「模式」的说明文案原本独占一行挂在下面，2026-10-11 按要求挪进这一行
                // ——挤在标题与右侧取值之间，字号缩一档。见 `MenuRow.detail`。
                MenuRow("Mode",
                        value: Text(charge.config.mode.title),
                        detail: charge.config.mode.detail,
                        tint: .mwAccent) {
                    ForEach(ChargeMode.allCases) { mode in
                        Button { charge.setMode(mode) } label: { Text(mode.title) }
                    }
                }

                MenuRow("Update frequency",
                        value: Text(verbatim: "\(charge.config.updateFrequency) s"),
                        tint: .mwAccent) {
                    ForEach(Self.frequencies, id: \.self) { seconds in
                        Button { charge.setUpdateFrequency(seconds) } label: { Text(verbatim: "\(seconds) s") }
                    }
                }

                // ── 2026-10-11：从「高级」卡片搬过来的一项 ──────────────────────
                //
                // 「高级」里原有六项（Prefer SmartBattery / 智能停充 / 停充时启用禁流 /
                // 热模拟 / PPM 模拟 / 限流），只留「智能停充」挪到这张卡片末尾，
                // 其余移除（「重置全部设置」也在同一天删掉了）。
                //
                // 被移除的五项里，前四项是**实验性开关**（上游 ChargeLimiter 的调试入口），
                // 「限流」是给特定充电器兜底用的 —— 它们都仍然在守护进程的配置里，
                // 只是不再有界面入口；已经设过的值原样保留。
                Divider().overlay(Color.mwCardStroke)

                ToggleRow("Predictive charge inhibit",
                          isOn: Binding(get: { charge.config.predictiveInhibit },
                                        set: { charge.setPredictiveInhibit($0) }))

                // ── 2026-10-15：从维护页搬过来的一块 ────────────────────────────
                //
                // 它改的是 `thermalmonitord`，而那个守护进程**降的正是充电电流** ——
                // 放在「充电控制」这张卡片里、紧挨着「智能停充」，比放在一页叫
                // 「维护」的地方更贴。整块内容与它那一套安全性说明见
                // `ThermalThrottlePanel`。
                //
                // 分隔线在这里是必需的：这一块自带标题与说明文字，直接接在
                // 「智能停充」那一行下面会被读成它的注解。上面那条线把
                // 「智能停充」从三个设置项里分出来，这条线把温控块从它分出来 ——
                // 两条线各自对应一次话题切换。
                Divider().overlay(Color.mwCardStroke)

                ThermalThrottlePanel()
            }
        }
    }

    private var thresholdsPanel: some View {
        Panel("Capacity thresholds", systemImage: "battery.50",
              // 收起时在标题行右侧补一个「当前区间」—— 不然收起之后这一张什么都不
              // 说，而「我设的是多少」正是收起状态下唯一还想知道的事。展开时不重复：
              // 内容里那两个滑块自己就带着值。
              trailing: thresholdsExpanded ? nil : Text(verbatim: "\(charge.config.chargeBelow)–\(charge.config.chargeAbove)%"),
              expanded: $thresholdsExpanded) {
            VStack(spacing: 16) {
                ThresholdSlider(title: "Start charging below",
                                value: charge.config.chargeBelow,
                                range: 10...80,
                                unit: "%",
                                tint: .mwAccent,
                                onChange: { charge.setChargeBelow($0) })
                ThresholdSlider(title: "Stop charging above",
                                value: charge.config.chargeAbove,
                                range: 30...100,
                                unit: "%",
                                tint: .mwBattery,
                                onChange: { charge.setChargeAbove($0) })
            }
        }
    }

    private var temperaturePanel: some View {
        Panel("Temperature control", systemImage: "thermometer.medium",
              // 与上面那张同一个写法：摘要只在收起时出现。区间写成
              // 「恢复阈值–停止阈值」，与卡片里两个滑块的自上而下顺序相反 ——
              // 摘要读的是**区间**（低到高），而滑块排的是**动作顺序**
              // （先定上限，再定下限）。两者不冲突，各自都对。
              trailing: temperatureExpanded ? nil : Text(verbatim: "\(charge.config.temperatureBelow)–\(charge.config.temperatureAbove)°"),
              expanded: $temperatureExpanded) {
            VStack(spacing: 16) {
                // 这里原本还有一个「温度控制」开关，2026-10-11 按要求删掉了 ——
                // 它并入「基础」卡片里的「启用」总开关：总开关打开就等于温度控制生效。
                // 写入在 `ChargeControlService.setEnable`，守护进程侧的老配置由
                // `reconcileTemperatureControl` 对齐。
                //
                // 两个阈值仍然只在总开关打开时可调，所以套一层单独的 `VStack` 再禁用它。
                //
                // **`.disabled()` 会向整棵子树传播** —— 早先把它套在最外层那个 `VStack` 上，
                // 结果连上面那个总开关自己也一起被禁掉了；而它默认是关的，于是永远打不开，
                // 整块看上去就是「点了没反应」。这类错误不会报任何编译或运行错误。
                VStack(spacing: 16) {
                    ThresholdSlider(title: "Stop charging above (°C)",
                                    value: charge.config.temperatureAbove,
                                    range: 20...45,
                                    unit: "°",
                                    tint: .mwLoss,
                                    onChange: { charge.setTemperatureAbove($0) })
                    ThresholdSlider(title: "Resume charging below (°C)",
                                    value: charge.config.temperatureBelow,
                                    range: 10...40,
                                    unit: "°",
                                    tint: .mwAccent,
                                    onChange: { charge.setTemperatureBelow($0) })
                }
                .disabled(!charge.config.enable)
                .opacity(charge.config.enable ? 1 : 0.5)

                // 灰掉的原因要写出来 —— 开关在上一张卡片里，这一页看不到它。
                Text("Follows the Enable switch above.")
                    .font(.caption2)
                    .foregroundStyle(Color.mwMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // 这里原本是 `batteryPanel`（健康度 + 循环次数 + 容量 + 电压电流 + 序列号）。
    //
    // ── 2026-10-15：整张卡片搬去了功率页的电池卡片 ──────────────────────────
    //
    // 两张卡片说的是同一个东西的两面 —— 一张是「现在怎么样」（电量、电芯电压 /
    // 电流 / 温度），一张是「这块电池是什么」（健康度、循环次数、容量、序列号）。
    // 原来它们分在页面的两处，中间还隔着一次分段切换：想看「循环次数」要滚两次屏。
    // 合并后的实现见 `DashboardPanels.batteryPanel`。
    //
    // **重复的两行去掉了。** 这张卡片里的「Current」与「Voltage」就是那边的
    // 「Cell current」与「Cell voltage」，只是取数路径不同（一个走守护进程给的电池
    // 字典 `BatteryInfo`，一个走 `PowerSnapshot`）。按要求保留功率页那一份 ——
    // 同一张卡片上出现两个同名读数，是最容易让人怀疑「哪个才是对的」的写法。
    //
    // 一并留在那边的还有「Boot voltage」：它不是电芯电压，而是开机那一刻记下的
    // 电池电压，回答的是「这块电池这一轮开机时是什么状态」，与实时读数不是同一个量。

    /// 原版的下拉项。1 秒是给「看着它动」用的，30 秒是给「装兜里省电」用的。
    private static let frequencies = [1, 2, 3, 5, 10, 30]
}

/// 守护进程没起来时的提示条。
///
/// 它原来画在 `ChargeControlView` 里、位于分段控件与分段内容之间，两个分段都能看到。
/// 2026-10-11 之后只剩一个调用点（就是这一页），2026-10-15 电源页收成单页后仍然是
/// 一个 —— 但**类型保留**：它答的是「为什么下面全部不生效」，和
/// `ChargeControlPanels` 那堆面板是两件事。
///
/// 两种情况要分开说：
///   · **没打进包**（`daemonBundled == false`）：这一版构建就没带它，用户自己修不了；
///   · **打进包但没跑起来**：可能是权限、可能是被杀，值得让用户知道「下面全部不生效」。
struct ChargeServiceNote: View {
    @EnvironmentObject private var charge: ChargeControlService

    var body: some View {
        if !charge.daemonBundled {
            EmptyNote(text: "The charge control service is not in this build. Run scripts/build-ipa.sh to fetch and bundle it.",
                      systemImage: "exclamationmark.triangle")
        } else if !charge.daemonRunning {
            EmptyNote(text: "The charge control service is not running. Nothing on this page will take effect until it starts.",
                      systemImage: "exclamationmark.triangle")
        }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  行控件
// ══════════════════════════════════════════════════════════════════════════════

/// 标签 + 开关。
private struct ToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(AppFont.text(14, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .tint(.mwAccent)
    }
}

/// 标签 + 当前值 + 一个弹出菜单。
///
/// 当前值收 `Text` 而不是 `LocalizedStringKey`：这一列里既有译文（「插电即充」），
/// 也有量（「5 s」），把「要不要查表」的选择留在调用点 —— 跟 `Panel.trailing` 一个路子。
private struct MenuRow<Options: View>: View {
    let title: LocalizedStringKey
    let value: Text
    /// 行内说明，可选。给「模式」用 —— 那句话原本独占一行挂在下面，
    /// 2026-10-11 按要求挪进标题与右侧取值之间。
    ///
    /// 已经是译文（`ChargeMode.detail` 返回 `String`），所以渲染走 `Text(verbatim:)`，
    /// 不会二次查表。
    var detail: String?
    var tint: Color = .mwAccent
    @ViewBuilder var options: () -> Options

    init(_ title: LocalizedStringKey,
         value: Text,
         detail: String? = nil,
         tint: Color = .mwAccent,
         @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.value = value
        self.detail = detail
        self.tint = tint
        self.options = options
    }

    var body: some View {
        Menu {
            options()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(AppFont.text(14, weight: .medium))
                    .foregroundStyle(Color.primary)
                if let detail {
                    // `layoutPriority(-1)`：空间不够时**先压这一句**，别去挤标题和取值 ——
                    // 那两个才是这一行真正要传达的东西。再配合 `minimumScaleFactor`，
                    // 长一点的说明会缩到能放下为止，而不是把右边的取值顶出去。
                    Text(verbatim: detail)
                        .font(AppFont.text(11))
                        .foregroundStyle(Color.mwMuted)
                        .lineLimit(1)
                        // 0.6 而不是 0.7：这句话在英文下有小 80 个字符，而这一行还要
                        // 容下标题与右侧取值。压到 0.6 是「勉强能读」与「被截断」的
                        // 折中 —— 再小就不如直接截断（截断至少不骗人）。
                        .minimumScaleFactor(0.6)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                value
                    .font(AppFont.text(14, weight: .semibold))
                    .foregroundStyle(tint)
                Image(systemName: "chevron.up.chevron.down")
                    .font(AppFont.text(10, weight: .bold))
                    .foregroundStyle(Color.mwMuted)
            }
            .contentShape(Rectangle())
        }
    }
}

/// 标签 + 只读值。
///
/// ── 2026-10-15：从 `private` 放开 ──────────────────────────────────────────
///
/// 电池那两张卡片合并之后，这个行样式被 `DashboardPanels`（功率页）也拿去用了 ——
/// 合并后的电池卡片里，上半截是功率页原有的实时读数，下半截是这里原来的静态参数。
/// 复制一份的话两处会慢慢长歪（字号、对齐、占位符的灰），而它们本来就是同一个东西。
///
/// ── 2026-10-15 第四次改：对齐频段页 `infoRow` ────────────────────────────────
///
/// 用户说「健康度数值太小、不太正常，调整为跟频段页当前网络的数值相同大小」并附了
/// 两页截图。改了三次（14 → 16 → 15）都不满意，看截图才明白症结不在这一个数字的
/// **绝对大小**，而在**值与标签几乎同号**：这里是「标签 14 medium / 值 15 semibold」，
/// 差 1 pt，读起来像标签的附属；频段页是「标签 13 regular 淡 / 值 13 semibold」，
/// 同号但粗细对比分明，值一眼就跳出来。
///
/// 现在两处一起照频段页来：标签 13 淡、值 13 粗。
///
/// ── 2026-10-15 第五次改：标签留 13、**值单独提到 16** ─────────────────────
///
/// 上一轮「两处同号」按点数对齐了，但真机上看起来仍是「大标签 + 小数值」——
/// 原因是汉字与拉丁数字在同一个点数下的**视觉重量不同**（汉字的实际墨迹大一圈）。
/// 用户的反馈很明确：「文案跟频段页一样大了，但数值还是很小，在这个基础上调大点」。
/// 所以这一轮只动值：13 → 16，比标签大 3 pt，扣掉那圈视觉差之后两者大致相当。
/// 标签不动 —— 它正是用户认可的那个尺寸。频段页 `infoRow` 未动。
///
/// ── 2026-10-16 第六次改：16 → **15.5，并去掉自动缩放** ───────────────────
///
/// 真机反馈：16 太大、15 太小，「这不正常」。两点一起改：
///
/// a. 字号是 `CGFloat`，**分数字号合法且可渲染**，15.5 就是 16 与 15 的正中。
///    以前只在整数上调，等于白白少了一半可选档位。
/// b. `.minimumScaleFactor(0.7)` 让「设的字号」不等于「看到的字号」：它把超宽
///    的值压到 70%，压出来是任意小数，且同一列各行触发与否不同 —— 这正是
///    「1 pt 的调整却出现跳档观感」的来源。去掉之后与频段页 `infoRow` 一致
///    （那里从来没加过它）。放不下时 `lineLimit(1)` 会截断，看得见；
///    缩放是看不见的，不该用在读数上。
///
/// ── 2026-10-16 第七次改：15.5 → **15，并删掉 `monospaced` 参数** ───────────
///
/// a. 用户定了 15。15.5 是上一轮「16 与 15 之间没有落点」时的折中，现在既然
///    缩放已经去掉、字号所见即所得，直接回到整数档更好维护。
/// b. `monospaced` 参数**删掉了**。它原本只被 `Serial` 一行使用，让那一行走
///    `.monospaced` design（SF Mono），而上面五行是 `.default` —— 同一列混两套
///    字形，用户看到的就是「有一行跟别的不像」。用户要求整列统一，于是参数一并
///    删除：留着不用会变成新的死参数（这个参数历史上就有过「声明了但 body 没用」
///    的前科）。
///
///    代价记在这里：序列号混字母与数字，比例字形下字符宽度不齐。但**同一列视觉
///    统一**的优先级更高 —— 序列号是给人看一眼抄下来的，不是用来逐列对齐的。
struct ValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var tint: Color = .primary

    var body: some View {
        // 间距与 `BandPanels.infoRow`（频段页「当前网络」）一致的 12。
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                // ── 2026-10-15：对齐频段页 `infoRow` 的样式 ─────────────────────
                //
                // 用户说「电源页健康度数值字体太小、不太正常，调整为跟频段页
                // 当前网络的数值相同大小」，并附了两页的截图。
                //
                // 看截图才知道差别在哪：频段页「当前网络」是**11 行同一种
                // 「标签 + 值」**，值一律 13 pt semibold；而这里标签是 14 pt
                // medium、值 15 pt semibold —— **值与标签只差 1 pt**，
                // 读起来像「标签的附属」而不是一个读数。用户说的「太小、不正常」
                // 说的正是这个，不是绝对值小。
                //
                // 所以两处一起改：标签降到 13 pt 并压淡，值也降到 13 pt 但保持
                // semibold。**字号虽然小了，值与标签的对比反而更强**（细而淡
                // 对粗而浓），整行的样式也就和频段页完全一致了。
                //
                // `ValueRow` 是电源页与充电控制页共用的一个行样式，改这里两处
                // 一起生效 —— 它们本来就是同一个东西（见本类型头上的说明）。
                .font(AppFont.text(13))
                .foregroundStyle(Color.mwMuted)
            Spacer(minLength: 8)
            Text(value)
                // ── 2026-10-15 再改：13 → 16 ────────────────────────────────────
                //
                // 用户看真机截图后的反馈：「健康度文案跟频段页的当前网络文案是一样
                // 大了，但数值还是很小，在这个基础上调大点」。
                //
                // 上一轮把标签与值一起降到 13 是**按点数对齐**的，漏掉了一件事：
                // 标签是汉字，值是拉丁数字与 `%` / `mAh` —— 同样 13 pt，汉字的
                // 字面（em box 里的实际墨迹）明显比数字大一圈。于是对齐之后
                // 视觉上的关系反而成了「大标签 + 小数值」，正是用户说的那个
                // 「数值还是很小」。
                //
                // 所以标签留在 13（它就是用户认可的那个大小），**值单独提到 16**：
                // 比标签大 3 pt，扣掉汉字那圈多出来的视觉重量之后，两者大致相等，
                // 而值与标签的粗细对比（semibold vs regular）本来就在。
                //
                // 这里**不用 `mwReadout`**：那个会加 `.monospacedDigit()`。
                // 频段页的值没有它，而加上了会让数字字形在 SF Proportional
                // 与 Tabular 之间换一版宽度。
                //
                // ── 2026-10-16：16 → 15.5 → **15**，并**去掉 `minimumScaleFactor`** ─
                //
                // 用户实测：16 太大、15 太小，中间没有落点 —— 而且这个「跳档」的
                // 观感不正常。两个原因，一起在这里解决：
                //
                // a. **整数档位没有中间值**。字号是 `CGFloat`，SwiftUI 也接受
                //    分数字号 —— 先用 15.5 试过，用户最后定了 15。
                //
                // b. **`minimumScaleFactor(0.7)` 让「设多少」不等于「看到多少」**。
                //    它在本行文本超出可用宽度时把字号压到 70%（15 pt 下是 10.5 pt），
                //    压出来的值是个任意小数、而且**同一列各行触发与否不同** ——
                //    于是每行的实际字号互不相同，看起来就像无故跳档。
                //
                //    去掉之后字号完全确定：设 15 就是 15，与频段页 `infoRow`
                //    一致（它从一开始就没有这个修饰）。放不下时由 `lineLimit(1)`
                //    截断，而不是悄悄变小 —— 截断是看得见的，缩放是看不见的。
                //
                //    风险核对过：这一列最长的值是序列号（16 字符左右，15 pt
                //    比例字形约 140 pt）加标签与间距约 200 pt，常见机型卡片内
                //    可用宽度在 320 pt 以上，够。
                //
                // 字号与其余五行的**字形也必须一致**：以前 `Serial` 走 `.monospaced`
                // （SF Mono），现在整列都是 `AppFont.text`，见类型头上的说明。
                .font(AppFont.text(15, weight: .semibold))
                .foregroundStyle(value == "—" ? Color.mwMuted.opacity(0.55) : tint)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 标签 + 数值 + 滑块。
///
/// 拖动期间只改本地 `draft`，松手才提交。不这样做的话，守护进程每 5 秒回一次配置，
/// 会把正在拖的滑块从手指底下拽回去。
private struct ThresholdSlider: View {
    let title: LocalizedStringKey
    let value: Int
    let range: ClosedRange<Double>
    let unit: String
    let tint: Color
    let onChange: (Int) -> Void

    @State private var draft: Double
    @State private var dragging = false

    init(title: LocalizedStringKey,
         value: Int,
         range: ClosedRange<Double>,
         unit: String,
         tint: Color,
         onChange: @escaping (Int) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.unit = unit
        self.tint = tint
        self.onChange = onChange
        self._draft = State(initialValue: Double(value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppFont.text(13, weight: .medium))
                Spacer(minLength: 8)
                Text("\(Int(draft))\(unit)")
                    .mwReadout(size: 16, weight: .semibold)
                    .foregroundStyle(tint)
            }
            // 显式写 `onEditingChanged:` 而不是用尾随闭包：`Slider` 有好几个重载，
            // 尾随闭包要靠编译器去挑「最后一个参数是闭包」的那一个，读起来也不明确。
            Slider(value: $draft, in: range, step: 1, onEditingChanged: { started in
                dragging = started
                if !started { onChange(Int(draft)) }
            })
            .tint(tint)
        }
        // 外部改了值（重置、或守护进程那边被别处改了）就跟着走。
        .onChange(of: value) { newValue in
            guard !dragging else { return }
            draft = Double(newValue)
        }
    }
}
