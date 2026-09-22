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
    static let muted = dynamic(0x60687A, 0x8C93A6)
    static let card = dynamic(0xFFFFFF, 0x14171F)
    static let stroke = dynamic(0x0A0A0A, 0xFFFFFF).withAlphaComponent(0.08)
    /// 轨道底色（进度条、环的未填充部分）。
    static let track = dynamic(0x0A0A0A, 0xFFFFFF).withAlphaComponent(0.10)

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

    /// 负载色：CPU / 内存的占用率用。
    ///
    /// 三段而不是连续渐变 —— 读数每秒都在动，连续渐变换色只会让人觉得整屏在闪；
    /// 三段的话只有跨过阈值那一下才变色，那一下恰好是需要被注意到的。
    static func loadTint(_ fraction: Double) -> UIColor {
        switch fraction {
        case ..<0.70: return battery
        case ..<0.90: return loss
        default: return danger
        }
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

    static func text(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard AppLanguage.current.prefersRoundedDesign,
              let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// 等宽数字。读数用它，免得每秒刷新时数字宽度跳动。
    static func mono(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// 微标签的字距。汉字没有大小写概念，也不需要拉丁那套字距。
    static var captionTracking: CGFloat { AppLanguage.current.prefersRoundedDesign ? 0.9 : 0.3 }
    static var captionUppercases: Bool { AppLanguage.current.prefersRoundedDesign }
}
