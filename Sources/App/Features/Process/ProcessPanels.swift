import SwiftUI

/// 第 5 个分页 —— 进程列表。
///
/// 对应 Windows 任务管理器的「进程」页：名称 / PID / 属主 / 状态。
///
/// ── 这一页能显示什么、不能显示什么 ──────────────────────────────────────────
///
/// **能**：进程名、PID、属主（root / mobile / 系统专用 uid）、运行状态、
/// 以及页头的**全局** CPU 与内存占用（那两项来自 `HardwareMonitor` 的 Mach 调用，
/// 与进程列表无关，但摆在同一页上才读得通）。
///
/// **不能**：单个进程的 CPU 与内存。`kinfo_proc` 里没有资源计数，要拿得走
/// `proc_pidinfo` / `proc_pid_rusage`（私有 API）并依赖 task port 权限 ——
/// 那条路要先在真机上验证，详见 `Tools/RootTool.c` 里 `proc-list` 那一节。
/// 所以这一版**没有**「CPU」「内存」两列，而不是摆两列全是 0 的假数据。
///
/// ── 刻意不做的 ──────────────────────────────────────────────────────────────
///
/// **没有「结束进程」**。技术上可行（`RootTool` 已经有 `kill` 的先例，
/// respring 就是这么做的），但杀错进程的代价是白苹果或强制重启 ——
/// 这一页只读，不给任何写入口。
///
/// ── 采样开销与生命周期 ──────────────────────────────────────────────────────
///
/// 每一拍都要起一个 root 子进程（见 `ProcessMonitor` 类型头），所以**只在页面可见时
/// 采样**：`onAppear` 起、`onDisappear` 停。用户没停在这一页时一拍都不跑。
struct ProcessPanels: View {

    /// 右上角齿轮的回调，由 `RootView` 给。
    let openSettings: @MainActor () -> Void

    /// 采样器。**在这一层持有**（`@StateObject`）而不是像 `HardwareMonitor` 那样
    /// 挂在 App 级：这一页的数据只有这一页用，而它的生命周期就该跟着这一页走。
    @StateObject private var monitor = ProcessMonitor()

    /// 筛选词。空 = 全部。
    @State private var query = ""

    var body: some View {
        PageScaffold("Processes", glow: .mwAccent, openSettings: openSettings) {
            // 概览单独成一个子视图：它观察 `HardwareMonitor`（每秒发布一次），
            // 而列表是几百行 —— 把那份订阅留在这一层，等于每秒让整页 body
            // 重算一遍、把整个列表 diff 一次。拆出去之后只有这个小面板跟着重算。
            ProcessOverviewPanel(monitor: monitor)

            if monitor.processes.isEmpty {
                emptyPanel
            } else {
                searchField

                // `ForEach` 直接挂在外层 `LazyVStack`（`PageScaffold` 里的那个）下，
                // 每一行才是独立的懒加载元素。把它整个包进一个 `Panel` 会让
                // LazyVStack 只看到一个子视图，于是几百行**全部**立刻建出来。
                ForEach(filtered) { entry in
                    ProcessRow(entry: entry)
                }

                if filtered.isEmpty {
                    noMatchPanel
                } else {
                    footer
                }
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.pause() }
    }

    // MARK: 筛选

    /// 按进程名（不区分大小写）或 pid 精确匹配筛选。
    private var filtered: [ProcessEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return monitor.processes }
        return monitor.processes.filter {
            $0.comm.localizedCaseInsensitiveContains(needle) || String($0.pid) == needle
        }
    }

    // MARK: 版式

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(AppFont.text(13, weight: .semibold))
                .foregroundStyle(Color.mwMuted)

            TextField(Strings.text("Filter"), text: $query)
                .font(AppFont.text(14))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.mwMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mwCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mwCardStroke, lineWidth: 1)
        )
    }

    /// 列表为空时的那一块。**分两种说法**：从来没读到过，与读到了但被筛没了。
    /// 两者在界面上该显示的东西完全不同，不能合并成一句「没有内容」。
    private var emptyPanel: some View {
        Panel("Overview", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                if monitor.lastAttemptFailed {
                    Text("Could not read the process list.")
                        .font(AppFont.text(13, weight: .medium))
                        .foregroundStyle(Color.mwDanger)
                    Text("The root tool did not return a result. Check the Root tool line on the About page.")
                        .font(AppFont.text(12))
                        .foregroundStyle(Color.mwMuted)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading…")
                            .font(AppFont.text(13))
                            .foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
    }

    private var noMatchPanel: some View {
        Panel {
            Text(Strings.text("No process matches “%@”.", query))
                .font(AppFont.text(13))
                .foregroundStyle(Color.mwMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        Text(Strings.text("Showing %lld of %lld", filtered.count, monitor.processes.count))
            .font(AppFont.text(11))
            .foregroundStyle(Color.mwMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }
}

// MARK: - 概览

/// 页头：进程数 + **全局** CPU / 内存 + 最近一次采样的状态。
///
/// 单独一个类型只为一件事：让 `HardwareMonitor` 每秒一次的发布只把**这一块**
/// 重算一遍，而不是整页（几百行）跟着重算。与 `RootView` 里把
/// `MonitorLifecycle` 拆成零尺寸视图是同一个手法。
private struct ProcessOverviewPanel: View {

    @ObservedObject var monitor: ProcessMonitor
    @EnvironmentObject private var hardware: HardwareMonitor

    var body: some View {
        Panel("Overview", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Metric(caption: "Processes",
                           value: monitor.processes.isEmpty
                               ? "—"
                               : "\(monitor.processes.count)")
                    // 这两项是**整机**的，不是某个进程的 —— 摆在这里是为了让
                    // 「有多少进程」和「系统此刻有多忙」能对着读。
                    Metric(caption: "CPU",
                           value: percent(hardware.snapshot.cpu.usage),
                           tint: .mwAccent)
                    Metric(caption: "Memory",
                           value: percent(hardware.snapshot.memory.usage),
                           tint: .mwBattery)
                }

                statusRow
            }
        }
    }

    /// 状态行：说明列表是新的、旧的，还是压根没读到。
    private var statusRow: some View {
        HStack(spacing: 8) {
            if monitor.lastAttemptFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppFont.text(11, weight: .bold))
                    .foregroundStyle(Color.mwLoss)
                Text("Last update failed — showing earlier data.")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwLoss)
            } else if let updated = monitor.lastUpdated {
                Text(updated, style: .relative)
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)
            } else {
                Text("Reading…")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)
            }

            Spacer(minLength: 8)

            Button {
                monitor.refresh()
            } label: {
                if monitor.isSampling {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(AppFont.text(13, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.mwAccent)
            .disabled(monitor.isSampling)
            .accessibilityLabel(Text("Refresh"))
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - 行

/// 一行进程。色点表属主，右侧是状态与 pid。
///
/// 这一版**没有** CPU / 内存两列 —— 那两项的数据还没有可信来源（见
/// `Tools/RootTool.c` 里 `proc-list` 那一节的说明）。宁可少两列，
/// 也不摆两列永远是「—」或永远是 0 的占位。
private struct ProcessRow: View {

    let entry: ProcessEntry

    private var owner: ProcessOwner { ProcessOwner(uid: entry.uid) }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ownerTint)
                .frame(width: 6, height: 6)

            Text(entry.comm)
                .font(AppFont.text(13))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                // 进程名的区分度常在尾部（`...Service` / `...Daemon`），
                // 截中间比截尾巴更容易认出来。
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(ProcessState(raw: entry.status).title)
                .font(AppFont.text(10))
                .foregroundStyle(Color.mwMuted)
                .lineLimit(1)
                .frame(width: 46, alignment: .trailing)

            Text(verbatim: "\(entry.pid)")
                .font(AppFont.mono(12))
                .foregroundStyle(Color.mwMuted)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.mwCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.mwCardStroke, lineWidth: 1)
        )
    }

    /// 属主的颜色。root 用警示色 —— 那是这一页上唯一值得一眼认出来的类别
    /// （系统特权进程）；用户 App 用强调色；其余系统守护进程保持灰的。
    private var ownerTint: Color {
        switch owner {
        case .root: return .mwLoss
        case .mobile: return .mwAccent
        case .system: return .mwMuted
        }
    }
}

// MARK: - 状态文案

extension ProcessState {
    /// 状态的中文/英文说法。取值编码见 `ProcessState`。
    var title: LocalizedStringKey {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .sleeping: return "Sleeping"
        case .stopped: return "Stopped"
        case .zombie: return "Zombie"
        case .unknown: return "—"
        }
    }
}
