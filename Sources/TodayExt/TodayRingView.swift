import UIKit

/// CPU / RAM 双圆环。
///
/// ## 几何（与设计稿逐项对齐）
///
/// ```
///   起点 7 点 ──╮              ╭── 终点 5 点
///               ╰──────────────╯
///                     缺口 60°
/// ```
///
/// · 两个环同心，**起点 7 点钟、终点 5 点钟，顺时针覆盖 300°**；
/// · 缺口 60°，**居中于正下方**（也就是 6 点钟方向）；
/// · 轨道与进度弧**两端都是圆头** —— 没有任何平头端点；
/// · 进度弧长度 = **轨道实长 × 百分比**（不是整圆周长 × 百分比）。
///
/// 最后一条容易搞错：300° 那段的弧长才是满量程，拿 2πr 去乘百分比的话，
/// 100% 会画到缺口里、50% 也会偏长。
///
/// ## 信息层级
///
/// · **外环 = CPU**（蓝），**内环 = RAM**（绿）；
/// · 中心两行是**内存读数**（占用率 + 剩余可用），以**内环圆心**为基准居中；
/// · `RAM` 与 `CPU xx%` 两个标签**贴在各自环的切口处**（也就是正下方那两个断口）。
///
/// 为什么把标签放在切口：切口那里本来就没有笔画，文字落在上面不会被弧压住，
/// 而且它天然指明了「这个标签说的是哪一圈」—— 放在环外就得靠颜色去猜。
final class TodayRingView: UIView {

    // MARK: - 几何常量

    /// 起点角度：7 点钟。以 12 点为 0°、顺时针为正。
    private static let startDegrees: CGFloat = 210
    /// 扫过的角度：7 点顺时针到 5 点，正好 300°（缺口 60°，居中正下方）。
    private static let sweepDegrees: CGFloat = 300

    /// 外环（CPU）线宽。
    private static let outerLineWidth: CGFloat = 6
    /// 内环（RAM）线宽。
    private static let innerLineWidth: CGFloat = 5
    /// 两个环之间的净间隙。
    private static let ringGap: CGFloat = 4

    // MARK: - 图层

    private let outerTrack = CAShapeLayer()
    private let outerProgress = CAShapeLayer()
    private let innerTrack = CAShapeLayer()
    private let innerProgress = CAShapeLayer()

    // MARK: - 文字

    private let centerValueLabel = UILabel()
    private let centerDetailLabel = UILabel()
    private let ramLabel = UILabel()
    private let cpuLabel = UILabel()

    // MARK: - 状态

    private var cpuFraction: Double = 0
    private var ramFraction: Double = 0

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        for layer in [outerTrack, outerProgress, innerTrack, innerProgress] {
            layer.fillColor = nil
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        outerTrack.strokeColor = TodayStyle.track.cgColor
        innerTrack.strokeColor = TodayStyle.track.cgColor
        outerTrack.lineWidth = Self.outerLineWidth
        innerTrack.lineWidth = Self.innerLineWidth
        outerProgress.lineWidth = Self.outerLineWidth
        innerProgress.lineWidth = Self.innerLineWidth

        centerValueLabel.font = TodayFont.mono(15, weight: .semibold)
        centerValueLabel.textColor = TodayStyle.primary
        centerValueLabel.textAlignment = .center
        centerValueLabel.adjustsFontSizeToFitWidth = true
        centerValueLabel.minimumScaleFactor = 0.7

        centerDetailLabel.font = TodayFont.text(9)
        centerDetailLabel.textColor = TodayStyle.muted
        centerDetailLabel.textAlignment = .center
        centerDetailLabel.adjustsFontSizeToFitWidth = true
        centerDetailLabel.minimumScaleFactor = 0.7

        ramLabel.font = TodayFont.text(10, weight: .semibold)
        ramLabel.textColor = TodayStyle.ramRing
        ramLabel.textAlignment = .center

        cpuLabel.font = TodayFont.text(10, weight: .semibold)
        cpuLabel.textColor = TodayStyle.cpuRing
        cpuLabel.textAlignment = .center

        for label in [centerValueLabel, centerDetailLabel, ramLabel, cpuLabel] {
            addSubview(label)
        }
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()

        // 圆环整体在水平方向居中、在竖直方向略微上移 —— 下方要留出切口标签的位置。
        let lineWidths = Self.outerLineWidth + Self.innerLineWidth
        let available = min(bounds.width, bounds.height - 20)
        let outerRadius = max(12, (available - lineWidths - Self.ringGap) / 2)
        let innerRadius = max(6, outerRadius - Self.outerLineWidth / 2 - Self.ringGap - Self.innerLineWidth / 2)

        let center = CGPoint(x: bounds.midX, y: bounds.minY + available / 2 + 2)

        let start = Self.standardAngle(fromTwelveClockwise: Self.startDegrees)
        let end = Self.standardAngle(fromTwelveClockwise: Self.startDegrees + Self.sweepDegrees)

        // UIBezierPath 的角度以 3 点为 0°、逆时针为正；我们的角度以 12 点为 0°、顺时针为正。
        // 换算之后「从 7 点顺时针扫 300°」在标准坐标系里是**逆时针**，所以 clockwise = false。
        let outerPath = UIBezierPath(arcCenter: center, radius: outerRadius,
                                     startAngle: start, endAngle: end, clockwise: false)
        outerTrack.path = outerPath.cgPath
        outerTrack.frame = bounds

        let innerPath = UIBezierPath(arcCenter: center, radius: innerRadius,
                                     startAngle: start, endAngle: end, clockwise: false)
        innerTrack.path = innerPath.cgPath
        innerTrack.frame = bounds

        let outerLength = Self.arcLength(radius: outerRadius, degrees: Self.sweepDegrees)
        let innerLength = Self.arcLength(radius: innerRadius, degrees: Self.sweepDegrees)

        applyProgress(outerProgress, center: center, radius: outerRadius,
                      length: outerLength, fraction: cpuFraction, color: TodayStyle.cpuRing)
        applyProgress(innerProgress, center: center, radius: innerRadius,
                      length: innerLength, fraction: ramFraction, color: TodayStyle.ramRing)

        layoutLabels(center: center, outerRadius: outerRadius, innerRadius: innerRadius)
    }

    private func layoutLabels(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat) {
        let valueHeight: CGFloat = 18
        let detailHeight: CGFloat = 11

        // 中心两行以**内环圆心**为基准居中：先算两行的总高，再把它对称地摆到圆心两侧。
        let total = valueHeight + detailHeight
        centerValueLabel.frame = CGRect(x: center.x - innerRadius,
                                        y: center.y - total / 2,
                                        width: innerRadius * 2,
                                        height: valueHeight)
        centerDetailLabel.frame = CGRect(x: center.x - innerRadius,
                                         y: center.y - total / 2 + valueHeight,
                                         width: innerRadius * 2,
                                         height: detailHeight)

        // 切口标签：贴在各自环的断口上，水平居中。
        let labelWidth: CGFloat = 52
        let labelHeight: CGFloat = 12
        let cutY = center.y + outerRadius + Self.outerLineWidth / 2 - labelHeight / 2
        let innerCutY = center.y + innerRadius + Self.innerLineWidth / 2 - labelHeight / 2

        ramLabel.frame = CGRect(x: center.x - labelWidth / 2, y: innerCutY,
                                width: labelWidth, height: labelHeight)
        cpuLabel.frame = CGRect(x: center.x - labelWidth / 2, y: cutY,
                                width: labelWidth, height: labelHeight)
    }

    // MARK: - 应用数据

    /// - Parameters:
    ///   - cpuFraction: 0…1，外环。
    ///   - ramFraction: 0…1，内环。
    ///   - ramDetail: 环内第二行，例如「剩余 1.2 GB」。
    ///   - cpuPercentText: 外环标签里的数值部分，例如「17%」。
    func apply(cpuFraction: Double, ramFraction: Double,
               ramDetail: String, cpuPercentText: String) {
        self.cpuFraction = min(max(cpuFraction, 0), 1)
        self.ramFraction = min(max(ramFraction, 0), 1)

        centerValueLabel.text = "\(Int((self.ramFraction * 100).rounded()))%"
        centerDetailLabel.text = ramDetail
        ramLabel.text = "RAM"
        cpuLabel.text = "CPU \(cpuPercentText)"

        setNeedsLayout()
    }

    // MARK: - 工具

    /// 把「以 12 点为 0°、顺时针为正」的角度，换算成 `UIBezierPath` 用的标准角度
    /// （以 3 点为 0°、逆时针为正）。
    private static func standardAngle(fromTwelveClockwise degrees: CGFloat) -> CGFloat {
        (degrees - 90) * .pi / 180
    }

    /// 给定半径与圆心角，返回弧长。
    ///
    /// **进度必须按这个长度算**，不能拿整圆周长去乘百分比 —— 轨道只占 300°。
    private static func arcLength(radius: CGFloat, degrees: CGFloat) -> CGFloat {
        2 * .pi * radius * degrees / 360
    }

    private func applyProgress(_ layer: CAShapeLayer, center: CGPoint, radius: CGFloat,
                               length: CGFloat, fraction: Double, color: UIColor) {
        let start = Self.standardAngle(fromTwelveClockwise: Self.startDegrees)
        let swept = Self.sweepDegrees * CGFloat(fraction)
        let end = Self.standardAngle(fromTwelveClockwise: Self.startDegrees + swept)

        let path = UIBezierPath(arcCenter: center, radius: radius,
                                startAngle: start, endAngle: end, clockwise: false)
        layer.path = path.cgPath
        layer.strokeColor = color.cgColor
        layer.frame = bounds
    }
}
