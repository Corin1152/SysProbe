import SwiftUI

/// 「关于」分页。版本号 + 诊断信息。原来是齿轮菜单里的第四页。
///
/// 2026-10-11 起它是底部分页栏的第 4 项 —— 齿轮删掉之后，这一页必须自己带
/// `NavigationStack`（以前那一层是 `SettingsDestinationHost` 给的）。
///
/// 标题保持 `.inline`：这一页是 `Form`（设置式列表），大标题在它上面会显得空。
/// 也顺带与「电源」「维护」两个带分段控件的分页保持一致 —— 四个分页里只有
/// 「硬件」用大标题，那是明确要求保留的。
///
/// **署名不在这里**（2026-10-04 按要求从界面上移除）。署名义务本身没有消失 ——
/// MiniWatts 是 Apache-2.0、ChargeLimiter 是 GPL-3.0，它们要求保留版权与许可声明，
/// 这些仍然完整地写在仓库根目录的 `NOTICE` 与 `LICENSE` 里，随源码一起分发。
/// 改这一页时不要顺手把 NOTICE 删掉。
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
        NavigationStack {
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
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
        }
        // 自检要起一个子进程并等它结束（毫秒级，但最长会等到 1 秒），放到
        // 主 actor 之外 —— 与维护页同一句话，同一个理由。
        .task {
            toolReady = await Task.detached { DeviceActions.probe() }.value
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
            // 守护进程托管的网页界面。App 里**不用**它（见 `ChargeControlPanels`），
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
