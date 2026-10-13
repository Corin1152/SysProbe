import UIKit

/// 负一屏的内容视图。纯 UIKit，不用 SwiftUI。
///
/// ## 为什么不用主 App 那套 SwiftUI 组件
///
/// 这一屏原本是 `UIHostingController` 装一个 SwiftUI 视图，装机后负一屏一直显示
/// 「无法载入」。原因有两条，第二条才是真根因：
///
/// 1. appex 里带 SwiftUI 会让 dyld 把 `SwiftUI.framework` 映射进来（几十 MB），
///    而扩展的预算远小于主 App。这一条值得避免，但**不是**「无法载入」的充分原因。
/// 2. **appex 从来没链 `NotificationCenter.framework`。** 系统建立扩展的 XPC 连接时，
///    会按 `NSExtensionPointIdentifier` 找出该用哪个 `NSExtensionContext` 子类 ——
///    对 `com.apple.widget-extension` 就是 `NCWidgetExtensionContext`，它实现在那个库
///    里。库不在 → 类找不到 → 当场 `EXC_BREAKPOINT`。**这个时机早于系统实例化本视图
///    控制器**，所以应用代码一行都不会执行。修法见 `project.yml` 的 `OTHER_LDFLAGS`。
///
/// ## 排版
///
/// **左环 + 右列**（排列方式参照 CPU-X 的负一屏组件）：左列是 CPU/RAM 双圆环；
/// 右列自上而下四行 —— 电芯温度 / 充电器输入 / 输入电芯 / 存储，每行「标签靠左、
/// 读数靠右」，存储那行多一条进度条。
///
///        ╭─────╮        电芯温度           31.6 °C
///       ╱  98%  ╲       充电器输入          0.59 W
///      │  1.2GB  │      输入电芯            0.00 W
///       ╲  RAM  ╱       存储        11.64 GB (19%)
///        CPU 12%        ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░
///
/// 后两条是 0.0.47 的文案调整（用户要求）：「充电器 / 电芯」→「充电器输入 / 输入电芯」
/// ——它们一个是**从充电器进来**的功率、一个是**真正进到电芯**的功率，光写名词看不出
/// 这层区别；存储那行把「剩余」两字换成了百分比，容量与比例一次看全。
///
/// ## 尺寸
///
/// **环格是自适应的**：它的上下边直接钉在本视图上（各留 `ringTopInset` / `ringBottomInset`
/// = 2pt），所以 `环格高 = 组件高 − 4`。而**右列单独算** —— 它下面要留
/// `contentBottomInset`（8pt）给存储进度条，上边比环列低。
///
/// 组件高度由 `preferredContentSize` 报给系统，并且**夹在系统给的上限之内**
/// （`TodayViewController.systemMaximumHeight`，来自 `widgetActiveDisplayModeDidChange`）。
///
/// 换句话说：**环外沿 = 系统允许的组件最大高度 − 4 − 9.5**。
/// 想让环更大，只能动那两个 2pt（已到下限）；把环格写成固定值是行不通的 ——
/// 高度不够时那条约束会被 Auto Layout 打破，环缩多少完全随机（0.0.46~0.0.47 就是这样）。
///
/// ⚠ **两列的下界不同**（环列 2pt、右列 8pt），所以它们不再严格居中对齐 ——
/// 环的中心比右列高约 3pt。这是「把环做大 6pt」的代价，用户 0.0.48 明确要了这个取舍。
///
/// ## 颜色（用户要求，2026-10-13）
///
/// **文案纯黑、数值保留各自的配色**，两者不混用：
///
/// | 元素 | 颜色 | 依据 |
/// |---|---|---|
/// | 标签 / 单位 / 环内切口标签 / 存储标题 | `TodayStyle.text`（浅色纯黑） | 与参考图 CPU-X 一致 |
/// | 电芯温度读数 | `TodayStyle.temperature(°C)` | **主程序电源分页那套暖色阶梯** |
/// | 充电器 / 电芯读数 | `TodayStyle.battery` | 0.0.39 版的功率配色 |
/// | 环内中心读数（内存占用率） | `TodayStyle.loadTint` | 0.0.39 版 `Memory` 那一格 |
///
/// 一句话：**纯黑只改文案**。读数若也刷成纯黑，这一屏就只剩一堆黑字，
/// 看不出哪个数是「量」、哪个是说明它的标签。
///
/// ## 演进（2026-10-13 一天内五版，每一条都是实机反馈逼出来的）
///
/// · **0.0.40**：第 1 格换成 CPU/RAM 双圆环，第 2 格换成电芯温度。
/// · **0.0.41** 实机：圆环**完全不可见**。纯自绘视图既没有 `intrinsicContentSize`、
///   内部也没有约束，而横向 stack 在 `alignment != .fill` 时不给 arrangedSubview
///   加高度约束 → 高度解析为 0 → `CAShapeLayer` 的 bounds 高 0 时**整个 path 都不渲染**。
///   → 补尺寸约束。
/// · **0.0.42** 实机：环太小（格宽仅 76pt）、两端位置不对（`UIBezierPath` 的
///   `clockwise` 在翻转坐标系里方向是反的）、存储条被底边裁（`preferredContentSize`
///   少算了系统头部）。→ 反等宽 + 自采样弧 + 头部补偿。
/// · **0.0.43** 实机：环只画到约 39pt —— 环格那条宽度约束优先级 750，被右列 stack 的
///   compression resistance 顶掉。→ 两条宽度一起写成 required。
/// · **0.0.44 / 0.0.45**：环与文案放大 50%、字体对齐主程序的功率圆环、内容上下各留 8pt；
///   最后按用户给的 CPU-X 参考图改成**左环 + 右列的排列**（比横排方案矮约 40pt）。
/// · **0.0.46** 实机（三处反馈）：
///   ① `CPU 12%` 那个标签**压在弧上** —— 缺口在该半径处只能给出约 43pt 宽，而 9pt 的
///      「CPU 12%」要 44pt，超了；→ 标签降到 **7pt**（约 34pt）；
///   ② 右列**行距一大一小**、第 3/4 行挤在一起 —— `side` 的 `.equalSpacing` 因为两个
///      子视图自身高度未定而失效；→ 改成上下贴紧、高度确定；
///   ③ 存储进度条**贴着组件底边** —— 留白 8pt 不够（存储条自己还被列高差顶掉约 7pt）。
/// · **0.0.47** 实机：切口标签仍压弧（环比设计小，缺口能给的宽度也跟着小）、
///   右列文案调整；用户还指出内容**整体偏下**。
/// · **0.0.48**（本版）—— 把「环每版大小都不一样」这件事从根上解决：
///   `ringView.height` 由**固定 120pt** 改成**吃满行高**（`= row.height`），
///   固定的「期望值」降级成 750 优先级、只用于算组件想要多高。
///   原因：组件高度受系统上限压着，高度不够时那条 required 的固定高度与
///   「内容不得超出组件」冲突，**Auto Layout 打破哪一条是不确定的** ——
///   0.0.46 环外沿约 86pt、0.0.47 约 72pt，设计的 105.5pt 从没出现过，
///   而且没有任何报错。同批还有：字号随环的尺寸等比缩放、上下留白改成
///   不对称的 2 / 8（比居中少一层换算，也顺手把内容顶回中间）。
///
/// 频率**不再显示**：iOS 不允许 appex 访问 IOReport（实测 `IOReportCopyAllChannels`
/// 在扩展里返回空通道集），而主 App 被挂起时也供不了数 —— 与其显示一个常年「—」，
/// 不如去掉这一项。
final class TodayWidgetView: UIView {

    /// 四组，顺序：双圆环（CPU + RAM）/ 电芯温度 / 充电器 / 电芯。
    private let ringView = TodayRingView()
    private let temperatureCell = TodayCellView()
    private let chargerCell = TodayCellView()
    private let cellCell = TodayCellView()
    private let storage = TodayStorageView()

    /// 左右留白。
    ///
    /// 这个数值不是随手定的：负一屏的组件标题（图标 + App 名 + 箭头）由**系统**绘制，
    /// 它有自己的边距（实测约 19pt）。内容区原来贴边，于是最左边的 `CPU` 比上方图标
    /// 往外探出约 13pt，看着不齐。加上这个偏移后，`CPU` 的左边缘正好落在图标的左边缘上；
    /// 右边也顺带留出空间，「已用 … · 剩余 …」不会再顶到组件右边缘。
    private static let horizontalInset: CGFloat = 14

    /// 圆环那一列占整行宽度的比例。
    ///
    /// **排列方式参照 CPU-X 的负一屏组件**：圆环独占左列，右侧一列放四行读数。
    /// 0.40（iPhone X 上约 132pt）—— 环真正卡住的是**高度**（见 `ringPreferredHeight`），
    /// 所以这一列再宽也不会让环更大，反而会挤掉右列。
    ///
    /// 提醒：这一列的宽度约束**必须与右列一起写成 required**（见 `build()`）。
    /// 0.0.43 曾只给它一条 750 优先级的约束，被右列的 compression resistance 顶掉，
    /// 实机上环只画到约 39pt（设计值 71pt）。
    private static let ringWidthRatio: CGFloat = 0.40

    /// 环格**期望**的高度 —— 只用来算「组件需要多高」，不是硬约束。
    ///
    /// ## 为什么不能写成硬约束（0.0.44 ~ 0.0.47 连环踩的坑）
    ///
    /// 组件总高 = 环格 + 系统头部 + 上下留白，而**系统对 `preferredContentSize.height`
    /// 有上限**（实测约 130pt）。一旦我们报的总高超过它：
    ///
    ///   1. 系统把高度压下来 → 本视图变矮 → 留给环格的高度不够；
    ///   2. 那条 `ringView.height = 120` 的 required 约束与「内容不得超出组件」的约束
    ///      冲突，**Auto Layout 只好打破一条 —— 打破哪一条是不确定的**；
    ///   3. 结果就是**每一版环的大小都不一样**，而且没有任何报错（0.0.47 实机环外沿
    ///      只有约 72pt，0.0.46 那张约 86pt，设计的 105.5pt 从未真正出现过）。
    ///
    /// 现在改成：环格的上下边**直接钉在本视图上**（见 `build()`），
    /// **本常量降级成 750 优先级的「期望值」** —— 只在 `systemLayoutSizeFitting`
    /// 算「组件想多高」时起作用；真机上可用高度不够时它自动让位，不会再有冲突。
    private static let ringPreferredHeight: CGFloat = 120

    /// 环**外沿直径**比环格高度小多少。
    ///
    /// 推导：`available = min(列宽, 环格高)`，
    /// `outerRadius = (available − 线宽和 − 环间距) / 2`（线宽和 = 5.5 + 4.5 = 10），
    /// 外沿直径 = `2 × outerRadius + 外线宽` = `available − 环间距 − 4.5`。
    ///
    /// 环间距从 10 收到 5 之后，这个差值从 14.5 变成 **9.5**。右列四行的总高对齐的是
    /// **环外沿**（用户要求），所以 = 环格高 − 9.5。⚠ 改 `TodayRingView.ringGap` 时
    /// 必须一起改这里，否则右列会与环顶/环底错位。
    private static let ringEdgeInset: CGFloat = 9.5

    /// **系统在组件顶部画的那一行**（App 图标 + 名称 + 展开箭头）的高度估算。
    ///
    /// 这里是**唯一真值来源** —— `TodayViewController` 用它算组件总高
    /// （`preferredContentSize` 是**含这一行**的总高）。取值依据见那边的反推
    /// （两次实机互相印证，约 21~26pt）。
    static let systemHeaderHeight: CGFloat = 24

    /// 环那一列的上下留白 —— **与右列分开算**。
    ///
    /// 用户 0.0.48 追问「不考虑跟右侧等高，环是否还能加大」—— 答案是能，这里就是那份空间。
    /// 环的大小 = 组件高 − 这个留白 − `ringEdgeInset`，而组件高是系统给的、动不了。
    /// 右列的下留白（8pt）是**为存储进度条**留的，可存储条在**右列**，环那一列的下方
    /// 本来就是空的 —— 以前两列挤在同一个水平 stack 里、共用一套留白，那 6pt 白丢了。
    ///
    /// 取 2pt 而不是 0：环外沿距环格边界还有 `ringEdgeInset / 2 = 4.75pt` 的空隙，
    /// 加上这 2pt 是 6.75pt，视觉上不贴边。
    private static let ringTopInset: CGFloat = 2
    private static let ringBottomInset: CGFloat = 2

    /// 右列的下留白 —— 存储进度条不能贴组件底边（用户 0.0.46 要求）。
    ///
    /// **它只约束右列**（`side` 的底边），不参与组件总高的计算（总高由环那一列决定）。
    static let contentBottomInset: CGFloat = 8

    /// 两列之间的水平间距。
    private static let columnSpacing: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        // **排列方式参照 CPU-X 的负一屏组件**：圆环独占左列，右侧一列自上而下放四行
        // —— 电芯温度 / 充电器 / 电芯 / 存储，每行都是「标签靠左、读数靠右」。
        //
        // 这比早先「四格横排 + 存储占一整条」省高度：右侧四行加起来约 90pt，而环格
        // 高 120pt，组件总高于是由环决定（比横排方案矮近 40pt）。
        let side = UIStackView(arrangedSubviews: [temperatureCell, chargerCell, cellCell, storage])
        side.axis = .vertical
        // **`.equalSpacing`：把剩下的空间全部平均分到三个行距上。**
        //
        // ⚠ **它只在「四行各自高度确定」时才真的均分。** 0.0.46 实机上行距一大一小
        // （第 3、4 行挤在一起），根因就在两个子视图自身的高度没有约束（用的是
        // `centerY` + 两条不等式）—— Auto Layout 于是可以把余量塞进「高度未定」的
        // 行里，而不必平分给间距。修法见 `TodayCellView` / `TodayStorageView` 里那两条
        // 改成「上下贴紧」的约束。
        side.distribution = .equalSpacing
        side.translatesAutoresizingMaskIntoConstraints = false

        // **圆环必须自己有确定的尺寸** —— 这是 0.0.40 实机「一个环都看不到」的根因。
        // `TodayRingView` 是纯自绘视图：既没有 `intrinsicContentSize`、内部也没有一条
        // 约束，宽高必须由外面给死，否则解析为 0（`CAShapeLayer` 的 bounds 高 0 时
        // 整个 path 都不渲染）。
        ringView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(ringView)
        addSubview(side)

        // 内容区的左右边界（两列共用），用 layout guide 表达。
        let content = UILayoutGuide()
        addLayoutGuide(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor,
                                             constant: Self.horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -Self.horizontalInset),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            // ── 左列：环 ──
            // **上下各只留 2pt，不与右列共用留白。**
            //
            // 以前两列挤在同一个水平 stack 里，于是共用一套留白（上 2 / 下 8）——
            // 可那 8pt 是**为存储进度条**留的，而存储条在**右列**，环那一列的下方
            // 本来就是空的。把环列解放出来，环外沿能多 6pt（约 +8%）。
            // 这正是用户 0.0.48 问的「不考虑跟右侧等高，环是否还能加大」。
            ringView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ringView.topAnchor.constraint(equalTo: content.topAnchor,
                                          constant: Self.ringTopInset),
            ringView.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                             constant: -Self.ringBottomInset),
            // 宽度按内容区的比例给 —— 但环真正卡的是**高度**（见 `ringPreferredHeight`），
            // 这一列再宽也不会让环更大，反而挤掉右列。
            ringView.widthAnchor.constraint(equalTo: content.widthAnchor,
                                            multiplier: Self.ringWidthRatio),

            // ── 右列：四行读数 ──
            side.leadingAnchor.constraint(equalTo: ringView.trailingAnchor,
                                          constant: Self.columnSpacing),
            side.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // 四行总高 = **环外沿直径** = 环格高 − `ringEdgeInset`（用户要求）。
            side.heightAnchor.constraint(equalTo: ringView.heightAnchor,
                                         constant: -Self.ringEdgeInset),
            // **底部单独留 8pt**：存储进度条不能贴组件底边（用户 0.0.46 的要求）。
            // 环列不需要这一段，所以两列的下界不同 —— 代价是两列不再严格居中对齐
            // （环的中心比右列高约 3pt），这是「环更大」换来的一点不齐。
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                         constant: -Self.contentBottomInset),
        ])

        // 环格高度的**期望值**：只在 `systemLayoutSizeFitting` 算「组件想多高」时起作用
        // （环是纯自绘、没有固有高度，否则那里算出来是 0）。优先级取 750 —— 真机上
        // 可用高度不够时它自动让位，不会把布局撑破。见 `ringPreferredHeight` 的注释。
        let preferredRingHeight = ringView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.ringPreferredHeight)
        preferredRingHeight.priority = .defaultHigh
        preferredRingHeight.isActive = true
    }

    // MARK: 每秒刷新

    /// 数据来自三个来源：硬件（CPU / 内存 / 存储）、电源（充电功率）、电池（温度）。
    ///
    /// 未插电时 `inputWatts` / `batteryWatts` 会是 nil，这里按 **0 W** 显示而不是「—」：
    /// 四组读数里突然出现一个破折号，看上去像「这一项坏了」；而 0 W 本身是准确的读数
    /// （确实没有功率进来）。
    ///
    /// 数字与单位**分开**传：单位要小一号、颜色也更淡。所以这里用 `Formatting.number`
    /// 而不是 `Formatting.percent` —— 后者会把 `%` 一起吐出来，再叠一个单位就印出两个。
    func apply(hardware: HardwareSnapshot, power: PowerSnapshot, battery: BatteryInfo?) {
        // 左列：CPU + RAM 双圆环。
        //
        // 内存那两个数走 CPU-X 的口径：百分比和剩余容量都是「只有完全空闲的页才算数」
        // （`strictUsage` + `free`）。不这么统一的话，93% 配一个 199 MB 会读不通 ——
        // 3 GB 的机器剩 199 MB 对应 93%、剩 87 MB 对应 97%，两个数必须出自同一套算法。
        //
        // 中心第二行**只放容量数字**，不带「剩余 / Free」前缀 —— 用户反馈那两个字在
        // 内环里太占地方（为了塞下它，整行曾被 `adjustsFontSizeToFitWidth` 压到 0.8 倍
        // 以下）。`Formatting.memory` 出的是「1.2GB」这种紧凑写法，正是为这种窄处写的。
        ringView.apply(cpuFraction: hardware.cpu.usage,
                       ramFraction: hardware.memory.strictUsage,
                       ramDetail: Formatting.memory(hardware.memory.free),
                       cpuPercentText: "\(Formatting.number(hardware.cpu.usage * 100))%")

        // 右列第 1 行：电芯温度。
        //
        // 读数来自守护进程（`BatteryInfo.temperature`，也就是电源页「电池」面板里
        // 那个 Temperature）—— 负一屏自己读不到：iOS 不允许 appex 访问 IOReport，
        // 而电池温度那一路要的正是它。
        //
        // **配色走 `TodayStyle.temperature` 的暖色阶梯 —— 这是主程序电源分页里电芯
        // 温度用的同一套**（29~33 °C 落在 `cool` 档，显示为绿 0x0E9B57）。用户明确
        // 要求这一格的数值配色保留主程序的方案；推送脚本里有断言钉住这五级色阶。
        let temperature = battery?.temperature
        temperatureCell.apply(caption: Strings.text("Cell temperature"),
                              value: temperature.map { String(format: "%.1f", $0) } ?? "—",
                              unit: temperature == nil ? nil : "°C",
                              tint: temperature.map { TodayStyle.temperature($0) } ?? TodayStyle.muted)

        // 文案是「充电器输入 / 输入电芯」（用户 0.0.47 要求）—— 这两个量一个是从充电器
        // **进来**的、一个是真正**进到电芯**的，光写「充电器 / 电芯」看不出这层区别。
        // 用**新 key**（`Charger input` / `Cell input`）而不是改 `Charger` / `Cell` 的
        // 翻译：那两个 key 是共享的，改了会连带改到别处。
        chargerCell.apply(caption: Strings.text("Charger input"),
                          value: Formatting.watts(power.inputWatts ?? 0),
                          unit: "W",
                          // 与电芯那组同色：两格都是功率读数，一个青一个绿会让人以为
                          // 它们在表达不同的东西。
                          tint: TodayStyle.battery)

        cellCell.apply(caption: Strings.text("Cell input"),
                       value: Formatting.watts(abs(power.batteryWatts ?? 0)),
                       unit: "W",
                       tint: TodayStyle.battery)

        storage.apply(used: hardware.storage.used, free: hardware.storage.free)
    }
}

// MARK: - 一组读数

/// 右侧清单里的一行：**标签靠左、读数靠右**（+ 单位）。
///
/// **2026-10-13 去掉了原来的第三层「副标签」**（它当时只为「输入功率」四个字存在）；
/// 0.0.45 又从「标签在上、读数在下」的竖排改成 CPU-X 那种一行一条的横排 ——
/// 同样的信息，横排只占一行的高度。
///
/// 字号固定为 caption 12 medium ／ 读数 12 semibold ／ 单位 11 medium，
/// 读数用等宽数字 —— 每秒刷新时宽度不会跳动。
///
/// 颜色：**标签与单位纯黑（`TodayStyle.text`），读数走传进来的 `tint`**。
/// 用户的原话是「纯黑只改文案颜色」—— 读数保留语义色，这一行才有主次。
final class TodayCellView: UIView {

    private let captionLabel = UILabel()
    private let valueLabel = UILabel()
    private let unitLabel = UILabel()

    // 字号与字重**对齐主 App 的功率圆环**（`Sources/Shared/Design/PowerRing.swift`
    // 的 `centre`）：读数 semibold + 等宽数字（主程序 `mwReadout` 也是这个组合），
    // 其余文字一律 **medium** —— 主程序那边 caption 是 `AppFont.text(12, .medium)`，
    // **不是** semibold；负一屏原来用 semibold，摆在一起 caption 的份量比读数还重。
    //
    // **字号按用户要求恢复到 0.0.39 那一版：12 / 12 / 11。** 0.0.43 曾把单位压到 9pt
    // 去凑「大读数 + 小单位」的层级，但真机上三格整体显得偏小 —— 层级靠**字重**区分
    // 就够了，不必再压字号。
    private static let captionFont = TodayFont.text(12, weight: .medium)
    private static let valueFont = TodayFont.readout(12, weight: .semibold)
    private static let unitFont = TodayFont.text(11, weight: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)

        captionLabel.font = Self.captionFont
        // 标签与单位是**文案**，走纯黑（用户要求）；数值的颜色由 `apply` 的 `tint` 给。
        captionLabel.textColor = TodayStyle.text
        captionLabel.numberOfLines = 1

        valueLabel.font = Self.valueFont
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        valueLabel.numberOfLines = 1

        unitLabel.font = Self.unitFont
        unitLabel.textColor = TodayStyle.text

        let valueRow = UIStackView(arrangedSubviews: [valueLabel, unitLabel])
        valueRow.axis = .horizontal
        valueRow.spacing = 2
        valueRow.alignment = .firstBaseline

        // **标签靠左、读数靠右**（CPU-X 那种「一行一条」的排法）。中间那个空视图负责
        // 吸收余量 —— 它的 hugging 压到 1，多余宽度就全归它，两侧文字各自贴边。
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)

        let line = UIStackView(arrangedSubviews: [captionLabel, spacer, valueRow])
        line.axis = .horizontal
        line.spacing = 6
        // `.center` 而不是 `.firstBaseline`：spacer 没有基线，用基线对齐会退化。
        // 两边的字都是 12 / 11pt，居中对齐与基线对齐肉眼看不出差别。
        line.alignment = .center
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            // **高度 = 文字本身的高度**（上下都贴紧）。
            //
            // 0.0.46 实机上「右列行距不均、第 3/4 行挤在一起」，根因就在这里：原来写的是
            // `centerY` + 上下两条**不等式**，那么这一行的**自身高度是没有约束的**。
            // 于是 `side` 的 `.equalSpacing` 想均分间距时，Auto Layout 完全可以把多出来
            // 的空间塞进「高度未定」的行里，而不必平分到间距上 —— 结果就是每行被撑成
            // 不同高度、行距看着一大一小。
            // 写死上下贴紧之后，四行高度确定（读数行约 14pt、存储行约 25pt），
            // 剩余空间**只能**分给三个间距，必然均分。
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(caption: String, value: String, unit: String?, tint: UIColor) {
        // 微标签：拉丁下转大写加字距，中文下原样（汉字没有大小写，加了只会显散）。
        let shown = TodayFont.captionUppercases ? caption.uppercased() : caption
        captionLabel.attributedText = NSAttributedString(string: shown, attributes: [
            .font: Self.captionFont,
            .foregroundColor: TodayStyle.text,
            .kern: TodayFont.captionTracking,
        ])
        valueLabel.text = value
        // **读数走传进来的 `tint`，与 0.0.39 版一致**：电芯温度是暖色阶梯
        // （`TodayStyle.temperature`，主程序那套），功率是 `battery` 绿。
        // 用户明确要求「纯黑只改文案颜色」—— 读数一旦也刷成纯黑，这一屏就只剩
        // 一堆黑字，看不出哪个数是「量」、哪个是标签。
        valueLabel.textColor = value == "—" ? TodayStyle.muted.withAlphaComponent(0.55) : tint
        unitLabel.text = unit
        unitLabel.isHidden = unit == nil
    }
}

// MARK: - 存储条

/// 系统存储：一条进度条 + 「剩余 ⋯」（已用的信息在主 App 的存储页里更完整）。
final class TodayStorageView: UIView {

    private let captionLabel = UILabel()
    private let detailLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint!
    private var fraction: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)

        captionLabel.font = TodayFont.text(12, weight: .medium)
        // 标题是文案 → 纯黑。
        captionLabel.textColor = TodayStyle.text

        detailLabel.font = TodayFont.readout(12)
        // **纯黑**（用户 0.0.47 要求）—— 它与上面三个读数不同，不是「量」而是
        // 「还剩多少」的说明，跟着标签一起走纯黑；存储那个量本身由进度条的颜色表达。
        detailLabel.textColor = TodayStyle.text
        detailLabel.textAlignment = .right
        // 「剩余 11.54 GB」在右侧那一列（约 177pt）里仍可能差一点点，允许收一档 ——
        // 总好过把左边的「存储」挤掉。
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.75

        track.backgroundColor = TodayStyle.track
        track.layer.cornerRadius = 2.5
        fill.layer.cornerRadius = 2.5
        // 填充色不在这里定 —— 它取决于剩余容量，见 `apply` 与 `TodayStyle.storageTint`。

        let header = UIStackView(arrangedSubviews: [captionLabel, detailLabel])
        header.axis = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline
        // 把「已用 / 剩余」顶到右边。两个 label 的默认 hugging 都是 251，靠 `.fill`
        // 隐式决定谁被拉伸 —— 那是碰运气，说清楚才稳。
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)

        track.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 5),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])

        let stack = UIStackView(arrangedSubviews: [header, track])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            // 同 `TodayCellView`：**高度 = 内容高度**（上下贴紧）。
            // 原来用 `centerY` + 两条不等式，自身高度未定，会被那一列的 `.equalSpacing`
            // 把余量塞进来 —— 表现就是「存储」这一行与上一行贴在一起、而行内的文字与
            // 进度条之间被撑开。写死之后高度确定，行距交给 stack 均分。
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(used: UInt64, free: UInt64) {
        let total = used &+ free
        let usedFraction = total == 0 ? 0 : min(max(Double(used) / Double(total), 0), 1)
        fraction = usedFraction

        // 条子填的是「已用」，但**颜色看的是「剩余」** —— 该被注意的是还剩多少。
        fill.backgroundColor = TodayStyle.storageTint(freeFraction: 1 - usedFraction)

        let shown = TodayFont.captionUppercases
            ? Strings.text("Storage").uppercased()
            : Strings.text("Storage")
        captionLabel.attributedText = NSAttributedString(string: shown, attributes: [
            .font: TodayFont.text(12, weight: .medium),
            .foregroundColor: TodayStyle.text,
            .kern: TodayFont.captionTracking,
        ])
        // **剩余容量 + 剩余百分比**（用户 0.0.47 要求）。
        //
        // 原来的「剩余 11.64 GB」把两个字花在了「剩余」上 —— 而左边的标签就写着
        // 「存储」，那几个字本来就是废话。换成百分比之后，这一行给的是**真正要盯的数**
        // （快满时它变小、进度条同时转红），容量与比例一次看全。
        // 百分比取整：与进度条的粗细相比，小数位看不出差别，反而把这一行撑长。
        let freePercent = total == 0 ? 0 : Int((Double(free) / Double(total) * 100).rounded())
        detailLabel.text = "\(Formatting.bytes(free)) (\(freePercent)%)"
        setNeedsLayout()
    }

    /// 填充宽度只能在这里算：`apply` 是在布局之前调用的，那时 `track.bounds.width`
    /// 还是 0，当场读会得到一条永远填不满的进度条。
    override func layoutSubviews() {
        super.layoutSubviews()
        let target = track.bounds.width * CGFloat(fraction)
        // 值没变就别写回 —— 赋 `constant` 会 invalidate 布局，不设这道闸就是每帧一次的
        // 布局循环。
        if abs(fillWidth.constant - target) > 0.5 {
            fillWidth.constant = target
        }
    }
}
