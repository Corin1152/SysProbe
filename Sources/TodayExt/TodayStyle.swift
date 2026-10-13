import UIKit

/// 负一屏的样式常量。
///
/// 色值与 `Shared/Design/Theme.swift` 一致，但**刻意不复用那个文件**：它整份建立在
/// SwiftUI 的 `Color` 之上，而这一屏必须完全脱离 SwiftUI。原因见 `TodayWidgetView`
/// 顶部的说明 —— 一句话，传统 Today 扩展的内存预算与启动 watchdog 撑不起
/// `UIHostingController` 那一整套运行时，代价就是负一屏显示「无法载入」。
///
/// `nonisolated` 是必须的，不是整洁：工程默认主 actor 隔离，那会让下面 `UIColor`
/// 的 trait 解析闭包也变成主 actor 隔离，而 UIKit 从渲染线程调它。Swift 6 会在那里
/// 插一次执行器检查 —— 首帧直接 trap。这个坑在 `Theme.swift` 里踩过一次。
nonisolated enum TodayStyle {

    /// 一份随浅色/深色自动解析的颜色。
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    /// 适配器侧：从充电器来的。
    static let accent = dynamic(0x0086B3, 0x35DFFF)
    /// 电池侧：真正进到电芯的。
    static let battery = dynamic(0x0E9B57, 0x3FE08C)
    /// 变成热损耗掉的。
    static let loss = dynamic(0xB86A00, 0xFFB443)
    /// 高占用 / 危险。
    static let danger = dynamic(0xC5342B, 0xFF6058)
    /// 无线 / MagSafe。
    static let wireless = dynamic(0x6B4EE6, 0xB49BFF)
    /// 次要文字（caption / 单位 / 副行）。
    ///
    /// **与主 App 的 `Theme.mwMuted` 同值** —— 负一屏原来用的是 0x3E4757（偏蓝黑），
    /// 两屏放在一起能看出不是一个调。颜色是「风格一致」里最先被眼睛抓到的一项，
    /// 字体族、字重对上了、颜色不对，看着仍然像两个 App。
    static let muted = dynamic(0x60687A, 0x8C93A6)
    static let card = dynamic(0xFFFFFF, 0x14171F)
    static let stroke = dynamic(0x0A0A0A, 0xFFFFFF).withAlphaComponent(0.08)
    /// 轨道底色（进度条、环的未填充部分）。
    static let track = dynamic(0x0A0A0A, 0xFFFFFF).withAlphaComponent(0.10)
    /// **文案**：caption 标签、单位、环内切口标签、存储标题。
    ///
    /// 浅色下是**纯黑**（用户要求，与参考图 CPU-X 一致）；深色下换近白 ——
    /// 纯黑在深色背景上根本看不见。
    ///
    /// **别拿它去染读数。** 数值有自己的语义色：CPU / RAM / 存储走 `loadTint`、
    /// 电芯温度走 `TodayStyle.temperature`、功率走 `battery` —— 这些是「29°C 是绿、
    /// 95% 是红」那套信息，一旦被刷成纯黑，读数与标签就分不出主次了。
    /// 用户的原话：「纯黑只改文案颜色」。
    static let text = dynamic(0x000000, 0xFFFFFF)

    // 双圆环的两条环色。
    //
    // **不用 `loadTint`**：那个是「占用越高越红」的三段变色，适合单条进度条；而双环
    // 是**两个不同的量**并排显示，各用各的固定色才能一眼分清哪圈是 CPU、哪圈是 RAM。
    // 会变色的话，某个瞬间两圈都变红，就分不出谁是谁了。
    /// 外环：CPU。
    ///
    /// **与主程序功率圆环的外环同色**（用户 0.0.54 要求）：那边外弧走
    /// `PowerSegment.glow(for: .draw, …)`，正常插电、非无线、不降频时返回 **`.mwAccent`**
    /// （`Theme.swift` 里是 `0x0086B3 / 0x35DFFF`）—— 与本文件的 `accent` 同值。
    /// 所以这里**直接复用 `accent` 而不是再抄一遍色值**：功率环的 tint 本来就出自同一个
    /// 数，两边共用一处来源，以后谁改了另一个不会悄悄留在原地（原来这里是 `0x1F7AE0`
    /// 的纯蓝，与功率环的青色放在一起能看出不是一个调）。
    ///
    /// ⚠ 对齐的是**颜色**，不是效果：主程序那边外弧还套了 `Theme.gradient`
    /// （左上 55% 透明 → 右下实色）与一层同色光晕，负一屏是纯色、无光晕。
    static let cpuRing = accent
    /// 内环：RAM。
    static let ramRing = dynamic(0x4E9A06, 0x8BD44A)

    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 14

    // 温度色阶，与 `Theme.swift` 一致：28 °C 以下冷蓝，44 °C 以上转红。
    // 写成常量而不是在 switch 里现调 `dynamic` —— 动态 `UIColor` 按身份比较，
    // 每次新建都不相等，会让每秒一次的刷新产生无谓的重绘。
    private static let cold = dynamic(0x2C7BE5, 0x4DA3FF)
    private static let cool = dynamic(0x0E9B57, 0x3FE08C)
    private static let warm = dynamic(0xB08900, 0xF2D14B)
    private static let hot = dynamic(0xB86A00, 0xFFA340)
    private static let veryHot = dynamic(0xC5342B, 0xFF6058)

    static func temperature(_ celsius: Double) -> UIColor {
        switch celsius {
        case ..<28: return cold
        case ..<34: return cool
        case ..<39: return warm
        case ..<44: return hot
        default: return veryHot
        }
    }

    /// 负载色：**内存占用率**读数用。
    ///
    /// 三段而不是连续渐变 —— 读数每秒都在动，连续渐变换色只会让人觉得整屏在闪；
    /// 三段的话只有跨过阈值那一下才变色，那一下恰好是需要被注意到的。
    ///
    /// **低档用 `ramRing`，也就是内环色**（用户 0.0.54 要求「内存占用率低占用时的颜色
    /// 跟内环颜色一致」）。原来低档用的是 `battery`（`0x0E9B57` 青绿），而内环是
    /// `ramRing`（`0x4E9A06` 黄绿）—— 两个绿摆在一起能看出不是一个调，而**低占用是
    /// 绝大多数时候的状态**，所以那点差别一直挂在屏幕上。
    /// 中档起才转橙、红：那时「量高」比「属于哪一圈」更该被看到。
    ///
    /// 存储进度条走的是另一个函数 `storageTint` —— 那个看的是「剩余」而不是「占用」，
    /// 方向相反。
    static func loadTint(_ fraction: Double) -> UIColor {
        switch fraction {
        case ..<0.70: return ramRing
        case ..<0.90: return loss
        default: return danger
        }
    }

    /// 存储条的颜色。
    ///
    /// 与 `loadTint` 的方向相反：那边是「占用越高越红」，这里是「**剩余**越少越红」——
    /// 该被注意的是还剩多少，不是已经用了多少。所以阈值按剩余比例算，20% 是 iOS
    /// 自己提示「存储空间不足」时常用的那道线。
    static func storageTint(freeFraction: Double) -> UIColor {
        freeFraction > 0.20 ? battery : danger
    }
}

nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// 负一屏的字体。
///
/// 与 `AppFont` 同样的取舍：中文下不请求圆体 —— SF Rounded 只有拉丁字形，汉字会掉回
/// 苹方 SC，同一行里字重与基线都对不齐。语言跟随系统（扩展读不到主 App 的
/// `UserDefaults`，见 `TodayViewController.viewDidLoad`）。
nonisolated enum TodayFont {

    /// 正文、标题、标签。**与主程序 `AppFont.text` 同构**：系统字体，中文下走
    /// SF Pro + 苹方 SC 那条字形链（不请求 `.rounded`），英文界面才切圆体。
    static func text(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard AppLanguage.current.prefersRoundedDesign,
              let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// 读数：**系统字体 + 等宽数字**，对应主程序的 `mwReadout`。
    ///
    /// `mwReadout` = `AppFont.text(...)` + `.monospacedDigit()`；UIKit 里的等价构造
    /// 就是 `monospacedDigitSystemFont` —— 字形仍走 SF Pro / 苹方，只把数字换成等宽
    /// 变体，所以每秒刷新时数字宽度不跳。
    ///
    /// **这是原来那个 `mono(_:)` 改的名。** 旧名字与主程序的 `AppFont.mono`（真等宽）
    /// 撞名却是两回事，读代码的人极易用错 —— 拿真等宽去排读数，读数会变成代码字体的
    /// 样子，而这正是两边字体"看着不是一个调"的常见来源。
    static func readout(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// **真等宽（SF Mono）**，对应主程序的 `AppFont.mono` / `mwMono`。
    ///
    /// 只用在**纯数字或西文**的短行上（负一屏目前只有环内那行 `1.2GB`）——
    /// SF Mono 没有中文字形，汉字会掉回苹方、与同一行的西文对不齐。
    static func mono(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// 微标签的字距。汉字没有大小写概念，也不需要拉丁那套字距。
    static var captionTracking: CGFloat { AppLanguage.current.prefersRoundedDesign ? 0.9 : 0.3 }
    static var captionUppercases: Bool { AppLanguage.current.prefersRoundedDesign }
}
