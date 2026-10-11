import SwiftUI

/// 「维护」分页的分段 1 —— 维护。原来是齿轮菜单里的第一页。
///
/// 内容：两个破坏性动作（重启设备 / 注销）、关闭温控降频、网络唤醒、语言切换。
/// 诊断区在「关于」页（2026-10-02 迁走）：这一页只该剩真正「动手改系统」的东西，
/// 诊断放回关于更符合它的信息属性。
///
/// 2026-10-11 起它不再自己撑一页：画布、光晕、导航栈、标题全部由
/// `MaintenanceHubView` 提供，这里只剩 `Form`。**`Form` 自己就是滚动容器** ——
/// 所以这一层绝不能套进任何 `ScrollView`（`PageScaffold` 正是那种）。嵌套滚动的
/// 症状是「这一页滑不动」，而且不报任何错；外壳那边用的是 `PageHubScaffold`，
/// 存在的唯一理由就是避开这件事。
struct MaintenancePanels: View {
    @EnvironmentObject private var app: AppState

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

    // ── 关闭温控降频 ────────────────────────────────────────────────────────

    /// `disabled.plist` 里 `com.apple.thermalmonitord` 的状态。`true` = 已配置为禁用。
    ///
    /// 注意这是**配置**状态，不是运行状态：改完要重启才真的生效。
    @State private var thermalDisabled = false

    /// 配置读不出来（工具不在包里 / 拿不到 root）。此时整行禁用。
    ///
    /// 与 `thermalDisabled == false` 分开存是必需的：合并的话，一个坏掉的工具
    /// 会显示成一个看起来正常、拨了却没反应的开关。
    @State private var thermalUnavailable = false

    /// 已经改过配置、还没重启。用来把「重启后生效」那一行显示出来。
    @State private var thermalNeedsRestart = false

    /// 正在写配置（起子进程并等它结束）。
    @State private var thermalBusy = false

    /// 待确认「开启」。开启有真实副作用，必须先说清楚。
    @State private var confirmThermalEnable = false

    /// 写入失败。**用行内提示而不是弹窗** —— 外层的 `confirmationDialog` 已经
    /// 给了重启 / 注销那两个动作，同一个视图上再叠一个弹窗会互相抢呈现。
    @State private var thermalFailed = false

    var body: some View {
        Form {
            maintenanceSection

            performanceSection

            WakeSection()

            Section {
                Picker("Language", selection: $app.language) {
                    // 语言名一律用该语言自己的写法，且不参与翻译 —— 把「简体中文」
                    // 翻成 "Simplified Chinese" 之后，只会中文的人反而找不到它。
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.endonym).tag(language)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Language")
            } footer: {
                Text("Applies to the whole app straight away. The Today widget follows the system language instead — it runs in its own process and cannot read this setting.")
            }
        }
        .scrollContentBackground(.hidden)
        // 自检要起一个子进程并等它结束（毫秒级，但最长会等到 1 秒），
        // 所以放到主 actor 之外跑。
        .task {
            toolReady = await Task.detached { DeviceActions.probe() }.value

            // 配置状态要**另外读一次**：`probe()` 只回答「子进程拿不拿得到 root」，
            // 不回答「温控那个键在不在」。两者失败时界面表现一样（都不可用），
            // 但能读的时候必须读出来。
            let state = await Task.detached { DeviceActions.thermalState() }.value
            switch state {
            case .disabled: thermalDisabled = true
            case .enabled: thermalDisabled = false
            case .unknown: thermalUnavailable = true
            }
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

    /// 最上面那一区：两个破坏性动作并排。
    ///
    /// 位置在**最上方**，是明确要求的结果 —— 代价要说清楚：破坏性操作放在最容易
    /// 顺手点到的地方，误触概率比埋在下面高。所以这一区的安全性全部压在另外两件事上，
    /// 改动这里时别把它们去掉：
    ///
    ///   1. 每个动作都要过二次确认（`confirmationDialog`），且弹窗里写全动作名，
    ///      不是「确定 / 取消」；
    ///   2. 工具不可用时整区禁用 + 变淡，不给一个点了没反应的按钮。
    ///
    /// 这一区**刻意不带 footer**：按钮本身就是全部内容，下面再挂一段说明只会把
    /// 两个按钮往下推、把第一屏让给解释文字。工具不可用的原因走诊断区的
    /// **Root tool** 一行，点击后的失败走 alert。
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

    // MARK: 性能

    /// 「性能」区：关闭温控降频。
    ///
    /// 这一区做的是**改系统文件**（launchd 的 `disabled.plist`），所以它的安全性
    /// 压在四件事上，改这里时别去掉：
    ///
    ///   1. 开启前必须过二次确认，且弹窗里把代价写全（电池健康度读不出来、
    ///      失去过热保护），不是「确定 / 取消」；
    ///   2. 配置读不出来时整行禁用 —— 不给一个拨了没反应的开关；
    ///   3. 明确写出**需要重启**，并在改完之后把「重启以生效」摆出来；
    ///   4. 工具自己会在首次写入前备份原文件（见 `Tools/RootTool.c`），
    ///      所以这里可以承诺「随时可以关回去」。
    ///
    /// 这一区**刻意不做成「一键加速」**：它只对**热**引起的降频有用，
    /// 对电池老化引起的峰值性能限制完全无效。页脚那句话就是为此写的。
    private var performanceSection: some View {
        Section {
            Toggle(isOn: thermalBinding) {
                Text("Disable thermal throttling")
            }
            .disabled(toolReady != true || thermalUnavailable || thermalBusy)
            // 挂在 `Toggle` 上而不是外层 `ZStack`：外层已经挂了一个
            // `confirmationDialog`（重启 / 注销），同一个视图上叠两个会互相抢呈现。
            .confirmationDialog(
                Text("Disable thermal throttling?"),
                isPresented: $confirmThermalEnable,
                titleVisibility: .visible
            ) {
                Button("Turn Off", role: .destructive) {
                    Task { await applyThermal(disabled: true) }
                }
                Button("Cancel", role: .cancel) {
                    // 回滚乐观置位 —— 取消之后开关必须回到原来的位置。
                    thermalDisabled = false
                }
            } message: {
                Text(verbatim: Strings.text("Disable thermal throttling warning"))
            }

            if thermalNeedsRestart {
                Button {
                    // 走与「重启设备」同一个确认流程，不另开一条路径。
                    request(.reboot)
                } label: {
                    Label("Restart to apply", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Performance")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stops the thermalmonitord daemon so iOS stops lowering the CPU clock in response to heat. Takes effect after a restart.")
                // 失败时在这里说 —— 见上面 `thermalFailed` 的说明。
                if thermalFailed {
                    Text("Could not change the thermal setting.")
                        .foregroundStyle(Color.mwDanger)
                }
            }
        }
    }

    /// 开关的绑定。
    ///
    /// setter **不直接落状态**：开启有真实副作用，要先弹确认。这里乐观置位是为了
    /// 让开关立刻跟手 —— 取消那条路会把 `thermalDisabled` 改回去。
    private var thermalBinding: Binding<Bool> {
        Binding(
            get: { thermalDisabled },
            set: { newValue in
                guard newValue != thermalDisabled else { return }
                if newValue {
                    thermalDisabled = true
                    confirmThermalEnable = true
                } else {
                    Task { await applyThermal(disabled: false) }
                }
            }
        )
    }

    /// 真的去写配置。
    ///
    /// 子进程要跑起来并等它结束（毫秒级，最长约 1 秒），所以放到主 actor 之外 ——
    /// 与 `probe()` 同样的理由。
    private func applyThermal(disabled: Bool) async {
        guard !thermalBusy else { return }
        thermalBusy = true
        thermalFailed = false

        let ok = await Task.detached { DeviceActions.setThermalDisabled(disabled) }.value

        thermalBusy = false
        if ok {
            thermalDisabled = disabled
            // 写成功也**不等于**已经生效 —— 要重启。
            thermalNeedsRestart = true
        } else {
            // 回滚，别让开关停在一个假的「已开启」上。
            thermalDisabled = !disabled
            thermalFailed = true
        }
    }

    // 诊断区已迁到「关于」页。工具状态的文案在 `DeviceActions.toolSummary(ready:)`，
    // 两个页面（关于 / 清理）共用它 —— 这里不再留一份。

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
            // 宽度靠 `maxWidth: .infinity` 撑满半个行，**只压高度**：
            // 纵向内边距 14 → 8、图标 18 → 16、行间距 6 → 4。
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
