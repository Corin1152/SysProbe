import SwiftUI

/// 分段控件：一排等宽选项，选中项带高亮底板，点哪格切哪格。
///
/// ── 为什么不再用 `Picker(.segmented)`（2026-10-14 重写）───────────────────────
///
/// 两条都是实机反馈出来的，而且互相关联：
///
/// 1. **切换会失败。** 用户报的症状是「点击后滑块闪一下就弹回，内容没变」——
///    这正是系统控件最坏的行为路径：它的选中态由 SwiftUI 与 UIKit **双向同步**，
///    点击写进 `@State` 之后，紧跟其后的那一次外壳重算（`PageHubScaffold` 的
///    `header()` 每次都会重新求值）会把 `UISegmentedControl` 重置回布局时的旧值。
///    这里改成「命中哪一格就写哪一个值，**没有第二步同步**」—— 弹回这条路径
///    整体消失。上一版用 `.id(page)` 修过一次，那只是让内容一定跟着换，管不到
///    控件本身被重置。
/// 2. **高度改不了。** 系统分段控件的高度由 iOS 定死，而用户要「加大一些、别误触」
///    就只有自绘一条路。这里的命中高度是显式常量（`hitHeight`，38 pt）。
///
/// 视觉沿用设计稿里那一版：外框 9 pt 圆角的浅灰槽、选中项 7 pt 圆角的卡片底加一层
/// 淡阴影、13 pt 字；字号与命中高度是显式常量，改这里比改系统控件有处可改。
struct SegmentedTabs<Item: Hashable>: View {

    /// 全部选项，顺序即显示顺序。
    let items: [Item]

    /// 当前选中项。由调用方持有的 `@State` 绑进来。
    @Binding var selection: Item

    /// 每一项的标签。返回 `LocalizedStringKey` 而不是 `String` —— 这样 `Text` 走的
    /// 是本地化那条路（环境 locale 决定译文），与页面上其余文案一致。
    let title: (Item) -> LocalizedStringKey

    /// 滑块的动画命名空间。**一个控件一份，不要跨视图共享** ——
    /// `matchedGeometryEffect` 按 id 配对，两个控件共用一个空间时会互相抢滑块。
    @Namespace private var thumb

    /// 命中高度。
    ///
    /// 38 pt：系统分段控件大约 28 pt，用户反馈过「有点小、会误触」。这项里真正
    /// 需要点中的是文字那一行，这里给整格都铺满命中区域（`contentShape`）。
    private let hitHeight: CGFloat = 38

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                Button {
                    // 显式提交：命中哪一格就写哪一个值，**没有第二步同步**。
                    // 见类型头第 1 条 —— 这就是「滑块不再弹回」的全部依据。
                    //
                    // `withAnimation` 让选中态与滑块同步动起来；不包的话滑块会瞬移。
                    withAnimation(.easeOut(duration: 0.16)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(AppFont.text(13, weight: isSelected(item) ? .semibold : .regular))
                        .foregroundStyle(isSelected(item) ? Color.mwAccent : Color.mwMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: hitHeight)
                        // 整格都是命中区域，而不是文字那一小块。
                        .contentShape(Rectangle())
                        .background(thumb(for: item))
                }
                .buttonStyle(.plain)
                // 无障碍：念得出「这是哪一项、现在选中的是不是它」。
                .accessibilityLabel(Text(title(item)))
                .accessibilityAddTraits(isSelected(item) ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.mwMuted.opacity(0.12))
        )
    }

    private func isSelected(_ item: Item) -> Bool { item == selection }

    /// 选中项背后那块高亮。
    ///
    /// **每一格都画一块**，只是未选中的透明度为 0 —— `matchedGeometryEffect` 不能
    /// 跨越「出现 / 消失」做动画，两边都在（一块透明）它才会把旧位置那一块滑到新
    /// 位置，视觉上就是滑块过去，而不是淡入淡出。
    ///
    /// `isSource:` 指定谁是当前这一帧的动画源：只有选中项是。
    @ViewBuilder
    private func thumb(for item: Item) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.mwCard)
            // 用中性色而不是纯黑：深色模式下卡片是亮的，黑阴影等于没有。
            .shadow(color: Color.mwMuted.opacity(0.16), radius: 3, x: 0, y: 1)
            .opacity(isSelected(item) ? 1 : 0)
            .matchedGeometryEffect(id: "tab-thumb", in: thumb, isSource: isSelected(item))
    }
}
