import SwiftUI

/// 「关于」页。版本号 + 移植来源的署名 + 诊断信息。
///
/// 署名不是客套：MiniWatts 是 Apache-2.0、ChargeLimiter 是 GPL-3.0，
/// 用了别人的代码就得说清楚。第三段刻意写成「本仓库自己实现、只参考了两个常量」——
/// 照实写比含糊地写「移植自某某」更准确。
///
/// 诊断区原来在「维护」页，2026-10-02 迁到这里：维护页在「清理」并入菜单之后
/// 只该剩「动手改系统」的东西，而诊断是**信息** —— 它归属关于页，与版本号
/// 同属「这一版装了什么、什么能用」的范畴。
struct AboutView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var charge: ChargeControlService

    /// 维护工具能不能用。与维护页 / 清理页各自跑一次毫秒级自检 ——
    /// 不为共用一行诊断引入跨页状态。
    @State private var toolReady: Bool?

    var body: some View {
        ZStack {
            Color.mwCanvas
            Backdrop(glow: .mwAccent)
            Form {
                Section {
                    // 排查问题时第一步就是确认装的是哪一版。
                    LabeledContent("App version", value: AppInfo.version)
                } header: {
                    Text("Version")
                }

                diagnosticsSection

                creditsSection
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        // 自检要起一个子进程并等它结束（毫秒级，但最长会等到 1 秒），放到
        // 主 actor 之外 —— 与维护页同一句话，同一个理由。
        .task {
            toolReady = await Task.detached { DeviceActions.probe() }.value
        }
    }

    /// 致谢。**刻意排在最后**（2026-10-03 从顶部移下来）：
    /// 这一页前面回答的是「我装的是哪一版、什么能用」，那才是用户来这儿要找的；
    /// 署名是法律义务，不是给用户的答案，放在最下面既满足署名要求，
    /// 又不会让每次打开关于页都先滚过五段法律文本。
    private var creditsSection: some View {
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
            // 「频段设置」是后加的功能，署名同样照实写。
            Text("Network band configuration reads and writes baseband bands through Apple's private CoreTelephony interfaces. The call shape follows CellularInfo by DevelopCubeLab, licensed under the GNU GPL v3.")
                .font(.footnote)
                .foregroundStyle(Color.mwMuted)
            // 「存储清理」是重写而非搬运的最直接的证据：样本无 LICENSE，
            // 而且它列表里有硬编码的占位数据 —— 这一句把两件事都说清楚。
            Text("Storage cleaning is implemented in this repository. The directory set and the per-app container approach follow the analysis of iOSCleanerPro 1.0 — an unlicensed third-party sample whose code was not reused. Its hardcoded placeholder app list is deliberately not reproduced.")
                .font(.footnote)
                .foregroundStyle(Color.mwMuted)
        } header: {
            Text("Credits")
        }
    }

    /// 诊断区。逐行原样从「维护」页迁来，内容没有变 —— 变的只是归宿：
    /// 每一行回答的都是「这一版装了什么、什么能用」，不是「维护操作的结果」。
    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Device", value: monitor.deviceModelIdentifier)
            LabeledContent("Sensors",
                           value: Strings.text(monitor.sensorsAvailable
                                               ? "available"
                                               : "unavailable"))
            // 扩展摘要。排查负一屏问题时，第一步就是确认扩展有没有被打进包 ——
            // 这一行显示的就是**这一版**的真实内容。
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
            LabeledContent("Root tool", value: DeviceActions.toolSummary(ready: toolReady))
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
    }
}
