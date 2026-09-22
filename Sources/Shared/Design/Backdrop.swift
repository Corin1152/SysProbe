import SwiftUI

/// The page background: a cool vertical wash with a faint measurement grid and a
/// single soft glow behind the content. Drawn once, cheap, and it is what makes
/// the screens read as instrument panels instead of settings pages.
struct Backdrop: View {
    var glow: Color = .mwAccent
    var glowIntensity: Double = 1

    private let spacing: CGFloat = 28

    var body: some View {
        ZStack {
            LinearGradient(colors: [.mwCanvasTop, .mwCanvas],
                           startPoint: .top,
                           endPoint: .bottom)

            Canvas { context, size in
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(.mwGrid), lineWidth: 0.5)
            }
            // 刻意**不加** `.drawingGroup()`。
            //
            // 它会把这一层渲进一张离屏纹理。而每次转场（启动第一帧、切分页、弹／收
            // 设置页）SwiftUI 都可能把那张纹理丢掉重画，中间会有一帧是空的；配上
            // 下面 `plusLighter` 的发光层在同一个合成组里，表现出来就是整屏闪一下。
            //
            // 性能上也不需要它：`Canvas` 本身已经是一层 CALayer，只有尺寸变化才会
            // 重画，那 ~50 条网格线画一次就留在层里了。

            RadialGradient(colors: [glow.opacity(0.22 * glowIntensity), .clear],
                           center: .init(x: 0.5, y: 0.18),
                           startRadius: 0,
                           endRadius: 420)
                .blendMode(.plusLighter)
                .animation(.easeInOut(duration: 0.8), value: glow)
        }
        .ignoresSafeArea()
    }
}

/// A titled panel. Everything on every screen sits in one of these.
struct Panel<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    /// Either translated copy — `Text("…")` — or a measured value that must never
    /// be looked up in the string catalog — `Text(verbatim:)`. Panels carry both:
    /// "12 sensors" is copy, an `iPhone17,2` or a `4.8 W` reading is not. Keeping
    /// this a `Text` puts that choice at the call site, where it is knowable.
    var trailing: Text?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey? = nil,
         systemImage: String? = nil,
         trailing: Text? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(AppFont.text(11, weight: .bold))
                            .foregroundStyle(Color.mwMuted)
                    }
                    if let title {
                        Text(title).mwCaption()
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        trailing
                            .mwMono(size: 11)
                            .foregroundStyle(Color.mwMuted)
                    }
                }
            }
            content()
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.mwCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwCardStroke, lineWidth: 1)
        )
    }
}

/// Caption, number, unit. The building block of every panel.
struct Metric: View {
    let caption: LocalizedStringKey
    let value: String
    var unit: String?
    var tint: Color = .primary
    /// Copy — `Text("…")` — or a hardware name that must not be translated —
    /// `Text(verbatim:)`. Both occur: one panel explains a formula, another
    /// names the sensor a reading came from.
    var footnote: Text?
    var size: CGFloat = 24

    /// A dash means the probe returned nothing, so it is drawn as absence rather
    /// than as a reading in the metric's own colour.
    private var isPlaceholder: Bool { value == "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption).mwCaption()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .mwReadout(size: isPlaceholder ? size * 0.7 : size)
                    .foregroundStyle(isPlaceholder ? Color.mwMuted.opacity(0.55) : tint)
                if let unit {
                    Text(unit)
                        .font(AppFont.text(size * 0.48, weight: .medium))
                        .foregroundStyle(Color.mwMuted)
                }
            }
            if let footnote {
                footnote
                    .font(.caption2)
                    .foregroundStyle(Color.mwMuted)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small status chip: charging state, thermal state, wireless badge.
struct Pill: View {
    /// Copy, or a formatted measurement. See `Panel.trailing`.
    let text: Text
    var systemImage: String?
    var tint: Color = .mwMuted

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(AppFont.text(10, weight: .bold))
            }
            text
                .font(AppFont.text(11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(tint.opacity(0.14))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        )
    }
}

/// A labelled horizontal bar, used for temperature zones and adapter utilisation.
struct BarRow: View {
    /// A label, or the name of the sensor this row shows.
    let title: Text
    /// Always a formatted measurement — "42.8 °C", "80%" — so never translated.
    let detail: String
    /// 0…1
    let fraction: Double
    let tint: Color
    var subtitle: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .font(AppFont.text(13, weight: .medium))
                        .lineLimit(1)
                    if let subtitle {
                        subtitle
                            .mwMono(size: 10)
                            .foregroundStyle(Color.mwMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(detail)
                    .mwReadout(size: 14, weight: .semibold)
                    .foregroundStyle(tint)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.mwMuted.opacity(0.15))
                    Capsule()
                        .fill(Theme.gradient(tint))
                        .frame(width: max(3, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 5)
        }
    }
}

/// Used wherever a probe legitimately has nothing to report.
///
/// Lives here rather than next to the app's page chrome because the charts need it
/// too, and the charts are shared with the Today extension — which does not compile
/// the app's own sources.
struct EmptyNote: View {
    let text: LocalizedStringKey
    var systemImage: String = "info.circle"

    init(text: LocalizedStringKey, systemImage: String = "info.circle") {
        self.text = text
        self.systemImage = systemImage
    }

    /// 键在运行期才知道的场合（`MemoryOptimizer.Phase.failed` 的失败原因）。
    ///
    /// 先把文案查出来再塞进 `LocalizedStringKey`，两条路径都成立：这个 `init` 若是
    /// 走了本地化查找，查的是一个查不到的中文串，回落即原文；若没走查找，原文本来
    /// 就已经是译文。不必去赌 `LocalizedStringKey(String)` 解析不解析。
    init(key: String, systemImage: String = "info.circle") {
        self.text = LocalizedStringKey(Strings.text(key))
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(AppFont.text(12, weight: .semibold))
                .foregroundStyle(Color.mwMuted)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.mwMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
