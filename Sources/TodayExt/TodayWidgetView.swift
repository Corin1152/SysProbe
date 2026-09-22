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
/// 尺寸对齐 CPU-X 的组件（约 118pt 高）。内容分四组横排，每组「标签 / 大读数 /
/// 副标签」三层；四组下面是一条系统存储的进度条。
///
///      CPU          内存         充电器        电芯
///      11%          88%          1.61 W       0.59 W
///      2376 MHz     351 MB 空闲  输入功率     输入功率
///
///      存储              已用 12.2 GB · 剩余 51.8 GB
///      ▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
final class TodayWidgetView: UIView {

    /// 四组读数，顺序：CPU / 内存 / 充电器 / 电芯。
    private let cpuCell = TodayCellView()
    private let memoryCell = TodayCellView()
    private let chargerCell = TodayCellView()
    private let cellCell = TodayCellView()
    private let storage = TodayStorageView()

    private let root = UIStackView()

    /// 左右留白。
    ///
    /// 这个数值不是随手定的：负一屏的组件标题（图标 + App 名 + 箭头）由**系统**绘制，
    /// 它有自己的边距（实测约 19pt）。内容区原来贴边，于是最左边的 `CPU` 比上方图标
    /// 往外探出约 13pt，看着不齐。加上这个偏移后，`CPU` 的左边缘正好落在图标的左边缘上；
    /// 右边也顺带留出空间，「已用 … · 剩余 …」不会再顶到组件右边缘。
    private static let horizontalInset: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let row = UIStackView(arrangedSubviews: [cpuCell, memoryCell, chargerCell, cellCell])
        row.axis = .horizontal
        row.spacing = 4
        // `.fillEqually`：四组等宽，读数不会因为某组数字长就把别的挤歪。
        row.distribution = .fillEqually
        row.alignment = .top

        root.axis = .vertical
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(row)
        root.addArrangedSubview(storage)
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: Self.horizontalInset),
            root.trailingAnchor.constraint(equalTo: trailingAnchor,
                                           constant: -Self.horizontalInset),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: 每秒刷新

    /// 数据来自两个采样器：硬件（CPU / 内存 / 存储）与电源（充电功率）。
    ///
    /// 未插电时 `inputWatts` / `batteryWatts` 会是 nil，这里按 **0 W** 显示而不是「—」：
    /// 四组读数里突然出现一个破折号，看上去像「这一项坏了」；而 0 W 本身是准确的读数
    /// （确实没有功率进来）。电芯那组本来就是这个行为，两组现在一致。
    ///
    /// 数字与单位**分开**传：单位要小一号、颜色也更淡。所以这里用 `Formatting.number`
    /// 而不是 `Formatting.percent` —— 后者会把 `%` 一起吐出来，再叠一个单位就印出两个。
    func apply(hardware: HardwareSnapshot, power: PowerSnapshot) {
        cpuCell.apply(caption: Strings.text("CPU"),
                      value: Formatting.number(hardware.cpu.usage * 100),
                      unit: "%",
                      tint: TodayStyle.loadTint(hardware.cpu.usage),
                      footnote: hardware.cpu.frequencyMHz > 0
                          ? "\(hardware.cpu.frequencyMHz) MHz"
                          : "—")

        memoryCell.apply(caption: Strings.text("Memory"),
                         value: Formatting.number(hardware.memory.usage * 100),
                         unit: "%",
                         tint: TodayStyle.loadTint(hardware.memory.usage),
                         footnote: Strings.text("%@ free", Formatting.bytes(hardware.memory.available)))

        chargerCell.apply(caption: Strings.text("Charger"),
                          value: Formatting.watts(power.inputWatts ?? 0),
                          unit: "W",
                          tint: TodayStyle.accent,
                          footnote: Strings.text("Input power"))

        cellCell.apply(caption: Strings.text("Cell"),
                       value: Formatting.watts(abs(power.batteryWatts ?? 0)),
                       unit: "W",
                       tint: TodayStyle.battery,
                       footnote: Strings.text("Input power"))

        storage.apply(used: hardware.storage.used, free: hardware.storage.free)
    }
}

// MARK: - 一组读数

/// 一组读数的三层：小标签 / 大读数 / 副标签。
///
/// 三层各自固定字号，且读数用等宽数字 —— 每秒刷新时宽度不会跳动。
final class TodayCellView: UIView {

    private let captionLabel = UILabel()
    private let valueLabel = UILabel()
    private let unitLabel = UILabel()
    private let footnoteLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        captionLabel.font = TodayFont.text(11, weight: .semibold)
        captionLabel.textColor = TodayStyle.muted
        captionLabel.numberOfLines = 1

        valueLabel.font = TodayFont.mono(11, weight: .semibold)
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        valueLabel.numberOfLines = 1

        unitLabel.font = TodayFont.text(10, weight: .medium)
        unitLabel.textColor = TodayStyle.muted

        footnoteLabel.font = TodayFont.text(11)
        footnoteLabel.textColor = TodayStyle.muted
        footnoteLabel.numberOfLines = 1
        footnoteLabel.adjustsFontSizeToFitWidth = true
        footnoteLabel.minimumScaleFactor = 0.75

        let valueRow = UIStackView(arrangedSubviews: [valueLabel, unitLabel])
        valueRow.axis = .horizontal
        valueRow.spacing = 2
        valueRow.alignment = .firstBaseline

        let stack = UIStackView(arrangedSubviews: [captionLabel, valueRow, footnoteLabel])
        stack.axis = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(caption: String, value: String, unit: String?, tint: UIColor, footnote: String) {
        // 微标签：拉丁下转大写加字距，中文下原样（汉字没有大小写，加了只会显散）。
        let shown = TodayFont.captionUppercases ? caption.uppercased() : caption
        captionLabel.attributedText = NSAttributedString(string: shown, attributes: [
            .font: TodayFont.text(11, weight: .semibold),
            .foregroundColor: TodayStyle.muted,
            .kern: TodayFont.captionTracking,
        ])
        valueLabel.text = value
        // 占位符画成弱化的灰 —— 它表示「没有读数」，不该看起来像一个值。
        valueLabel.textColor = value == "—" ? TodayStyle.muted.withAlphaComponent(0.55) : tint
        unitLabel.text = unit
        unitLabel.isHidden = unit == nil
        footnoteLabel.text = footnote
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

        captionLabel.font = TodayFont.text(11, weight: .semibold)
        captionLabel.textColor = TodayStyle.muted

        detailLabel.font = TodayFont.mono(11)
        detailLabel.textColor = TodayStyle.muted
        detailLabel.textAlignment = .right

        track.backgroundColor = TodayStyle.track
        track.layer.cornerRadius = 2.5
        fill.layer.cornerRadius = 2.5
        fill.backgroundColor = TodayStyle.accent

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
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(used: UInt64, free: UInt64) {
        let total = used &+ free
        fraction = total == 0 ? 0 : min(max(Double(used) / Double(total), 0), 1)

        let shown = TodayFont.captionUppercases
            ? Strings.text("Storage").uppercased()
            : Strings.text("Storage")
        captionLabel.attributedText = NSAttributedString(string: shown, attributes: [
            .font: TodayFont.text(11, weight: .semibold),
            .foregroundColor: TodayStyle.muted,
            .kern: TodayFont.captionTracking,
        ])
        detailLabel.text = Strings.text("%@ used · %@ free",
                                        Formatting.bytes(used),
                                        Formatting.bytes(free))
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
