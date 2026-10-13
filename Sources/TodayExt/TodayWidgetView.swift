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
/// 右列自上而下四行 —— 电芯温度 / 充电器 / 电芯 / 存储，每行「标签靠左、读数靠右」，
/// 存储那行多一条进度条。
///
///        ╭─────╮        电芯温度         32.1 °C
///       ╱  98%  ╲       充电器            1.63 W
///      │  1.2GB  │      电芯              0.00 W
///       ╲  RAM  ╱       存储    已用 47.96 · 剩余 11.54
///        CPU 26%        ▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░
///
/// 组件总高约 180pt（环 140 + 系统头部 24 + 上下留白 16）。
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
    /// 0.40（iPhone X 上约 125pt）配 `ringHeight = 140` → 可用直径 120pt →
    /// 外径约 106pt，正是「环放大 50%」的目标。
    ///
    /// 提醒：这一列的宽度约束**必须与右列一起写成 required**（见 `build()`）。
    /// 0.0.43 曾只给它一条 750 优先级的约束，被右列的 compression resistance 顶掉，
    /// 实机上环只画到约 39pt（设计值 71pt）。
    private static let ringWidthRatio: CGFloat = 0.40

    /// 圆环那一列的高度，也是整块内容的高度。
    ///
    /// 环的可用直径 = `min(列宽, 高度 − 20)`；要拿到 120pt 的可用直径，高度取 140pt。
    /// 右侧四行加起来约 90pt（`.fillEqually` 摊到 140pt），所以**组件总高由环决定**：
    /// 140 + 系统头部 24 + 上下留白 16 = **约 180pt**。
    private static let ringHeight: CGFloat = 140

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        // **排列方式参照 CPU-X 的负一屏组件**：圆环独占左列，右侧一列自上而下放四行
        // —— 电芯温度 / 充电器 / 电芯 / 存储，每行都是「标签靠左、读数靠右」。
        //
        // 这比早先「四格横排 + 存储占一整条」明显省高度：右侧四行加起来约 90pt，而环
        // 高 140pt，组件总高于是由环决定（约 180pt，比横排方案的 219pt 矮 39pt）。
        let side = UIStackView(arrangedSubviews: [temperatureCell, chargerCell, cellCell, storage])
        side.axis = .vertical
        side.spacing = 12
        // **不摊满、只用自己的自然高度**（`.fill` + `row.alignment = .center`）。
        // 早先用 `.fillEqually` 把四行拉到与环同高，行与行的距离被撑到 33pt 上下 ——
        // 用户要求「拉近点」，所以改成「内容高约 104pt、整体在环高内居中」。

        let row = UIStackView(arrangedSubviews: [ringView, side])
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fill
        // `.center` 而不是 `.fill`：右侧一列保持自然高度并垂直居中，行距才由
        // `side.spacing` 说了算（`.fill` 会把它拉到与环等高）。
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        // **圆环必须自己有确定的尺寸** —— 这是 0.0.40 实机「一个环都看不到」的根因。
        //
        // `TodayRingView` 是纯自绘视图：4 个 `CAShapeLayer` + 4 个 `UILabel` 全靠
        // frame 摆放，既没有 `intrinsicContentSize`、内部也没有一条约束。而横向
        // stack 在 `alignment != .fill` 时**不会**给 arrangedSubview 加高度约束 ——
        // 高度没有来源 → 解析为 0，于是：
        //   · `layoutSubviews` 里 `available = min(w, 0 - 20) = -20`，半径落到下限、
        //     圆心跑到视图上方，四个标签全叠在同一处；
        //   · 更彻底的是 `CAShapeLayer` 的 bounds 高 0 时整个 path 都不渲染 ——
        //     实机上就是「一个环都没有，只剩几个重叠的小字」。
        //
        // 同文件里 `TodayCellView` / `TodayStorageView` 都靠内部约束链把自己的高度
        // 撑起来，所以这个坑只有圆环会踩。
        ringView.translatesAutoresizingMaskIntoConstraints = false
        // **两条宽度都写成 required，明确把整行切开。** 这是 0.0.43 实机「环比设计小一半」
        // 的根因：当时只给圆环一条 750 优先级的比例约束，与后三格 stack 的
        // compression resistance（同为 750）撞在一起，真机上后者赢了 —— 环格被压到
        // 约 53pt，环于是只画到约 39pt（设计值 71pt）。让两者之和恒等于行宽，
        // 就没有这种争夺。
        NSLayoutConstraint.activate([
            ringView.widthAnchor.constraint(equalTo: row.widthAnchor,
                                            multiplier: Self.ringWidthRatio),
            side.widthAnchor.constraint(equalTo: row.widthAnchor,
                                        multiplier: 1 - Self.ringWidthRatio,
                                        constant: -row.spacing),
            ringView.heightAnchor.constraint(equalToConstant: Self.ringHeight),
        ])

        addSubview(row)

        // 整块内容**垂直居中**：组件的实际高度由 `preferredContentSize` 定
        // （内容自然高 + 系统头部 + 上下留白），多出来的部分平均分到上下两端。
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor,
                                         constant: Self.horizontalInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor,
                                          constant: -Self.horizontalInset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 内容万一长得超过组件高度，这两个不等式保证它不会溢出到边界外。
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
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
        // **配色走 `TodayStyle.temperature` 的暖色阶梯，与本次「次要文字改用 muted」
        // 无关** —— 用户明确要求这一格的数值颜色保持原样（29~33 °C 落在 `cool` 档，
        // 显示为绿 0x0E9B57）。推送脚本里有断言钉住这五级色阶，改 muted 不会波及它。
        let temperature = battery?.temperature
        temperatureCell.apply(caption: Strings.text("Cell temperature"),
                              value: temperature.map { String(format: "%.1f", $0) } ?? "—",
                              unit: temperature == nil ? nil : "°C",
                              tint: temperature.map { TodayStyle.temperature($0) } ?? TodayStyle.muted)

        chargerCell.apply(caption: Strings.text("Charger"),
                          value: Formatting.watts(power.inputWatts ?? 0),
                          unit: "W",
                          // 与电芯那组同色：两格都是功率读数，一个青一个绿会让人以为
                          // 它们在表达不同的东西。
                          tint: TodayStyle.battery)

        cellCell.apply(caption: Strings.text("Cell"),
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
        captionLabel.textColor = TodayStyle.muted
        captionLabel.numberOfLines = 1

        valueLabel.font = Self.valueFont
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        valueLabel.numberOfLines = 1

        unitLabel.font = Self.unitFont
        unitLabel.textColor = TodayStyle.muted

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
            // **垂直居中，不贴满**：右侧那一列用 `.fillEqually` 把每行拉到等高，
            // 贴满会把这一行撑开、文字跑到行中央偏上的位置。
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            line.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(caption: String, value: String, unit: String?, tint: UIColor) {
        // 微标签：拉丁下转大写加字距，中文下原样（汉字没有大小写，加了只会显散）。
        let shown = TodayFont.captionUppercases ? caption.uppercased() : caption
        captionLabel.attributedText = NSAttributedString(string: shown, attributes: [
            .font: Self.captionFont,
            .foregroundColor: TodayStyle.muted,
            .kern: TodayFont.captionTracking,
        ])
        valueLabel.text = value
        // 占位符画成弱化的灰 —— 它表示「没有读数」，不该看起来像一个值。
        valueLabel.textColor = value == "—" ? TodayStyle.muted.withAlphaComponent(0.55) : tint
        unitLabel.text = unit
        unitLabel.isHidden = unit == nil
    }
}

// MARK: - 存储条

/// 系统存储：一条进度条 + 「已用 / 剩余」。
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
        captionLabel.textColor = TodayStyle.muted

        detailLabel.font = TodayFont.readout(12)
        detailLabel.textColor = TodayStyle.muted
        detailLabel.textAlignment = .right
        // 「已用 47.96 GB · 剩余 11.54 GB」在右侧那一列（约 177pt）里会差一点点，
        // 允许收一档 —— 总好过把左边的「存储」挤掉。
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
            // **垂直居中，不贴满**：它现在被右侧那一列的 `.fillEqually` 拉着等高，
            // 贴满会把「存储」那行文字与进度条之间的距离撑开一大截。
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
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
            .foregroundColor: TodayStyle.muted,
            .kern: TodayFont.captionTracking,
        ])
        // **只报剩余**（用户要求）。已用的信息在主 App 的存储页里更完整，负一屏这一行
        // 给它只会把文案撑长 —— 上一版「已用 47.96 GB · 剩余 11.54 GB」在右侧那一列里
        // 已经要靠自动缩字号才放得下。
        detailLabel.text = "\(Strings.text("Free")) \(Formatting.bytes(free))"
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
