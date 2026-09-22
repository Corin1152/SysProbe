import UIKit

/// 负一屏的内容视图。纯 UIKit，不用 SwiftUI。
///
/// ## 为什么不用主 App 那套 SwiftUI 组件
///
/// 这一屏原本是 `UIHostingController` 装一个 SwiftUI 视图，装机后负一屏一直显示
/// 「无法载入」。对比能正常工作的 CPU-X 之后，原因很直接 —— 拆开两边的 appex，
/// 数里面的 SwiftUI 符号：
///
///     我们的 appex    181 个
///     CPU-X 的 appex    0 个      ← storyboard + UIKit 控件
///
/// 传统 Today 扩展的内存预算与启动 watchdog 都远小于主 App。appex 里只要还有
/// SwiftUI 的东西，dyld 就会把 `SwiftUI.framework` 映射进来，再叠上
/// `UIHostingController` 那一整套视图运行时 —— 在这点预算里就是启动即被掐掉，
/// 系统于是显示「无法载入」。
///
/// 所以这一屏用 UIKit 重写。取数仍然走 `PowerMonitor`，那一层已经与 SwiftUI 无关
/// （`Shared/Power` 里的 `import SwiftUI` 全部去掉了，`LocalizedStringKey` 换成
/// `String`）。颜色与字体见 `TodayStyle`，取值与 `Theme.swift` 一致。
final class TodayWidgetView: UIView {

    // MARK: 顶部

    private let ring = TodayRingView()
    private let statusPill = TodayPillView()
    private let wirelessPill = TodayPillView()
    private let batteryMetric = TodayMetricView()
    private let cellMetric = TodayMetricView()
    private let cellTemperatureMetric = TodayMetricView()

    // MARK: 电池

    private let batteryPanel = TodayPanelView(title: Strings.text("Battery"), symbol: "battery.100")
    private let voltageMetric = TodayMetricView()
    private let currentMetric = TodayMetricView()
    private let temperatureMetric = TodayMetricView()

    // MARK: 供电路径

    private let pathPanel = TodayPanelView(title: Strings.text("Power path"), symbol: "arrow.triangle.branch")
    private let pathTrailing = UILabel()
    private let fromChargerMetric = TodayMetricView()
    private let intoCellMetric = TodayMetricView()
    private let lossMetric = TodayMetricView()
    private let efficiencyMetric = TodayMetricView()

    // MARK: 适配器

    private let adapterPanel = TodayPanelView(title: Strings.text("Adapter"), symbol: "powerplug")
    private let adapterTrailing = UILabel()
    private let actualMetric = TodayMetricView()
    private let ratedMetric = TodayMetricView()
    private let utilisationBar = TodayBarView()
    private let nameRow = TodayDetailRow()
    private let negotiatedRow = TodayDetailRow()
    private let profilesCaption = TodayCaptionLabel()
    private let profilesStack = UIStackView()
    private let resistanceDivider = TodayDivider()
    private let resistanceMetric = TodayMetricView()
    private let voltageDropMetric = TodayMetricView()

    // MARK: 未插电

    private let idlePanel = TodayPanelView(title: Strings.text("Power"), symbol: "bolt.slash")
    private let idleNote = UILabel()

    private let root = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 组装

    private func build() {
        root.axis = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        root.addArrangedSubview(heroRow)
        root.addArrangedSubview(batteryPanel)
        root.addArrangedSubview(pathPanel)
        root.addArrangedSubview(adapterPanel)
        root.addArrangedSubview(idlePanel)

        assembleBatteryPanel()
        assemblePathPanel()
        assembleAdapterPanel()

        idleNote.numberOfLines = 0
        idleNote.font = .preferredFont(forTextStyle: .footnote)
        idleNote.textColor = TodayStyle.muted
        idlePanel.content.addArrangedSubview(idleNote)

        for panel in [batteryPanel, pathPanel, adapterPanel, idlePanel] {
            panel.isHidden = true
        }
    }

    private var heroRow: UIView {
        let info = UIStackView(arrangedSubviews: [
            pillsRow, batteryMetric, cellMetric, cellTemperatureMetric,
        ])
        info.axis = .vertical
        info.spacing = 8
        info.alignment = .leading

        let row = UIStackView(arrangedSubviews: [ring, info])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center

        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 132),
            ring.heightAnchor.constraint(equalToConstant: 132),
        ])

        batteryMetric.setSize(26)
        cellMetric.setSize(18)
        cellTemperatureMetric.setSize(18)
        batteryMetric.tint = TodayStyle.battery

        // 不加尾部 spacer：`row` 默认 `.fill`，`info` 会自己吃掉环右边的全部宽度，
        // 里面再靠 `alignment = .leading` 左对齐。多一个 spacer 只会把读数区挤窄。
        return row
    }

    private var pillsRow: UIView {
        let row = UIStackView(arrangedSubviews: [statusPill, wirelessPill])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        return row
    }

    private func assembleBatteryPanel() {
        for metric in [voltageMetric, currentMetric, temperatureMetric] { metric.setSize(20) }
        voltageMetric.tint = TodayStyle.accent
        currentMetric.tint = TodayStyle.battery

        let row = UIStackView(arrangedSubviews: [voltageMetric, currentMetric, temperatureMetric])
        row.axis = .horizontal
        row.spacing = 14
        row.distribution = .fillEqually
        batteryPanel.content.addArrangedSubview(row)
    }

    private func assemblePathPanel() {
        pathTrailing.font = TodayFont.mono(12)
        pathTrailing.textColor = TodayStyle.muted
        pathPanel.setTrailing(pathTrailing)

        for metric in [fromChargerMetric, intoCellMetric] { metric.setSize(22) }
        fromChargerMetric.tint = TodayStyle.accent
        intoCellMetric.tint = TodayStyle.battery
        let top = UIStackView(arrangedSubviews: [fromChargerMetric, intoCellMetric])
        top.axis = .horizontal
        top.spacing = 14
        top.distribution = .fillEqually

        for metric in [lossMetric, efficiencyMetric] { metric.setSize(18) }
        lossMetric.tint = TodayStyle.loss
        efficiencyMetric.tint = TodayStyle.battery
        let bottom = UIStackView(arrangedSubviews: [lossMetric, efficiencyMetric])
        bottom.axis = .horizontal
        bottom.spacing = 14
        bottom.distribution = .fillEqually

        pathPanel.content.addArrangedSubview(top)
        pathPanel.content.addArrangedSubview(bottom)
    }

    private func assembleAdapterPanel() {
        adapterTrailing.font = TodayFont.mono(12)
        adapterTrailing.textColor = TodayStyle.muted
        adapterPanel.setTrailing(adapterTrailing)

        for metric in [actualMetric, ratedMetric] { metric.setSize(22) }
        actualMetric.tint = TodayStyle.accent
        let top = UIStackView(arrangedSubviews: [actualMetric, ratedMetric])
        top.axis = .horizontal
        top.spacing = 14
        top.distribution = .fillEqually
        adapterPanel.content.addArrangedSubview(top)
        adapterPanel.content.addArrangedSubview(utilisationBar)

        profilesCaption.apply(Strings.text("Advertised profiles"))
        adapterPanel.content.addArrangedSubview(nameRow)
        adapterPanel.content.addArrangedSubview(negotiatedRow)

        adapterPanel.content.addArrangedSubview(TodayDivider())
        adapterPanel.content.addArrangedSubview(profilesCaption)
        profilesStack.axis = .vertical
        profilesStack.spacing = 6
        adapterPanel.content.addArrangedSubview(profilesStack)

        adapterPanel.content.addArrangedSubview(resistanceDivider)
        for metric in [resistanceMetric, voltageDropMetric] { metric.setSize(18) }
        resistanceMetric.tint = TodayStyle.loss
        let resistanceRow = UIStackView(arrangedSubviews: [resistanceMetric, voltageDropMetric])
        resistanceRow.axis = .horizontal
        resistanceRow.spacing = 14
        resistanceRow.distribution = .fillEqually
        adapterPanel.content.addArrangedSubview(resistanceRow)
    }

    // MARK: 每秒刷新

    func apply(_ snapshot: PowerSnapshot,
               headline: (watts: Double, caption: String)?,
               resistance: PathResistanceEstimate?) {

        ring.apply(inputWatts: headline?.watts,
                   batteryWatts: snapshot.batteryWatts,
                   fullScale: max(snapshot.adapterRatedWatts ?? 30, 1),
                   caption: headline?.caption,
                   tint: snapshot.isWirelessInput ? TodayStyle.wireless : TodayStyle.accent)

        statusPill.apply(text: snapshot.statusText,
                         symbol: snapshot.isCharging ? "bolt.fill" : "powerplug.fill",
                         tint: snapshot.isCharging ? TodayStyle.battery : TodayStyle.muted)
        wirelessPill.apply(text: Strings.text("Wireless"),
                           symbol: "wave.3.right",
                           tint: TodayStyle.wireless)
        wirelessPill.isHidden = !snapshot.isWirelessInput

        batteryMetric.apply(caption: Strings.text("Battery"),
                            value: snapshot.percent.map { "\($0)" } ?? "—",
                            unit: snapshot.percent != nil ? "%" : nil)
        batteryMetric.tint = TodayStyle.battery

        cellMetric.apply(caption: Strings.text("Cell"),
                         value: cellText(snapshot),
                         unit: nil)
        cellMetric.tint = .label
        cellMetric.isHidden = snapshot.batteryVoltage == nil && snapshot.batteryCurrent == nil

        cellTemperatureMetric.apply(caption: Strings.text("Cell temperature"),
                                    value: snapshot.batteryTemperature.map(Formatting.temperature) ?? "—",
                                    unit: nil)
        cellTemperatureMetric.tint = snapshot.batteryTemperature.map(TodayStyle.temperature) ?? TodayStyle.muted
        cellTemperatureMetric.isHidden = snapshot.batteryTemperature == nil

        let plugged = snapshot.externalConnected
        batteryPanel.isHidden = !plugged
        pathPanel.isHidden = !plugged
        adapterPanel.isHidden = !plugged
        idlePanel.isHidden = plugged

        guard plugged else {
            idleNote.text = Strings.text("Plug in a charger to read the adapter's handshake.")
            return
        }

        applyBattery(snapshot)
        applyPath(snapshot)
        applyAdapter(snapshot, resistance: resistance)
    }

    private func cellText(_ snapshot: PowerSnapshot) -> String {
        let volts = snapshot.batteryVoltage.map(Formatting.volts)
        let amps = snapshot.batteryCurrent.map(Formatting.amps)
        switch (volts, amps) {
        case let (v?, a?): return "\(v) · \(a)"
        case let (v?, nil): return v
        case let (nil, a?): return a
        default: return "—"
        }
    }

    private func applyBattery(_ snapshot: PowerSnapshot) {
        voltageMetric.apply(caption: Strings.text("Voltage"),
                            value: snapshot.batteryVoltage.map(Formatting.volts) ?? "—",
                            unit: nil)
        currentMetric.apply(caption: Strings.text("Current"),
                            value: snapshot.batteryCurrent.map(Formatting.amps) ?? "—",
                            unit: nil)
        temperatureMetric.apply(caption: Strings.text("Temperature"),
                                value: snapshot.batteryTemperature.map(Formatting.temperature) ?? "—",
                                unit: nil)
        temperatureMetric.tint = snapshot.batteryTemperature.map(TodayStyle.temperature) ?? TodayStyle.muted
    }

    private func applyPath(_ snapshot: PowerSnapshot) {
        if let utilisation = snapshot.adapterUtilisation {
            // 键是 `"%@ of adapter"`（值是「占适配器 %@」），百分号作为参数传进去 ——
            // 写在字面量里会被 `String(format:)` 当成格式符。
            let percent = Formatting.percent(utilisation * 100) + "%"
            pathTrailing.text = String(format: Strings.text("%@ of adapter"), percent)
            pathTrailing.isHidden = false
        } else {
            pathTrailing.isHidden = true
        }

        fromChargerMetric.apply(caption: Strings.text("From charger"),
                                value: snapshot.inputWatts.map(Formatting.watts) ?? "—",
                                unit: snapshot.inputWatts != nil ? "W" : nil)
        intoCellMetric.apply(caption: Strings.text("Into cell"),
                             value: snapshot.batteryWatts.map { Formatting.watts(abs($0)) } ?? "—",
                             unit: snapshot.batteryWatts != nil ? "W" : nil)
        lossMetric.apply(caption: Strings.text("Loss"),
                         value: snapshot.conversionLossWatts.map(Formatting.watts) ?? "—",
                         unit: snapshot.conversionLossWatts != nil ? "W" : nil)
        efficiencyMetric.apply(caption: Strings.text("Efficiency"),
                               value: snapshot.conversionEfficiency.map { Formatting.percent($0 * 100) } ?? "—",
                               unit: snapshot.conversionEfficiency != nil ? "%" : nil)
    }

    private func applyAdapter(_ snapshot: PowerSnapshot, resistance: PathResistanceEstimate?) {
        adapterTrailing.text = snapshot.adapterSource ?? ""
        adapterTrailing.isHidden = snapshot.adapterSource == nil

        actualMetric.apply(caption: Strings.text("Actual"),
                           value: snapshot.inputWatts.map(Formatting.watts) ?? "—",
                           unit: snapshot.inputWatts != nil ? "W" : nil)
        ratedMetric.apply(caption: Strings.text("Rated"),
                          value: snapshot.adapterRatedWatts.map { String(format: "%.0f", $0) } ?? "—",
                          unit: snapshot.adapterRatedWatts != nil ? "W" : nil)

        if let utilisation = snapshot.adapterUtilisation {
            utilisationBar.isHidden = false
            utilisationBar.apply(title: Strings.text("Adapter utilisation"),
                                 fraction: utilisation,
                                 detail: Formatting.percent(utilisation * 100) + "%",
                                 tint: TodayStyle.accent)
        } else {
            utilisationBar.isHidden = true
        }

        nameRow.apply(Strings.text("Name"), snapshot.adapterName)
        negotiatedRow.apply(Strings.text("Negotiated"), snapshot.negotiatedProfile?.label)

        let profiles = snapshot.adapterProfiles
        profilesCaption.isHidden = profiles.isEmpty
        profilesStack.isHidden = profiles.isEmpty
        if profilesStack.arrangedSubviews.count != profiles.count {
            profilesStack.arrangedSubviews.forEach {
                profilesStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for _ in profiles { profilesStack.addArrangedSubview(TodayProfileRow()) }
        }
        for (index, profile) in profiles.enumerated() {
            guard let row = profilesStack.arrangedSubviews[index] as? TodayProfileRow else { continue }
            row.apply(profile, negotiated: snapshot.negotiatedProfile?.index)
        }

        resistanceDivider.isHidden = resistance == nil
        if let resistance {
            resistanceMetric.apply(caption: Strings.text("Path resistance"),
                                   value: "\(resistance.milliohms)",
                                   unit: "mΩ")
            voltageDropMetric.apply(caption: Strings.text("Voltage drop"),
                                    value: snapshot.inputVoltageDropVolts.map { String(format: "%.2f", $0) } ?? "—",
                                    unit: snapshot.inputVoltageDropVolts != nil ? "V" : nil)
            resistanceMetric.isHidden = false
            voltageDropMetric.isHidden = false
        } else {
            resistanceMetric.isHidden = true
            voltageDropMetric.isHidden = true
        }
    }
}

// MARK: - 圆环

/// 输入 / 入池功率的双环。
///
/// 用 `CAShapeLayer` 而不是 SwiftUI 的 `Canvas`：这里要的只是两条圆弧，一层
/// layer 一次画完，没有任何视图树参与。
final class TodayRingView: UIView {

    private let trackLayer = CAShapeLayer()
    private let inputLayer = CAShapeLayer()
    private let batteryLayer = CAShapeLayer()
    private let wattsLabel = UILabel()
    private let captionLabel = UILabel()

    private var inputFraction: Double = 0
    private var batteryFraction: Double = 0
    private var tint: UIColor = TodayStyle.accent

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        for layer in [trackLayer, inputLayer, batteryLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        trackLayer.strokeColor = TodayStyle.track.cgColor

        wattsLabel.font = TodayFont.text(22, weight: .semibold)
        wattsLabel.textAlignment = .center
        wattsLabel.adjustsFontSizeToFitWidth = true
        wattsLabel.minimumScaleFactor = 0.5

        captionLabel.font = TodayFont.text(11, weight: .medium)
        captionLabel.textColor = TodayStyle.muted
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [wattsLabel, captionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.66),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(inputWatts: Double?, batteryWatts: Double?,
               fullScale: Double, caption: String?, tint: UIColor) {
        self.tint = tint
        inputFraction = min(max((inputWatts ?? 0) / fullScale, 0), 1)
        batteryFraction = min(max(abs(batteryWatts ?? 0) / fullScale, 0), 1)

        let watts = inputWatts ?? batteryWatts.map { abs($0) }
        wattsLabel.text = watts.map { String(format: "%.1f", $0) } ?? "—"
        wattsLabel.textColor = watts == nil ? TodayStyle.muted : tint
        captionLabel.text = caption
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 10 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // 外环 = 输入功率，内环 = 入池功率。
        let outerRadius = side / 2 - 8
        let innerRadius = outerRadius - 13
        let lineWidth: CGFloat = 9

        trackLayer.lineWidth = lineWidth
        trackLayer.path = arc(center: center, radius: outerRadius, fraction: 1).cgPath
        trackLayer.frame = bounds

        inputLayer.lineWidth = lineWidth
        inputLayer.strokeColor = tint.cgColor
        inputLayer.path = arc(center: center, radius: outerRadius, fraction: inputFraction).cgPath
        inputLayer.frame = bounds

        batteryLayer.lineWidth = lineWidth
        batteryLayer.strokeColor = TodayStyle.battery.cgColor
        batteryLayer.path = arc(center: center, radius: innerRadius, fraction: batteryFraction).cgPath
        batteryLayer.frame = bounds
    }

    /// 从 12 点方向顺时针画一段弧。
    private func arc(center: CGPoint, radius: CGFloat, fraction: Double) -> UIBezierPath {
        let path = UIBezierPath(arcCenter: center,
                                radius: radius,
                                startAngle: -.pi / 2,
                                endAngle: -.pi / 2 + 2 * .pi * CGFloat(max(fraction, 0.0001)),
                                clockwise: true)
        return path
    }
}

// MARK: - 读数

final class TodayMetricView: UIView {

    private let captionLabel = UILabel()
    private let valueLabel = UILabel()
    private let unitLabel = UILabel()

    var tint: UIColor = .label {
        didSet { applyValueColor() }
    }

    /// 占位符（`—`）画成弱化的灰，而不是读数的强调色 —— 它表示「没有读数」，
    /// 不该看起来像一个值。`tint` 的 `didSet` 也要走这里，否则外面在 `apply`
    /// 之后设一次 `tint` 就会把占位符的颜色覆盖掉。
    private func applyValueColor() {
        valueLabel.textColor = valueLabel.text == "—"
            ? TodayStyle.muted.withAlphaComponent(0.55)
            : tint
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        captionLabel.font = TodayFont.text(11, weight: .semibold)
        captionLabel.textColor = TodayStyle.muted

        valueLabel.font = TodayFont.mono(18, weight: .semibold)
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.5
        valueLabel.textColor = tint

        unitLabel.font = TodayFont.text(11, weight: .medium)
        unitLabel.textColor = TodayStyle.muted

        let valueRow = UIStackView(arrangedSubviews: [valueLabel, unitLabel])
        valueRow.axis = .horizontal
        valueRow.spacing = 3
        valueRow.alignment = .firstBaseline

        let stack = UIStackView(arrangedSubviews: [captionLabel, valueRow])
        stack.axis = .vertical
        stack.spacing = 3
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

    func setSize(_ size: CGFloat) {
        valueLabel.font = TodayFont.mono(size, weight: .semibold)
    }

    func apply(caption: String, value: String, unit: String?) {
        captionLabel.attributedText = captionText(caption)
        valueLabel.text = value
        applyValueColor()
        unitLabel.text = unit
        unitLabel.isHidden = unit == nil
    }

    /// 微标签：拉丁下转大写加字距，中文下原样（汉字没有大小写，加了只会显散）。
    private func captionText(_ text: String) -> NSAttributedString {
        let shown = TodayFont.captionUppercases ? text.uppercased() : text
        return NSAttributedString(string: shown, attributes: [
            .font: TodayFont.text(11, weight: .semibold),
            .foregroundColor: TodayStyle.muted,
            .kern: TodayFont.captionTracking,
        ])
    }
}

// MARK: - 面板

final class TodayPanelView: UIView {

    let content = UIStackView()
    private let titleLabel = UILabel()
    private let iconView = UIImageView()
    private let header = UIStackView()

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        backgroundColor = TodayStyle.card
        layer.cornerRadius = TodayStyle.cardRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = TodayStyle.stroke.cgColor

        iconView.image = UIImage(systemName: symbol)
        iconView.tintColor = TodayStyle.muted
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.attributedText = NSAttributedString(string: title, attributes: [
            .font: TodayFont.text(11, weight: .semibold),
            .foregroundColor: TodayStyle.muted,
        ])

        header.axis = .horizontal
        header.spacing = 6
        header.alignment = .center
        header.addArrangedSubview(iconView)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(UIView())

        content.axis = .vertical
        content.spacing = 10

        let stack = UIStackView(arrangedSubviews: [header, content])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TodayStyle.cardPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TodayStyle.cardPadding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: TodayStyle.cardPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -TodayStyle.cardPadding),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTrailing(_ view: UIView) {
        header.addArrangedSubview(view)
    }
}

// MARK: - 小件

final class TodayPillView: UIView {

    private let label = UILabel()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous

        label.font = TodayFont.text(12, weight: .semibold)
        iconView.contentMode = .scaleAspectFit

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 11),
            iconView.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(text: String, symbol: String, tint: UIColor) {
        label.text = text
        label.textColor = tint
        iconView.image = UIImage(systemName: symbol)
        iconView.tintColor = tint
        backgroundColor = tint.withAlphaComponent(0.12)
    }
}

final class TodayBarView: UIView {

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint!
    private var fraction: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = TodayFont.text(13)
        titleLabel.textColor = TodayStyle.muted
        detailLabel.font = TodayFont.mono(12)
        detailLabel.textColor = TodayStyle.muted

        track.backgroundColor = TodayStyle.track
        track.layer.cornerRadius = 3
        fill.layer.cornerRadius = 3

        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), detailLabel])
        header.axis = .horizontal
        header.spacing = 8

        track.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)

        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fillWidth,
        ])

        let stack = UIStackView(arrangedSubviews: [header, track])
        stack.axis = .vertical
        stack.spacing = 5
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

    func apply(title: String, fraction: Double, detail: String, tint: UIColor) {
        titleLabel.attributedText = NSAttributedString(string: title, attributes: [
            .font: TodayFont.text(13), .foregroundColor: TodayStyle.muted,
        ])
        detailLabel.text = detail
        fill.backgroundColor = tint
        self.fraction = min(max(fraction, 0), 1)
        setNeedsLayout()
    }

    /// 填充宽度只能在这里算：`apply` 是在布局之前调用的，那时 `track.bounds.width`
    /// 还是 0，当场读会得到一条永远填不满的进度条。
    override func layoutSubviews() {
        super.layoutSubviews()
        let target = track.bounds.width * CGFloat(fraction)
        // 值没变就别写回 —— 赋 `constant` 会 invalidate 布局，不设这道闸就是每帧一次
        // 的布局循环。
        if abs(fillWidth.constant - target) > 0.5 {
            fillWidth.constant = target
        }
    }
}

final class TodayDetailRow: UIView {

    private let label = UILabel()
    private let value = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = TodayFont.text(13)
        label.textColor = TodayStyle.muted
        value.font = TodayFont.text(13, weight: .medium)
        value.textAlignment = .right
        value.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [label, value])
        stack.axis = .horizontal
        stack.spacing = 8
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

    func apply(_ labelText: String, _ valueText: String?) {
        label.text = labelText
        value.text = valueText
        isHidden = valueText == nil
    }
}

final class TodayProfileRow: UIView {

    private let iconView = UIImageView()
    private let label = UILabel()
    private let watts = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        label.font = TodayFont.mono(12)
        watts.font = TodayFont.mono(12)
        watts.textColor = TodayStyle.muted
        watts.textAlignment = .right

        let stack = UIStackView(arrangedSubviews: [iconView, label, UIView(), watts])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 11),
            iconView.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ profile: PDProfile, negotiated: Int?) {
        let selected = profile.index == negotiated
        iconView.image = UIImage(systemName: selected ? "largecircle.fill.circle" : "circle")
        iconView.tintColor = selected ? TodayStyle.accent : TodayStyle.muted
        label.text = profile.label
        watts.text = String(format: "%.0f W", profile.watts)
    }
}

final class TodayCaptionLabel: UILabel {

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = TodayFont.text(11, weight: .semibold)
        textColor = TodayStyle.muted
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ text: String) {
        let shown = TodayFont.captionUppercases ? text.uppercased() : text
        attributedText = NSAttributedString(string: shown, attributes: [
            .font: TodayFont.text(11, weight: .semibold),
            .foregroundColor: TodayStyle.muted,
            .kern: TodayFont.captionTracking,
        ])
    }
}

final class TodayDivider: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TodayStyle.stroke
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
