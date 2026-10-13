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
    private static let outerLineWidth: CGFloat = 7.5
    /// 内环（RAM）线宽。
    private static let innerLineWidth: CGFloat = 6
    /// 两个环之间的净间隙。
    ///
    /// 线宽与间隙一起按 1.5 倍放大（原来是 5 / 4 / 5）—— **只放大半径、不放大线宽，
    /// 环壁会相对变薄**，看着就不是同一个环了。放大后两个切口标签中心的径向距离 =
    /// 3.75 + 7.5 + 3 = 14.25pt，框高 12pt 正好不叠。
    private static let ringGap: CGFloat = 7.5

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

        // 字号：**2026-10-13 实机反馈后整组放大 1.5 倍**（11 / 7 / 6 → 16 / 10 / 9）。
        //
        // 比例调过三轮：0.0.42 是 15 / 9 / 9（被指出「太大、超出圆环」）→ 0.0.43 收到
        // 13 / 8 / 8 → 11 / 7 / 7 → 6pt。但 0.0.43 装到真机上，环与文字一起显得偏小
        // （根因见 `TodayWidgetView.ringWidthRatio` 那段：宽度约束优先级太低，环格被
        // 后三格抢掉、环实际只画到约 39pt），用户要求**圆环及文案整体放大 50%**。
        //   · 「96%」16pt 等宽约 29pt，内环直径约 70pt，占四成；
        //   · 「1.2GB」10pt 约 31pt（已去掉「剩余」前缀）；
        //   · 切口标签 9pt：「CPU 96%」约 34pt、「RAM」约 21pt。
        //
        // **字重沿用对齐主 App 功率圆环的那一套**：只有「读数」是 semibold，caption
        // 与标签都是 medium（`AppFont.text(12, .medium)`）。
        centerValueLabel.font = TodayFont.readout(16, weight: .semibold)
        centerValueLabel.textColor = TodayStyle.primary
        centerValueLabel.textAlignment = .center
        centerValueLabel.adjustsFontSizeToFitWidth = true
        centerValueLabel.minimumScaleFactor = 0.7

        // 第二行是纯数字 + 西文的短行（`1.2GB`），按主程序副行（`mwMono`）的规矩用
        // **真等宽**；再往下那两个切口标签是拉丁标签，与主程序 caption 同规，用 text。
        centerDetailLabel.font = TodayFont.mono(10)
        centerDetailLabel.textColor = TodayStyle.muted
        centerDetailLabel.textAlignment = .center
        centerDetailLabel.adjustsFontSizeToFitWidth = true
        centerDetailLabel.minimumScaleFactor = 0.7

        ramLabel.font = TodayFont.text(9, weight: .medium)
        ramLabel.textColor = TodayStyle.ramRing
        ramLabel.textAlignment = .center

        cpuLabel.font = TodayFont.text(9, weight: .medium)
        cpuLabel.textColor = TodayStyle.cpuRing
        cpuLabel.textAlignment = .center

        for label in [centerValueLabel, centerDetailLabel, ramLabel, cpuLabel] {
            addSubview(label)
        }
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()

        // 圆环水平居中，竖直方向也居中 —— 两个切口标签已经移到环内，内容就是环本身，
        // 不再需要像早先那样为环下方的标签预留偏移。
        let lineWidths = Self.outerLineWidth + Self.innerLineWidth
        // 四条边各留 20pt 余量后取正圆：`available` 既是环的可用直径，也是它到边界的距离。
        let available = min(bounds.width, bounds.height - 20)
        let outerRadius = max(12, (available - lineWidths - Self.ringGap) / 2)
        let innerRadius = max(6, outerRadius - Self.outerLineWidth / 2 - Self.ringGap - Self.innerLineWidth / 2)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // 轨道：从 7 点沿**顺时针**扫满 300°，缺口自然落在正下方（起点 7 点、终点 5 点）。
        outerTrack.path = Self.arcPath(center: center, radius: outerRadius,
                                       from: Self.startDegrees, sweep: Self.sweepDegrees)
        outerTrack.frame = bounds
        innerTrack.path = Self.arcPath(center: center, radius: innerRadius,
                                       from: Self.startDegrees, sweep: Self.sweepDegrees)
        innerTrack.frame = bounds

        // 进度弧：与轨道同一个起点，长度 = 300° × 百分比（满量程是那 300°，不是整圆）。
        applyProgress(outerProgress, center: center, radius: outerRadius,
                      fraction: cpuFraction, color: TodayStyle.cpuRing)
        applyProgress(innerProgress, center: center, radius: innerRadius,
                      fraction: ramFraction, color: TodayStyle.ramRing)

        layoutLabels(center: center, outerRadius: outerRadius, innerRadius: innerRadius)
    }

    private func layoutLabels(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat) {
        // 行高跟着字号走（16pt 等宽约 21pt 行高，10pt 约 13pt 行高）。
        let valueHeight: CGFloat = 21
        let detailHeight: CGFloat = 13

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

        // 切口标签：**落在两个断点（7 点、5 点）连线的中点上**，而不是贴在弧的外沿。
        //
        // 贴外沿时文字紧挨着弧最粗的那一圈，看着往外坠；移到断点连线中点，视觉上正好
        // 落进缺口的中央。该点的垂直偏移 = R × sin60° —— 7 点与 5 点分别在 210° / 150°
        // 方向，两个方向上的余弦相消、正弦同号，中点就落在圆心正下方 0.866R 处。
        //
        // 两个标签中心因此相距 0.866 × (outerRadius − innerRadius) ≈ 12.3pt，框高取 12pt
        // 正好不叠（0.0.41 曾用 12pt 框压进 8.5pt 的间隙，实机上叠成了一团）。
        let sin60 = sin(CGFloat.pi / 3)
        let labelWidth: CGFloat = 68
        let labelHeight: CGFloat = 12
        let cutCentreY = center.y + outerRadius * sin60
        let innerCutCentreY = center.y + innerRadius * sin60

        ramLabel.frame = CGRect(x: center.x - labelWidth / 2,
                                y: innerCutCentreY - labelHeight / 2,
                                width: labelWidth, height: labelHeight)
        cpuLabel.frame = CGRect(x: center.x - labelWidth / 2,
                                y: cutCentreY - labelHeight / 2,
                                width: labelWidth, height: labelHeight)
    }

    // MARK: - 应用数据

    /// - Parameters:
    ///   - cpuFraction: 0…1，外环。
    ///   - ramFraction: 0…1，内环。
    ///   - ramDetail: 环内第二行，**只放容量数字**，例如「1.2GB」（不带「剩余」前缀）。
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

    /// 「以 12 点为 0°、顺时针为正」的角度 → 视图坐标里的点。
    ///
    /// 整个组件只有这一个角度入口，所以很好验证：0° = 正上方、90° = 正右、
    /// 180° = 正下、270° = 正左。
    private static func point(center: CGPoint, radius: CGFloat,
                              twelveClockwise degrees: CGFloat) -> CGPoint {
        let radians = (degrees - 90) * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius,
                       y: center.y + sin(radians) * radius)
    }

    /// 沿「12 点为 0°、顺时针为正」构造一段弧。
    ///
    /// **刻意不用 `UIBezierPath(arcCenter:radius:startAngle:endAngle:clockwise:)`**：
    /// 那个 `clockwise` 参数在 UIView 的翻转坐标系里方向是反的（UIKit 文档原话
    /// "in a flipped coordinate system, specifying a clockwise arc results in a
    /// counterclockwise arc"），0.0.41 实机上两端位置就不对。按角度自己采样虽然笨，
    /// 但只有一种解释 —— 每 2° 一段，300° 的弧在 63pt 直径上弦高误差约 0.01pt，
    /// 与真圆弧肉眼无差。
    private static func arcPath(center: CGPoint, radius: CGFloat,
                                from startDegrees: CGFloat, sweep: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let steps = max(2, Int((abs(sweep) / 2).rounded(.up)))
        for step in 0...steps {
            let degrees = startDegrees + sweep * CGFloat(step) / CGFloat(steps)
            let p = point(center: center, radius: radius, twelveClockwise: degrees)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func applyProgress(_ layer: CAShapeLayer, center: CGPoint, radius: CGFloat,
                               fraction: Double, color: UIColor) {
        // 零长度路径 + 圆头线帽会画出一个小圆点（半径 = 线宽/2）。占用率极低时
        // 直接不画，比在起点留一个点干净。
        guard fraction > 0.001 else {
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        layer.path = Self.arcPath(center: center, radius: radius,
                                  from: Self.startDegrees,
                                  sweep: Self.sweepDegrees * CGFloat(fraction))
        layer.strokeColor = color.cgColor
        layer.frame = bounds
    }
}
