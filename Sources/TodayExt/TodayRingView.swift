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
/// · **环内三行是读数**，以**内环圆心**为中心自上而下排列 ——
///   `CPU 占用率` / `内存占用率` / `内存容量`；
/// · `RAM` 与 `CPU` 两个标签**贴在各自环的切口处**（也就是正下方那两个断口），
///   只标「这一圈是什么」—— **数值全在环内**（0.0.52 起）。
///
/// 为什么把标签放在切口：切口那里本来就没有笔画，文字落在上面不会被弧压住，
/// 而且它天然指明了「这个标签说的是哪一圈」—— 放在环外就得靠颜色去猜。
///
/// ## 颜色
///
/// · **环与环内的读数取同一个色阶函数**（`cpuLoadTint` / `memoryLoadTint`）：
///   低占用时是两环本来的颜色（外环青蓝 / 内环黄绿），中档起**环与数字一起**转橙、红；
/// · **容量那行与两个切口标签纯黑**（`TodayStyle.text`）—— 容量没有「量」的含义
///   （进度条已经表达了），标签则是文案，不是读数。
final class TodayRingView: UIView {

    // MARK: - 几何常量

    /// 起点角度：7 点钟。以 12 点为 0°、顺时针为正。
    private static let startDegrees: CGFloat = 210
    /// 扫过的角度：7 点顺时针到 5 点，正好 300°（缺口 60°，居中正下方）。
    private static let sweepDegrees: CGFloat = 300

    /// 外环（CPU）线宽。
    ///
    /// **5.5pt 是对着 CPU-X 的参考图定的**：那边环的外沿直径与线宽之比约 5%，
    /// 我们原来是 7%（7.5 / 106.5），看着偏「胖」。线宽收细之后，同样的可用直径会
    /// 算出更大的半径（`outerRadius` 里要减掉的线宽变少），环反而略微变大。
    private static let outerLineWidth: CGFloat = 5.5
    /// 内环（RAM）线宽。
    private static let innerLineWidth: CGFloat = 4.5
    /// 两个环之间的净间隙。
    ///
    /// **10 → 5（用户 0.0.48 要求「外环直径不变、内环加大」）。** 内环半径 =
    /// `outerRadius − 0.5·外线宽 − ringGap − 0.5·内线宽`，间隙每让出 1pt，内环直径
    /// 就多 2pt。实机上环只能拿到约 80pt 外沿（系统给的高度就那么大），内环因此很挤
    /// —— 中心的「314.2MB」直接压在绿环上，所以这里必须让。
    ///
    /// ⚠ 代价是**两个切口标签靠得更近**（中心距 = `0.866 × (ringGap + 线宽和/2)`）：
    /// 10pt 时约 13pt、5pt 时只有 8.7pt，而标签框高 8pt —— 几乎贴住。所以两个标签
    /// 的**落点也一起错开了**（见 `layoutLabels`：内环标签往里、外环标签往外）。
    private static let ringGap: CGFloat = 5

    // MARK: - 图层

    private let outerTrack = CAShapeLayer()
    private let outerProgress = CAShapeLayer()
    private let innerTrack = CAShapeLayer()
    private let innerProgress = CAShapeLayer()

    // MARK: - 文字

    /// 环内第一行：**CPU 占用率**（0.0.52 从外环切口挪进来的）。
    private let centerCPULabel = UILabel()
    /// 环内第二行：内存占用率。
    private let centerValueLabel = UILabel()
    /// 环内第三行：内存容量。
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

        // ── 字号：**随环的尺寸等比缩放**，见 `applyFontScale` ──
        //
        // 基准是「可用直径 ≥ 90pt」时的 **11pt（环内三行）/ 8pt（两个切口标签）**。
        // 写成固定值是不行的：环实际能拿到多大由组件高度决定，而组件高又被系统的
        // 展开态上限压着 —— 环小的时候固定字号会把内环和缺口塞满。
        applyFontScale(1)

        // ── 环内三行（0.0.52 起）──
        //
        //      9%        ← CPU 占用率（本次从外环切口挪进来）
        //      98%       ← 内存占用率
        //      54.8MB    ← 内存容量
        //
        // 配色（0.0.56 起）：**环与环内的读数取同一个色阶函数**，两者因此天然同步 ——
        //   · CPU 值 = `cpuLoadTint(cpuFraction)`，低占用就是外环色 `cpuRing`；
        //   · 内存值 = `memoryLoadTint(ramFraction)`，低占用就是内环色 `ramRing`。
        // 低占用是绝大多数时候的状态，所以「读数和它所属的环同色」是常态；
        // 中档起两个一起转橙、红 —— 那时「量高」比「属于哪一圈」更该被看到。
        // 初值取低档，`apply` 每来一次数据都会重设。这三行都是「数值」不是「文案」，
        // 用户明确要求纯黑只给文案。
        centerCPULabel.textColor = TodayStyle.cpuLoadTint(0)
        centerCPULabel.textAlignment = .center
        centerCPULabel.adjustsFontSizeToFitWidth = true
        centerCPULabel.minimumScaleFactor = 0.7

        centerValueLabel.textColor = TodayStyle.memoryLoadTint(0)
        centerValueLabel.textAlignment = .center
        centerValueLabel.adjustsFontSizeToFitWidth = true
        centerValueLabel.minimumScaleFactor = 0.7

        // 第三行是纯数字 + 西文的短行（`1.2GB` / `54.8MB`），按主程序副行（`mwMono`）的
        // 规矩用**真等宽**。**颜色是纯黑**（用户 0.0.48 要求）—— 它与上面两个占用率
        // 一起构成「环内读数」，不再走次要灰。
        centerDetailLabel.textColor = TodayStyle.text
        centerDetailLabel.textAlignment = .center
        centerDetailLabel.adjustsFontSizeToFitWidth = true
        centerDetailLabel.minimumScaleFactor = 0.7

        // 切口标签的宽度上限由缺口决定：缺口是 60° 扇形，标签落在两个断点连线的中点上
        // （距圆心 `0.866R`），那一行高度上缺口给出的**水平宽度** =
        // `2 × 0.866R × tan30° = R`，再扣掉弧端点的圆头线帽（外线宽 5.5pt）。
        //   当前（R = 43.75）：可用约 38pt ——「CPU」「RAM」在 8pt 下各约 17pt ✓ 余量很足；
        //   环小到 R = 36：可用约 30pt，仍放得下 → 这两个标签几乎不会被挤。
        //
        // **0.0.52 起切口里不再有数值**：占用率都移进了环内，切口只负责标「这一圈是什么」，
        // 所以标签短了一半（「CPU 7%」→「CPU」），宽度不再是约束。
        //
        // ⚠ 别用「把标签往外挪」来解决拥挤：半径越小，同样宽度占的角度越大，反而更挤；
        // 往外挪则直接落到环外去。
        ramLabel.textColor = TodayStyle.text
        ramLabel.textAlignment = .center

        cpuLabel.textColor = TodayStyle.text
        cpuLabel.textAlignment = .center

        for label in [centerCPULabel, centerValueLabel, centerDetailLabel, ramLabel, cpuLabel] {
            addSubview(label)
        }
    }

    // MARK: - 字号自适应

    /// 字号基准：**可用直径 90pt** —— 到了这个尺寸就用满 11pt，不再往下缩。
    ///
    /// 为什么是 90（0.0.52 环内改成三行后重算）：内环**内沿**直径 = `可用直径 − 39.5`
    /// （内环 = 可用 − 35，再扣一条内线宽 4.5），而两个方向都要放得下：
    ///   · 高度：三行行高 `3 × 13.1` + 两个行间隙 `2 × 1.5` ≈ **42pt**；
    ///   · 宽度：最宽那行 `54.8MB`（真等宽）约 **40pt**。
    /// 取大者 42pt → 可用直径 ≥ 约 82pt，这里取 **90** 留一点余量。
    ///
    /// 实机上可用直径在 100 上下，所以**正常情况下缩放恒为 1**，环内就是 11pt。
    /// 只有环被系统压得很小时才缩 —— 那种尺寸下三行会顶到内环的笔画上，缩是必要的。
    ///
    /// ⚠ **别把它改回 `ringPreferredHeight`（120）**：那是「期望环格高」，而真机给的
    /// 可用直径小于它，缩放会常年停在 0.85 上下 —— **环内字会比设定的字号小一号**，
    /// 而且光看代码发现不了（写的是 11pt、渲染出来是 9.4pt）。
    private static let referenceDiameter: CGFloat = 90
    /// 缩放下限。再小字就糊了，宁可让 `adjustsFontSizeToFitWidth` 去裁。
    private static let minimumFontScale: CGFloat = 0.7

    /// 环内**三行共用**的字号 —— **11pt**（用户 0.0.52 要求）。
    ///
    /// 三行 = CPU 占用率 / 内存占用率 / 内存容量。原来只有两行、12pt；加了 CPU 那一行
    /// 之后收到 11pt —— 内环里要竖着排三行，每行都得让出一点，否则整块会顶到内环的
    /// 笔画上。
    ///
    /// 字族与字重仍分工：两个占用率是**读数**（等宽数字 + semibold），
    /// 容量那行是**纯数字短行**，按主程序副行的规矩走真等宽（`mono`）。
    private static let referenceCenterSize: CGFloat = 11

    /// 两个切口标签（`RAM` / `CPU`）的字号 —— **8pt**（0.0.48 从 7 加大而来）。
    ///
    /// 它们能放多大由**缺口的可用宽度**决定：缺口是 60° 扇形，标签落在窄口里，
    /// 那一行高度上能给的宽度约等于所在环的半径（再扣掉弧端圆头线帽）。
    /// 8pt 下「RAM」「CPU」各约 17pt，在半径 25pt 以上都放得下。
    /// **0.0.52 起切口里不再有数值**，这两个标签比早先短得多，宽度已不成约束。
    private static let referenceLabelSize: CGFloat = 8

    /// 上一次应用过的缩放，避免每帧重建字体（`layoutSubviews` 是高频回调）。
    private var appliedFontScale: CGFloat = 0

    private func applyFontScale(_ scale: CGFloat) {
        let center = Self.referenceCenterSize * scale
        // 两个占用率同号同字重（都是读数）；容量那行走真等宽（主程序副行的规矩）。
        centerCPULabel.font = TodayFont.readout(center, weight: .semibold)
        centerValueLabel.font = TodayFont.readout(center, weight: .semibold)
        centerDetailLabel.font = TodayFont.mono(center)
        ramLabel.font = TodayFont.text(Self.referenceLabelSize * scale, weight: .medium)
        cpuLabel.font = TodayFont.text(Self.referenceLabelSize * scale, weight: .medium)
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()

        // 圆环水平居中，竖直方向也居中 —— 两个切口标签都在环内，内容就是环本身。
        let lineWidths = Self.outerLineWidth + Self.innerLineWidth
        // **可用直径 = min(列宽, 列高)，不再额外扣 20pt。**
        // 早先扣的那 20pt 是给「挂在环下方」的切口标签留的；0.0.43 起标签移到了环内
        // （落在两个断点连线的中点上），那 20pt 就成了纯粹白丢的直径。
        let available = min(bounds.width, bounds.height)
        let outerRadius = max(12, (available - lineWidths - Self.ringGap) / 2)
        let innerRadius = max(6, outerRadius - Self.outerLineWidth / 2 - Self.ringGap - Self.innerLineWidth / 2)

        // 字号跟着环的尺寸走（只在跨过阈值时才真的重建字体）。
        let fontScale = max(Self.minimumFontScale, min(1, available / Self.referenceDiameter))
        if abs(fontScale - appliedFontScale) > 0.02 {
            appliedFontScale = fontScale
            applyFontScale(fontScale)
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // 轨道：从 7 点沿**顺时针**扫满 300°，缺口自然落在正下方（起点 7 点、终点 5 点）。
        outerTrack.path = Self.arcPath(center: center, radius: outerRadius,
                                       from: Self.startDegrees, sweep: Self.sweepDegrees)
        outerTrack.frame = bounds
        innerTrack.path = Self.arcPath(center: center, radius: innerRadius,
                                       from: Self.startDegrees, sweep: Self.sweepDegrees)
        innerTrack.frame = bounds

        // 进度弧：与轨道同一个起点，长度 = 300° × 百分比（满量程是那 300°，不是整圆）。
        // **弧色跟着各自的占用量走**（用户 0.0.56）：低占用时就是两环本来的颜色
        // （外环青蓝 / 内环黄绿），中 / 高占用时环与环内那个读数**同步**转橙、红 ——
        // 「该注意了」这件事由环和数字一起说，比只有数字变色显眼得多。
        applyProgress(outerProgress, center: center, radius: outerRadius,
                      fraction: cpuFraction, color: TodayStyle.cpuLoadTint(cpuFraction))
        applyProgress(innerProgress, center: center, radius: innerRadius,
                      fraction: ramFraction, color: TodayStyle.memoryLoadTint(ramFraction))

        layoutLabels(center: center, outerRadius: outerRadius, innerRadius: innerRadius,
                     scale: appliedFontScale)
    }

    private func layoutLabels(center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat,
                              scale: CGFloat) {
        // ── 环内三行（0.0.52）──
        //
        // 行高**直接用字体自己的行高**（11pt 系统字约 13.1pt），不用估算常量 ——
        // 估算常量（当初的 21 / 13pt）比真实行高大出一截，文字在框里居中后上下各留
        // 一段看不见的空白，行与行看着就像贴在一起。框高 = 行高，净间隙就等于 `lineGap`。
        //
        // 三行同字号，所以行高相同、相邻两行的**中心距**是一个定值 `spacing`。
        // 摆放方式：**中间那行压在圆心上，上下两行各偏 ±spacing** —— 三行整体以圆心为
        // 中心，这就是用户 0.0.52 要的「在内环居中显示」。
        //
        // 不写成「把三行的包围盒居中」：两种算法在等行高时结果相同，但中心对称的写法
        // 对「行数变化」是自洽的 —— 0.0.52 正是把两行扩成三行，只动了下面那张行表，
        // 居中关系一点没歪。
        let lineHeight = centerValueLabel.font.lineHeight
        let lineGap = 1.5 * scale
        let spacing = lineHeight + lineGap
        // ⚠ 宽度取**内环的内沿**（`innerRadius − 半条线宽`），不是中心线直径 ——
        // 按中心线给宽度，文字两端会压在内环的笔画上。用户 0.0.48 反馈的
        // 「内存剩余量跟内环重叠」有一半是这个原因（另一半是内环太小，见 `ringGap`）。
        let innerWidth = (innerRadius - Self.innerLineWidth / 2) * 2
        let rows: [(UILabel, CGFloat)] = [
            (centerCPULabel, -spacing),
            (centerValueLabel, 0),
            (centerDetailLabel, spacing),
        ]
        for (label, offset) in rows {
            label.frame = CGRect(x: center.x - innerWidth / 2,
                                 y: center.y + offset - lineHeight / 2,
                                 width: innerWidth,
                                 height: lineHeight)
        }

        // 切口标签：**落在各自环缺口的底边上**（也就是两个起止点 7 点 / 5 点所在的那一行）。
        //
        // 7 点与 5 点分别在 210° / 150° 方向，余弦相消、正弦同号，所以它们连线的中点
        // 必然落在圆心正下方 `0.866R` 处 —— 这一行就是「缺口底边」。
        //
        // 0.0.47 曾为了避让把落点错开（内环 0.80R、外环 0.96R），结果两个标签
        // **都吊在半空中**，看着比缺口底边高一截（用户 0.0.49 实机反馈「RAM 跟下方的
        // 占用率有点偏高了，下移一些，跟环的起止点对齐在同一行」）。
        //
        // 现在两个都回到 `0.866R`。间隙只有 5pt、两个标签的中心距因此只有 8.7pt，
        // 小于字体行高 9.5pt —— 但**字形本身只有约 5.7pt 高**（行高里的上下空白不可见），
        // 所以视觉上不会叠。而缺口在这一行给出的宽度约等于所在环的半径，
        // 「CPU」「RAM」在 8pt 下各约 17pt，都放得下，不会压到弧。
        let sin60 = sin(CGFloat.pi / 3)
        let labelWidth: CGFloat = 68
        let labelHeight = ramLabel.font.lineHeight
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
    ///   - ramDetail: 环内第三行，**只放容量数字**，例如「1.2GB」（不带「剩余」前缀）。
    ///   - cpuPercentText: 环内第一行的 CPU 占用率文本（含 `%`），例如「17%」。
    func apply(cpuFraction: Double, ramFraction: Double,
               ramDetail: String, cpuPercentText: String) {
        self.cpuFraction = min(max(cpuFraction, 0), 1)
        self.ramFraction = min(max(ramFraction, 0), 1)

        // ── 环内三行：CPU 占用率 / 内存占用率 / 内存容量 ──
        //
        // CPU 那个数是用户 0.0.52 要求**从外环切口挪进来的**：两个占用率并排之后，
        // 一眼能比出「是 CPU 紧还是内存紧」，比一个在切口、一个在环内要好读。
        centerCPULabel.text = cpuPercentText
        // 两行读数与各自的环**取同一个色阶函数**（用户 0.0.56 要求「同步变色」）——
        // 低占用时分别是外环色 / 内环色，中高占用时与环一起转橙、红。
        centerCPULabel.textColor = TodayStyle.cpuLoadTint(self.cpuFraction)
        centerValueLabel.text = "\(Int((self.ramFraction * 100).rounded()))%"
        centerValueLabel.textColor = TodayStyle.memoryLoadTint(self.ramFraction)
        centerDetailLabel.text = ramDetail
        // 两个切口标签只负责标「这一圈是什么」—— 数值已经全在环内了。
        ramLabel.text = "RAM"
        cpuLabel.text = "CPU"

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
