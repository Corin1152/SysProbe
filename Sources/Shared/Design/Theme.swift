import SwiftUI
import UIKit

/// The palette. Every colour is defined for both appearances and resolved by the
/// system, so the whole app follows light/dark without a single `colorScheme` check
/// in a view body.
///
/// `nonisolated` is load-bearing, not tidiness. The project defaults to main-actor
/// isolation, which made the `UIColor` trait-resolution closure below main-actor
/// isolated too — and UIKit calls that closure from whatever thread is resolving a
/// dynamic colour during rendering. Under Swift 6 the compiler inserts an executor
/// check there, so the app trapped on the first frame that painted a gradient.
nonisolated extension Color {
    static func mw(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Page background, bottom of the canvas gradient.
    static let mwCanvas = Color.mw(0xEEF1F6, 0x06070A)
    /// Page background, top of the canvas gradient — a cool cast, so the screen
    /// reads as an instrument rather than a form.
    static let mwCanvasTop = Color.mw(0xF7F9FC, 0x0C1018)
    static let mwCard = Color.mw(0xFFFFFF, 0x14171F)
    static let mwCardStroke = Color.mw(0x0A0A0A, 0xFFFFFF).opacity(0.08)
    static let mwGrid = Color.mw(0x2B3A55, 0x6C8CC7).opacity(0.10)

    /// Adapter side: what arrives from the charger.
    static let mwAccent = Color.mw(0x0086B3, 0x35DFFF)
    /// Battery side: what actually reaches the cell.
    static let mwBattery = Color.mw(0x0E9B57, 0x3FE08C)
    /// Energy lost as heat.
    static let mwLoss = Color.mw(0xB86A00, 0xFFB443)
    static let mwDanger = Color.mw(0xC5342B, 0xFF6058)
    /// Wireless / MagSafe.
    static let mwWireless = Color.mw(0x6B4EE6, 0xB49BFF)
    static let mwMuted = Color.mw(0x60687A, 0x8C93A6)

    // The five steps of the temperature scale, as constants rather than as calls
    // to `mw` inside the switch below.
    //
    // This is load-bearing, not tidiness. `mw` builds a *new* `UIColor` with a
    // trait-resolution closure on every call, and a dynamic `UIColor` compares by
    // identity — two of them built from the same two hex values are not equal. So
    // a `Color` produced by calling `mw` in a view body was a different value on
    // every evaluation even when the temperature had not moved, which defeated
    // SwiftUI's equality checks: the heat map's blurred blend layer recomposited
    // every second for a number that had not changed. Resolving each step once
    // fixes both the per-frame allocation and the false inequality.
    private static let mwTemperatureSteps = (
        cold: Color.mw(0x2C7BE5, 0x4DA3FF),
        cool: Color.mw(0x0E9B57, 0x3FE08C),
        warm: Color.mw(0xB08900, 0xF2D14B),
        hot: Color.mw(0xB86A00, 0xFFA340),
        veryHot: Color.mw(0xC5342B, 0xFF6058)
    )

    /// Temperature scale used by the heat map and every temperature bar.
    /// Cool blue below 28 °C through to red at 44 °C and above.
    static func mwTemperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<28: return mwTemperatureSteps.cold
        case ..<34: return mwTemperatureSteps.cool
        case ..<39: return mwTemperatureSteps.warm
        case ..<44: return mwTemperatureSteps.hot
        default: return mwTemperatureSteps.veryHot
        }
    }

    static func mwPower(_ watts: Double) -> Color {
        watts >= 18 ? .mwAccent : (watts >= 7.5 ? .mwBattery : .mwMuted)
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

nonisolated enum Theme {
    static let cardRadius: CGFloat = 18
    static let cardPadding: CGFloat = 16

    static func gradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.55), color],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }
}

/// 字体。全 App 的字形都从这里出，语言一换就整体跟着换。
///
/// 中文下刻意**不**请求 `.rounded`：iOS 的 SF Rounded 只有拉丁字形，汉字会掉回苹方 SC，
/// 结果是同一行里数字圆润、汉字方正，字重与基线也对不齐。改用系统默认设计后，拉丁走
/// SF Pro、汉字走苹方 SC —— 这是 Apple 自己配好的一条字形链，中英混排才是一套字。
///
/// 字距同理：拉丁全大写配字距是仪表面板的味道，汉字加同样的字距只会显得散。
nonisolated enum AppFont {

    /// 正文、标题、读数。中文下退回系统默认设计。
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size,
                    weight: weight,
                    design: AppLanguage.current.prefersRoundedDesign ? .rounded : .default)
    }

    /// 等宽。这个不随语言变 —— 它管的是数字对齐，而中文下要用到等宽的地方本来就只有数字。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    /// 微标签的字距。
    static var captionTracking: CGFloat {
        AppLanguage.current.prefersRoundedDesign ? 0.9 : 0.3
    }

    /// 微标签是否转大写。汉字没有大小写，转了也白转。
    static var captionUppercases: Bool {
        AppLanguage.current.prefersRoundedDesign
    }
}

extension View {
    /// The uppercase, tracked micro-label used above every readout.
    func mwCaption() -> some View {
        font(AppFont.text(11, weight: .semibold))
            .textCase(AppFont.captionUppercases ? Text.Case.uppercase : nil)
            .tracking(AppFont.captionTracking)
            .foregroundStyle(Color.mwMuted)
    }

    /// A large tabular readout. Monospaced digits so the number stops jittering
    /// while it updates once a second.
    ///
    /// `rolling` opts into the digit-roll transition. It is off by default: with a
    /// one-second tick, every readout on screen animating every character every
    /// second is both restless to look at and a steady render cost for nothing.
    /// The hero number on the dial turns it on; the rest snap.
    func mwReadout(size: CGFloat, weight: Font.Weight = .semibold, rolling: Bool = false) -> some View {
        font(AppFont.text(size, weight: weight))
            .monospacedDigit()
            .contentTransition(rolling ? .numericText() : .identity)
    }

    func mwMono(size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        font(AppFont.mono(size, weight: weight))
    }
}

// MARK: iOS 16 compatibility helpers

extension View {
    /// Pins scroll content to the container's width.
    ///
    /// iOS 17 introduced `containerRelativeFrame` for this; on iOS 16 the best
    /// available equivalent is an infinite-max-width frame. It expands but cannot
    /// clamp, so pathologically wide intrinsic content (a long unbroken word in a
    /// panel) could still overflow horizontally — every user of this modifier is a
    /// column of wrapping text, which sizes to the proposed width on its own, so in
    /// practice the pages lay out the same.
    /// 设置面板的容器底色。
    ///
    /// `presentationBackground` 是 iOS 16.4 才有的。不设的话，面板容器用的是系统背景
    /// 材质，弹入的第一帧露出来的是它，与画布差一截。16.2 / 16.3 上退回原样 —— 面板内部
    /// 压的那层 `Color.mwCanvas` 已经兜住了内容区，差的是最外层那一帧。
    @ViewBuilder
    func mwSheetBackground() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(Color.mwCanvas)
        } else {
            self
        }
    }

    @ViewBuilder
    func mwContainerWidth() -> some View {
        if #available(iOS 17.0, *) {
            // 注意：这里一度写成了 `self.mwContainerWidth()`，也就是调用自己 ——
            // 编译器只给一句 "function call causes an infinite recursion" 警告，
            // 真跑到 iOS 17 上会直接栈溢出。必须是 `containerRelativeFrame`。
            self.containerRelativeFrame(.horizontal)
        } else {
            self.frame(maxWidth: .infinity)
        }
    }
}
