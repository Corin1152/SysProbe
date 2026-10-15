import SwiftUI

/// 「关闭温控降频」—— 电源页「基础」卡片末尾的那一块。
///
/// ── 2026-10-15：从维护页搬过来 ──────────────────────────────────────────────
///
/// 它原来在「维护」分页的「性能」区（`MaintenancePanels.performanceSection`）。
/// 那一页散架之后，三块内容按「它改的是哪一类东西」重新分配，而不是按它原来在
/// 哪一张卡片里：
///
///   · **改系统状态的**（重启设备 / 注销 / 网络唤醒）→ 齿轮 → 维护；
///   · **动充电行为的**（就是这一块）→ 电源页「基础」卡片末尾；
///   · **动磁盘的**（清理）→ 硬件页存储卡片里。
///
/// 这个开关改的是 `thermalmonitord`，而那个守护进程**降的正是充电电流** ——
/// 放在「充电控制」这张卡片里、紧挨着「智能停充」，比放在一页叫「维护」的地方
/// 更贴。用户找它时会先想「我要改的是充电」，而不是「它原来在第几页」。
///
/// ── 为什么是独立类型而不是往 `basicsPanel` 里塞 ─────────────────────────────
///
/// 它带着一整套状态：配置读回、乐观置位 + 回滚、二次确认、写失败行内提示、
/// 「重启以生效」标记（还要靠系统运行时长判断这条标记有没有兑现）。这些跟
/// 「基础」卡片里那几个 `Binding` 直连 `ChargeControlService` 的开关不是一回事，
/// 混在同一个 `VStack` 里会让那张卡片变成整页最长的一段代码。
///
/// ── 安全性没有因为搬家而放松 ────────────────────────────────────────────────
///
/// 这一块做的是**改系统文件**（launchd 的 `disabled.plist`），所以它的安全性
/// 压在四件事上，改这里时别去掉：
///
///   1. 开启前必须过二次确认，且弹窗里把代价写全（电池健康度读不出来、
///      失去过热保护），不是「确定 / 取消」；
///   2. 配置读不出来时整行禁用 —— 不给一个拨了没反应的开关；
///   3. 明确写出**需要重启**，并在改完之后把「重启以生效」摆出来；
///   4. 工具自己会在首次写入前备份原文件（见 `Tools/RootTool.c`），
///      所以这里可以承诺「随时可以关回去」。
///
/// 它**刻意不做成「一键加速」**：只对**热**引起的降频有用，对电池老化引起的
/// 峰值性能限制完全无效。下面那句说明就是为此写的。
struct ThermalThrottlePanel: View {

    // ── 关闭温控降频 ────────────────────────────────────────────────────────

    /// `disabled.plist` 里 `com.apple.thermalmonitord` 的状态。`true` = 已配置为禁用。
    ///
    /// 注意这是**配置**状态，不是运行状态：改完要重启才真的生效。
    ///
    /// ── 为什么是 `@AppStorage`（2026-10-14）──────────────────────────────────
    ///
    /// 它原来是 `@State`，于是**每次进这一页都从默认值 `false` 重新开始** ——
    /// 分页之间来回切、以及从别的分页切回来，都会让本视图重建一次。用户看到的症状是
    /// 「每次进入，开关都先从关跳到开」：真实状态是「开」（已禁用），而 `@State`
    /// 给它的是 `false`，等 `.task` 把 plist 读回来才纠正。
    ///
    /// 改成 `@AppStorage` 之后，上一次读到的真实值会一直留着：进页面第一帧就是对的，
    /// 读回来看见没变就什么都不做。**键名与它在维护页时一模一样** —— 换名字等于
    /// 把用户已经设好的值丢掉。
    @AppStorage("sysprobe.thermalDisabled") private var thermalDisabled = false

    /// 已经改过配置、**还没重启**。用来把「重启后生效」那一行显示出来。
    ///
    /// 与 `thermalDisabled` 同理：它也是「跨视图重建必须留住」的状态 ——
    /// 切走再回来就看不到「重启以生效」的提示，等于把用户刚做的改动说丢了。
    ///
    /// ── 为什么它旁边还多了一个时刻（修「重启之后提示还在」）────────────────
    ///
    /// 这条标记一旦置上，就**只有重启设备才算兑现**，而它自己不知道那件事发生过。
    /// 原来没有任何一处把它写回 `false`，于是它永远为真：用户点过一次开关，
    /// 「重启以生效」就再也不会消失，连真的重启了设备都还在。
    ///
    /// 所以写入时一并记下**那一刻的系统运行时长**（`systemUptime`）。读的时候比一比：
    /// 系统重启过的话运行时长会归零重来，必然小于记下的那个值 —— 那就是「已经兑现了」。
    /// 用运行时长而不是绝对时间戳，是因为它不依赖时钟（用户改表、换时区都不影响），
    /// 也不需要在 App 里额外记一份启动历史。
    @AppStorage("sysprobe.thermalNeedsRestart") private var thermalNeedsRestartPending = false

    /// 置上「待重启」那一刻的系统运行时长，秒。`0` = 没有这条记录。
    @AppStorage("sysprobe.thermalNeedsRestartAt") private var thermalNeedsRestartAt: Double = 0

    /// 「重启以生效」这一行该不该显示。
    ///
    /// 两个条件都成立才显示：改过配置，**而且**改完之后系统没有重启过。
    private var thermalNeedsRestart: Bool {
        guard thermalNeedsRestartPending else { return false }
        // 没有时刻记录（持久化改造之前写下的那一批数据）→ 判断不出兑现与否，
        // 当作已失效。宁可少提示一次，也不要一条永远消不掉的提示。
        guard thermalNeedsRestartAt > 0 else { return false }
        return ProcessInfo.processInfo.systemUptime >= thermalNeedsRestartAt
    }

    /// 配置读不出来（工具不在包里 / 拿不到 root）。此时整行禁用。
    ///
    /// 与 `thermalDisabled == false` 分开存是必需的：合并的话，一个坏掉的工具
    /// 会显示成一个看起来正常、拨了却没反应的开关。
    ///
    /// 它**不**跨重建保留（`@State`）：读不出来是这一次的结果，与「读出来是什么值」
    /// 不是一回事。留着上一次的失败会让一个已经好了的工具继续显示不可用。
    @State private var thermalUnavailable = false

    /// 正在写配置（起子进程并等它结束）。
    @State private var thermalBusy = false

    /// 待确认「开启」。开启有真实副作用，必须先说清楚。
    @State private var confirmThermalEnable = false

    /// 写入失败。**用行内提示而不是弹窗** —— 这一块已经挂了一个确认弹窗
    /// （`confirmThermalEnable`）和一个重启确认，同一个视图上再叠第三个会互相抢呈现。
    @State private var thermalFailed = false

    /// 特权工具能不能用。`nil` = 还没测出来（卡片刚出现的头几十毫秒）。
    ///
    /// **不是「文件在不在」那种静态判断**：权限不足时工具会静默失败 ——
    /// 界面照常、点下去什么都不发生。所以这里真去跑一次自检，见 `DeviceActions.probe()`。
    @State private var toolReady: Bool?

    // ── 「重启以生效」那一行 ────────────────────────────────────────────────

    /// 待确认重启。**与温控的确认分开两个源视图**：`confirmThermalEnable` 挂在
    /// `Toggle` 上，这个挂在下面那个按钮上 —— 同一个视图上叠两个
    /// `confirmationDialog` 会互相抢呈现。
    @State private var confirmReboot = false

    /// 连 `posix_spawn` 都没成功（工具被删了、包不完整）。要说话 ——
    /// 重启最大的失败模式就是「点了没反应」。
    @State private var rebootFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: thermalBinding) {
                Text("Disable thermal throttling")
                    .font(AppFont.text(14, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
            .tint(.mwAccent)
            .disabled(toolReady != true || thermalUnavailable || thermalBusy)
            // 去掉 Toggle 的滑块动画（2026-10-14 用户要求）。
            //
            // 这个开关的两个状态来源不同：用户点它、以及 `.task` 读回 plist 后纠正。
            // 前者是用户动作，动画是合理的反馈；后者是**纠错**，动画只会让人看到
            // 「它自己动了一下」。把动画整个关掉，两种情形都是干脆地切换。
            .animation(nil, value: thermalDisabled)
            // 挂在 `Toggle` 上而不是外层 `VStack`：外层下面那个按钮还要挂一个
            // 重启确认，同一个视图上叠两个会互相抢呈现。
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

            // 说明与失败提示都是 `.caption`：这一段是卡片里的一个开关，
            // 不是一张卡片，正文级字号会把它顶得跟上面的「智能停充」一样重。
            Text("Stops the thermalmonitord daemon so iOS stops lowering the CPU clock in response to heat. Takes effect after a restart.")
                .font(.caption)
                .foregroundStyle(Color.mwMuted)
                .fixedSize(horizontal: false, vertical: true)

            if thermalFailed {
                Text("Could not change the thermal setting.")
                    .font(.caption)
                    .foregroundStyle(Color.mwDanger)
            }

            if thermalNeedsRestart {
                Button {
                    // 走与齿轮里「重启设备」同一个动作，不另开一条路径 ——
                    // 这里自己弹一次确认，因为那个页面此刻不在屏幕上。
                    confirmReboot = true
                } label: {
                    Label("Restart to apply", systemImage: "arrow.clockwise")
                        .font(AppFont.text(13, weight: .semibold))
                }
                .tint(.mwAccent)
                .confirmationDialog(
                    Text(verbatim: Strings.text("Are you sure you want to %@?", DeviceAction.reboot.title)),
                    isPresented: $confirmReboot,
                    titleVisibility: .visible
                ) {
                    Button(DeviceAction.reboot.title, role: .destructive) {
                        // 成功的话这里**不会**有下文：重启会让整个进程消失。
                        if !DeviceActions.perform(.reboot) { rebootFailed = true }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(verbatim: DeviceAction.reboot.warning)
                }
            }
        }
        .alert("Could not start the helper.", isPresented: $rebootFailed) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("The privileged helper is missing from this build, or could not obtain root. Run scripts/build-ipa.sh to bundle it.")
        }
        // 自检要起一个子进程并等它结束（毫秒级，但最长会等到 1 秒），
        // 所以放到主 actor 之外跑 —— 与 `MaintenanceSheet` 同一句话，同一个理由。
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

            // 持久化改造之前写下的那批「待重启」没有时刻，永远判断不出兑现与否。
            // 在这里一次性清干净，免得它变成一条消不掉的提示（2026-10-14）。
            if thermalNeedsRestartPending, thermalNeedsRestartAt == 0 {
                thermalNeedsRestartPending = false
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
            // 写成功也**不等于**已经生效 —— 要重启。连同「此刻的系统运行时长」一起
            // 记下，重启之后这一行才会自己消失（见 `thermalNeedsRestart`）。
            //
            // 顺序不能反：先落时刻、再置标记 —— 标记是显示与否的总闸，
            // 若先置标记，中间那一帧会用一个还没更新的时刻去判断。
            thermalNeedsRestartAt = ProcessInfo.processInfo.systemUptime
            thermalNeedsRestartPending = true
        } else {
            // 回滚，别让开关停在一个假的「已开启」上。
            thermalDisabled = !disabled
            thermalFailed = true
        }
    }
}
