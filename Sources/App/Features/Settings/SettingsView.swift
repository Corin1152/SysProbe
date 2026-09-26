import SwiftUI

/// 设置页。维护动作、语言、诊断信息，以及移植来源的署名。
struct SettingsView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var charge: ChargeControlService
    @EnvironmentObject private var app: AppState
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
            // 画布铺在 `Form` **外面**、与它做兄弟节点，而不是 `Form` 的 `.background`。
            //
            // 两处差别都是看得见的：`NavigationStack` 自己的底色是系统分组色，只铺 `Form`
            // 的话导航栏那一条露出来的是它；而弹入／退出转场的第一帧若内容还没画上，
            // 露出来的同样是它 —— 深色下是近黑、浅色下是灰白，看起来就是整屏闪一下。
            ZStack {
                Color.mwCanvas
                Backdrop(glow: .mwAccent)
                Form {
                    maintenanceSection

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

                    Section {
                        LabeledContent("Device", value: monitor.deviceModelIdentifier)
                        LabeledContent("Sensors",
                                       value: Strings.text(monitor.sensorsAvailable
                                                           ? "available"
                                                           : "unavailable"))
                        // 版本与扩展摘要。排查负一屏问题时，第一步就是确认装的是哪一版、
                        // 扩展有没有被打进包 —— 这两行显示的就是**这一版**的真实内容。
                        LabeledContent("App version", value: AppInfo.version)
                        LabeledContent("Widget", value: AppInfo.widgetSummary)
                        // 充电守护进程的状态。
                        //
                        // 这一行值得放在这里而不是只放在充电页上：它是唯一能区分
                        // 「守护进程没被打进包」与「打进去了但起不来」的地方 ——
                        // 两者的界面表现一模一样（开关能点、什么都不发生）。
                        LabeledContent("Charge control",
                                       value: Strings.text(charge.daemonRunning
                                                           ? "Service running"
                                                           : "Service stopped"))
                        // 维护工具的状态。同上，它区分的正是「工具没进包」与
                        // 「进了包但拿不到 root」—— 后者的表现也是「点了没反应」。
                        LabeledContent("Root tool", value: rootToolSummary)
                        // 守护进程托管的网页界面。App 里**不用**它（见 `ChargeControlView`），
                        // 但它是 App 之外最后一道保险：界面出问题时，在 Safari 里打开
                        // 这个地址依然能手动停充。
                        Link(destination: ChargeBridge.interfaceURL) {
                            HStack {
                                Text("Service address")
                                Spacer()
                                Text(ChargeBridge.interfaceURL.absoluteString)
                                    .foregroundStyle(Color.mwAccent)
                            }
                        }
                        ForEach(monitor.diagnostics, id: \.self) { line in
                            Text(verbatim: line)
                                .font(.footnote)
                                .foregroundStyle(Color.mwMuted)
                        }
                    } header: {
                        Text("Diagnostics")
                    }

                    Section {
                        Text("Power and adapter readings are ported from MiniWatts, © the MiniWatts authors, licensed under the Apache License 2.0. They are read from Apple's private IOKit interfaces — read-only, no writes — which is why this app is sideload-only.")
                            .font(.footnote)
                            .foregroundStyle(Color.mwMuted)
                        Text("Charge control is ported from ChargeLimiter, © lich4, licensed under the GNU GPL v3. Its daemon is fetched from the upstream release at build time rather than stored in this repository.")
                            .font(.footnote)
                            .foregroundStyle(Color.mwMuted)
                        // 署名照实写：代码是本仓库自己写的，只有两个「在真机上验证过的
                        // 取值」参考了 RebootTools。别把这条写成「移植自某某」——那不准。
                        Text("Reboot and respring are implemented in this repository rather than reused from another app. The two constants they rely on — reboot(0) and the signal sent to SpringBoard — follow RebootTools by dongchenshuo, which credits 肖博vlog for the reboot core.")
                            .font(.footnote)
                            .foregroundStyle(Color.mwMuted)
                    } header: {
                        Text("Credits")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            // 自检要起一个子进程并等它结束（毫秒级，但最长会等到 1 秒），
            // 所以放到主 actor 之外跑 —— 这一帧正好是面板的呈现动画。
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
        .mwSheetBackground()
    }

    // MARK: 维护

    /// 设置页最上面那一区：两个破坏性动作并排。
    ///
    /// 位置在**最上方**，是明确要求的结果 —— 代价要说清楚：破坏性操作放在最容易
    /// 顺手点到的地方，误触概率比埋在下面高。所以这一区的安全性全部压在另外三件事上，
    /// 改动这里时别把它们去掉：
    ///
    ///   1. 每个动作都要过二次确认（`confirmationDialog`），且弹窗里写全动作名，
    ///      不是「确定 / 取消」；
    ///   2. 工具不可用时整区禁用 + 变淡，不给一个点了没反应的按钮；
    ///   3. 按钮是**普通行内按钮**，不占满整行 —— 见下面 `.buttonStyle` 那一段。
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
        } footer: {
            if toolReady == false {
                Text("The privileged helper is missing from this build, or could not obtain root. Run scripts/build-ipa.sh to bundle it.")
            } else {
                Text("These run a privileged helper from this app's bundle. Reboot Device restarts the whole phone; Respring restarts the interface only.")
            }
        }
    }

    /// 维护工具在诊断区里的那一行。
    ///
    /// 三态：没进包（静态可判）／自检通过／自检失败。中间那个 `—` 是「还在测」——
    /// 与 `AppInfo` 里读不到值时的写法一致。
    private var rootToolSummary: String {
        guard DeviceActions.toolPath != nil else { return Strings.text("not bundled") }
        switch toolReady {
        case .none: return "—"
        case .some(true): return Strings.text("available")
        case .some(false): return Strings.text("unavailable")
        }
    }

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
    /// 类型写成 `@MainActor () -> Void` 而不是 `() -> Void` —— 与 `PageScaffold`
    /// 里那个 `onOpenSettings` 同样的理由：闭包体里要碰主 actor 隔离的状态，
    /// 而项目默认主 actor 隔离，`() -> Void` 会在这里丢掉那个隔离域。
    let tap: @MainActor () -> Void

    var body: some View {
        // 用 `Button { tap() } label:` 而不是 `Button(action: tap)`：后者要把这个闭包
        // 直接交给 SwiftUI，会再撞一次上面那个隔离域转换的问题。
        Button {
            tap()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                Text(action.title)
                    .font(AppFont.text(13, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                    // 中文四个字、英文十来个字母，窄屏上都得待在一行里。
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
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
