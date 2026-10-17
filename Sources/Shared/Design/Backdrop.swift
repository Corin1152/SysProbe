import SwiftUI

/// The page background. **A flat fill since 2026-10-17** — it used to be a cool
/// vertical wash with a faint measurement grid and a single soft glow behind the
/// content, which is what made the screens read as instrument panels.
///
/// 用户要求「去掉主程序的网格背景，改为纯白色」：渐变、28 pt 网格、`plusLighter`
/// 的径向发光三样一起删掉了，只剩 `Color.mwCanvas`（浅色纯白 / 深色近黑）。
/// 结果是整屏只剩卡片与它的 1 pt 描边 —— 卡片之间靠描边和 4 pt 间隙分层，
/// 不再有底色差。卡片自己的填充色（`mwCard`）不变。
///
/// ── 参数为什么还留着 ────────────────────────────────────────────────────────
///
/// `glow` / `glowIntensity` 现在**不参与绘制**。保留而不是删掉，是因为调用点散在
/// `PageScaffold`、`AboutView`、`MaintenanceSheet` 三处，而 `PageScaffold.glow`
/// 又是页面自己的一项属性（电源页按插电／无线／降频传不同的色）。哪天要恢复
/// 那层发光，改这一个 body 就行，不用顺着五处签名往回改。
///
/// ── 为什么是 `Equatable`（2026-10-14）──────────────────────────────────────
///
/// 从前这一层是整屏 `Canvas`：一次绘制铺两遍渐变、画约 400 条网格线、再叠一层
/// 径向发光，而它挂在每个分页的 `ZStack` 里，父视图 body 一重算它就跟着重新求值。
/// 标 `Equatable` 并让调用处接 `.equatable()`，值没变就能跳过整个 body。
///
/// 现在是纯色，重算也不贵了；但 `.equatable()` 的调用点照旧成立，保持原样 ——
/// 它省的是「整屏一层的求值」，纯色也一样受益。
struct Backdrop: View, Equatable {
    var glow: Color = .mwAccent
    var glowIntensity: Double = 1

    var body: some View {
        Color.mwCanvas.ignoresSafeArea()
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
    /// 折叠开关。`nil`（默认）= 这张卡片不可折叠，行为与以前完全一样。
    ///
    /// ── 2026-10-15 新增 ────────────────────────────────────────────────────
    ///
    /// 给了 `Binding` 之后，**整行标题变成开合按钮**，标题左侧多一个会转 90° 的
    /// 小三角 —— 与频段页的 4G 卡片（`BandPanels.bandPanel`）、进程页的分组标题
    /// （`ProcessPanels.groupHeader`）是同一个手法，读的人一眼能连上。
    ///
    /// 做成 `Panel` 的参数而不是在调用点自绘卡片：这几处折叠卡片的外壳完全一样
    /// （`Theme.cardPadding` + `Color.mwCard` + `strokeBorder`），复制一份的话
    /// 圆角、描边、内边距迟早会长歪。
    var expanded: Binding<Bool>?
    /// 内边距。默认 `Theme.cardPadding` —— 只有**需要单独收一点**的卡片才传
    /// （2026-10-17 电源页首卡：按要求「卡片缩小一点」，只动它一张）。
    ///
    /// 不做成「整站统一调小」：卡片的呼吸感靠的就是这个数，压全局会让所有页
    /// 一起变挤，而用户要的是那一张。
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey? = nil,
         systemImage: String? = nil,
         trailing: Text? = nil,
         expanded: Binding<Bool>? = nil,
         padding: CGFloat = Theme.cardPadding,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.expanded = expanded
        self.padding = padding
        self.content = content
    }

    var body: some View {
        // ── 2026-10-16：标题与内容之间 12 → 10（压卡片高度）─────────────────
        //
        // 这个 `spacing` 作用在**这一层的直接子视图**上：无标题的卡片只有一个内容
        // 视图，收它不产生任何效果；有标题的卡片是「标题行 + 内容」两个子视图，
        // 收它等于每张带标题的卡片再矮 2 pt。与 `Theme.cardPadding` 16 → 14
        // （上下各 2）叠起来，一张带标题的卡片总共矮 6 pt。
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                if let expanded {
                    Button {
                        expanded.wrappedValue.toggle()
                    } label: {
                        header(isExpanded: expanded.wrappedValue, collapsible: true)
                    }
                    // `.plain`：标题不是「一行里的一个动作」，它是这一整块的开合
                    // 开关，不该带按钮的高亮底色。
                    .buttonStyle(.plain)
                } else {
                    header(isExpanded: true, collapsible: false)
                }
            }
            // `nil` 当展开处理：不可折叠的卡片内容永远画。
            if expanded?.wrappedValue ?? true {
                content()
            }
        }
        .padding(padding)
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

    /// 标题行。可折叠时整行都是命中区域（`.contentShape`）—— 这一行除了文字
    /// 没有别的东西，而手指按得中比看得清更难。
    private func header(isExpanded: Bool, collapsible: Bool) -> some View {
        HStack(spacing: 6) {
            if collapsible {
                Image(systemName: "chevron.right")
                    .font(AppFont.text(11, weight: .bold))
                    .foregroundStyle(Color.mwAccent)
                    // 90° 而不是换成另一个符号：同一个图形转过去，读的人一眼能连上
                    // 是「同一个东西换了姿态」。
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
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
        .contentShape(Rectangle())
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
                    // 读数永远不换行。设备卡片把「机型 / 系统 / 内核」并成一行之后，
                    // 每格只剩约 100 pt —— `iPhone17,2` 在 16 pt 下刚好压线，
                    // 换个长一点的机型就会折成两行，而那一格一折，整张卡片就长一截。
                    // 缩到 0.7 还放不下才截断，比换行诚实。
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
