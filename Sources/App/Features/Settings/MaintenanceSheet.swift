import SwiftUI

/// 齿轮下拉菜单的第一项 —— 「维护」。
///
/// ── 2026-10-15：从底部分页搬进齿轮 ──────────────────────────────────────────
///
/// 它原来是底部分页栏第 3 格「维护」页里的第一个分段。页码收成四格
/// （硬件 / 电源 / 频段 / 进程）之后，这一页剩下的两样东西没有别处可去，收进齿轮。
///
/// 原来那一页的三块内容这次**按「它改的是哪一类东西」拆开**，而不是按它原来在
/// 哪一张卡片里：
///
///   · **改系统状态的**（重启设备 / 注销 / 网络唤醒）→ 留在这里；
///   · **动充电行为的**（关闭温控降频）→ 电源页「基础」卡片末尾；
///   · **动磁盘的**（清理）→ 硬件页存储卡片里。
///
/// 用户找这些东西时会先想「我要改的是充电还是存储」，而不是「它原来在第几页」。
///
/// ── 安全性没有因为搬家而放松 ────────────────────────────────────────────────
///
/// 两个破坏性动作仍然要过二次确认（`confirmationDialog`），弹窗标题与说明都写全
/// 动作名，不是「确定 / 取消」；工具不可用时整区禁用 + 变淡，不给一个点了没反应的
/// 按钮。这两条是原来那一页的全部安全措施，改这里时别去掉。
///
/// 位置从「分页里最上面那一区」变成「齿轮里的一层」，误触概率反而降了 ——
/// 原来那两个按钮就摆在分页第一屏，现在要多点两下才够得着。
struct MaintenanceSheet: View {

    /// 作为弹层出现时的关闭动作。
    @Environment(\.dismiss) private var dismiss

    /// 正在等确认的动作。`nil` 表示没有待确认的操作。
    ///
    /// 用一个弹窗而不是每个按钮各挂一个：标题与说明都要按动作拼，
    /// 两份状态容易在快速连点时错位。
    @State private var pendingAction: DeviceAction?
    @State private var isConfirming = false

    /// 特权工具能不能用。`nil` = 还没测出来（面板刚打开的头几十毫秒）。
    ///
    /// **不是「文件在不在」那种静态判断**：权限不足时工具会静默失败 ——
    /// 界面照常、点下去什么都不发生。所以这里真去跑一次自检，见 `DeviceActions.probe()`。
    @State private var toolReady: Bool?

    /// 连 `posix_spawn` 都没成功（工具被删了、包不完整）。要说话 ——
    /// 这两个动作最大的失败模式就是「什么都没发生」。
    @State private var actionFailed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mwCanvas
                // `.equatable()`：整屏 `Canvas`，父 body 重算时不重画。见 `Backdrop`。
                Backdrop(glow: .mwAccent).equatable()
                Form {
                    maintenanceSection
                    WakeSection()
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Maintenance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(.mwAccent)
                }
            }
        }
        // 自检要起一个子进程并等它结束（毫秒级，但最长会等到 1 秒），
        // 所以放到主 actor 之外跑 —— 与 `AboutView` 同一句话，同一个理由。
        .task {
            toolReady = await Task.detached { DeviceActions.probe() }.value
        }
        .confirmationDialog(
            Text(verbatim: confirmTitle),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                // `destructive` 让它在弹窗里显示成红色 —— 这两个动作都不可撤销。
                Button(action.title, role: .destructive) { perform(action) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text(verbatim: pendingAction?.warning ?? "")
        }
        .alert("Could not start the helper.", isPresented: $actionFailed) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("The privileged helper is missing from this build, or could not obtain root. Run scripts/build-ipa.sh to bundle it.")
        }
    }

    // MARK: 维护

    /// 两个破坏性动作并排。
    ///
    /// 这一区**刻意不带 footer**：按钮本身就是全部内容，下面再挂一段说明只会把
    /// 两个按钮往下推。工具不可用的原因走关于页诊断区的 **Root tool** 一行，
    /// 点击后的失败走 alert。
    private var maintenanceSection: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(DeviceAction.allCases) { action in
                    DeviceActionButton(action: action) { request(action) }
                }
            }
            // **这个修饰符是必需的，不是装饰。**
            //
            // `Form`/`List` 的一行里放多个按钮时，默认（automatic）样式会把整行当成
            // 一个点击区域：点哪儿都会把行内**所有**按钮一起触发 —— 也就是点「注销」
            // 会连带触发「重启设备」。`.borderless` 让每个按钮各自持有自己的命中区域，
            // 这也是 Apple 文档里对这个场景给的答案。
            .buttonStyle(.borderless)
            .disabled(toolReady == false)
            .opacity(toolReady == false ? 0.4 : 1)
        } header: {
            Text("Maintenance")
        }
    }

    // MARK: 确认弹窗

    private var confirmTitle: String {
        guard let action = pendingAction else { return "" }
        return Strings.text("Are you sure you want to %@?", action.title)
    }

    /// 记下要确认的动作并弹窗。**不在这里执行** —— 用户还可能取消。
    private func request(_ action: DeviceAction) {
        pendingAction = action
        isConfirming = true
    }

    /// 真的执行。
    ///
    /// 成功的话这里**不会**有下文：重启设备会让整个进程消失，注销会让本 App 被系统
    /// 收掉。所以只在 `posix_spawn` 失败时说话，成功时什么都不做 —— 也来不及做。
    private func perform(_ action: DeviceAction) {
        // 刻意**不**在这里清 `pendingAction`：弹窗还在做退出动画，标题与说明当场变空
        // 会闪一下。留着它，下一次点按钮时会被覆盖，取消那条路自己会清。
        if !DeviceActions.perform(action) {
            actionFailed = true
        }
    }
}

/// 维护区里的一个动作按钮。两个并排，各占一半宽度。
private struct DeviceActionButton: View {
    let action: DeviceAction
    /// 类型写成 `@MainActor () -> Void` 而不是 `() -> Void`：闭包体里要碰主 actor
    /// 隔离的状态，而项目默认主 actor 隔离，`() -> Void` 会在这里丢掉那个隔离域。
    let tap: @MainActor () -> Void

    var body: some View {
        // 用 `Button { tap() } label:` 而不是 `Button(action: tap)`：后者要把这个闭包
        // 直接交给 SwiftUI，会再撞一次上面那个隔离域转换的问题。
        Button {
            tap()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                Text(action.title)
                    .font(AppFont.text(13, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                    // 中文四个字、英文十来个字母，窄屏上都得待在一行里。
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.mwDanger.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.mwDanger.opacity(0.28), lineWidth: 1)
            )
            // 让整个半行都是命中区域，而不是只有图标和文字那一小块。
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
