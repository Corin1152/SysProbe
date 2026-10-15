import SwiftUI

/// 第 5 个分页 —— 进程列表。
///
/// 对应 Windows 任务管理器的「进程」页：名称 / CPU / 内存 / PID / 状态。
///
/// ── 这一页能显示什么、不能显示什么 ──────────────────────────────────────────
///
/// **能**：应用名（从 `.app` 包里读的显示名，不是内核那个被截断的进程名）、
/// CPU 占用率、常驻内存、PID、属主（root / mobile / 系统专用 uid）、运行状态，
/// 以及页头的**整机** CPU 与内存占用（那两项来自 `HardwareMonitor` 的 Mach 调用，
/// 与进程列表无关，但摆在同一页上才读得通）。
///
/// **可能读不到**：CPU 与内存两列走的是 `proc_pidinfo`（私有 API），需要
/// `task_for_pid-allow`。真机上万一被拦，那两列整列显示「—」，并在页头说明原因 ——
/// 而不是把 0 当成「占用 0」摆出去。判据是 `ProcessMonitor.resolvedCount`。
///
/// ── 分组 ────────────────────────────────────────────────────────────────────
///
/// 分成「用户应用」与「系统」两组，判据是 C 侧给的 `userApp`（可执行文件在不在
/// Bundle 容器里）。这台设备上三百多个进程里用户 App 只占十几个，混在一起时
/// 想找自己装的 App 得翻很久；分开之后两组各自按 pid 升序，各自好找。
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
/// 采样**：`onAppear` 起、`onDisappear` 停。切到别的分页、或 App 退到后台，
/// 一拍都不跑。
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
                //
                // 分组标题也是这个 LazyVStack 的兄弟节点，而不是套在组外面 ——
                // 套一层 `Section` 或 `VStack` 会重新把组内所有行变成「一次性建出来」。
                if !userApps.isEmpty {
                    groupHeader("User Apps", count: userApps.count)
                    ForEach(userApps) { row(for: $0) }
                }
                if !systemProcesses.isEmpty {
                    groupHeader("System", count: systemProcesses.count)
                    ForEach(systemProcesses) { row(for: $0) }
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

    // MARK: 筛选与分组

    /// 按显示名 / 进程名（不区分大小写）或 pid 精确匹配筛选。
    ///
    /// 三个都搜：用户记得住的是应用名（"微信"），排查问题时手里拿的是进程名
    /// （`backboardd`）或 pid。只搜一个会让人以为「搜不到就是没有」。
    private var filtered: [ProcessEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return monitor.processes }
        return monitor.processes.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.comm.localizedCaseInsensitiveContains(needle)
                || String($0.pid) == needle
        }
    }

    /// 用户安装的 App（含它们的扩展进程）。
    private var userApps: [ProcessEntry] {
        filtered.filter(\.isUserApp)
    }

    /// 系统自带的进程。**是「非用户 App」而不是「uid == 0」** ——
    /// 系统那一组里绝大多数是各自的专用 uid（`_securityd` 之类），
    /// 按 uid 判会把它们全漏掉。
    private var systemProcesses: [ProcessEntry] {
        filtered.filter { !$0.isUserApp }
    }

    // MARK: 版式

    private func groupHeader(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AppFont.text(12, weight: .semibold))
                .foregroundStyle(Color.mwMuted)
            Text(verbatim: "\(count)")
                .font(AppFont.mono(11))
                .foregroundStyle(Color.mwMuted.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    private func row(for entry: ProcessEntry) -> ProcessRow {
        ProcessRow(entry: entry,
                   cpuShare: monitor.cpuShare[entry.pid],
                   resourceAvailable: monitor.resolvedCount > 0)
    }

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

/// 页头：进程数 + **整机** CPU / 内存 + 最近一次采样的状态。
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

                // 只在「列表有内容、但有东西没读到」时出现。**两种降级分开说** ——
                // 「CPU / 内存整列是 —」与「名字全是进程名」在界面上看起来完全不同，
                // 用户据此该做的事也不同。不说清楚的话，两种都会被当成「这一页坏了」。
                if !monitor.processes.isEmpty
                    && (monitor.resolvedCount == 0 || monitor.namedCount == 0) {
                    unavailableNotice
                }
            }
        }
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.resolvedCount == 0 {
                noticeBlock("Per-process CPU and memory are unavailable.",
                            detail: "The private API was blocked, so only names and PIDs are shown.")
            }
            if monitor.namedCount == 0 {
                noticeBlock("App names are unavailable — showing process names.",
                            detail: "proc_pidpath or the app bundle could not be read.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeBlock(_ title: LocalizedStringKey,
                             detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppFont.text(11, weight: .medium))
                .foregroundStyle(Color.mwMuted)
            Text(detail)
                .font(AppFont.text(10))
                .foregroundStyle(Color.mwMuted.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 一行进程。两行版式：上行是应用名与 CPU 占用，下行是进程名 / pid / 状态与内存。
///
/// ── 为什么是两行 ────────────────────────────────────────────────────────────
///
/// 单行要同时塞下「应用名 + CPU% + 内存 + pid + 状态」，在 iPhone 宽度上必然有一项
/// 被压成省略号。而这五项里**应用名**是要认的、**CPU 与内存**是要比的，
/// 都不该让位。拆成两行之后主次分明：上行认人，下行对账。
private struct ProcessRow: View {

    let entry: ProcessEntry
    /// 0…1 的整机口径占用率。`nil` = 这一拍没有基线（刚出现的进程），
    /// 或者整条 libproc 路不通。
    let cpuShare: Double?
    /// 这一趟里有没有任何一个进程读到了资源计数。`false` 时两列一起显示「—」，
    /// 不再逐个判 —— 那种情况下逐个数是 0 的进程会被误显示成「0% / 0 KB」。
    let resourceAvailable: Bool

    private var owner: ProcessOwner { ProcessOwner(uid: entry.uid) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(ownerTint)
                .frame(width: 6, height: 6)
                // 让色点与上行文字的中线对齐，而不是贴在行顶。
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(AppFont.text(13, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    // 应用名的区分度常在尾部（`…Pro` / `…Lite`），
                    // 截中间比截尾巴更容易认出来。
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    if entry.showsCommSeparately {
                        Text(verbatim: entry.comm)
                            .font(AppFont.mono(10))
                            .foregroundStyle(Color.mwMuted)
                            .lineLimit(1)
                        Text(verbatim: "·")
                            .font(AppFont.text(10))
                            .foregroundStyle(Color.mwMuted.opacity(0.7))
                    }
                    Text(verbatim: "\(entry.pid)")
                        .font(AppFont.mono(10))
                        .foregroundStyle(Color.mwMuted)
                    Text(ProcessState(raw: entry.status).title)
                        .font(AppFont.text(10))
                        .foregroundStyle(Color.mwMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: cpuText)
                    .font(AppFont.mono(12))
                    .foregroundStyle(cpuTint)
                    .frame(width: 46, alignment: .trailing)
                Text(verbatim: memoryText)
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.mwMuted)
                    .frame(width: 58, alignment: .trailing)
            }
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

    // MARK: 数值

    private var cpuText: String {
        guard resourceAvailable, let share = cpuShare else { return "—" }
        let percent = share * 100
        // 低于 0.05% 的一律并成 0%：那种量级在四位宽的列里没有意义，
        // 而 "0.0%" 看起来像「读不到」，与真正的「—」混淆。
        if percent < 0.05 { return "0%" }
        if percent >= 10 { return "\(Int(percent.rounded()))%" }
        return String(format: "%.1f%%", percent)
    }

    /// CPU 越高越显眼：≥70% 用警示色，≥25% 用强调色，其余用正文色。
    /// 这一页的主要用途就是「找出谁在吃 CPU」，全列一个颜色等于没给。
    private var cpuTint: Color {
        guard resourceAvailable, let share = cpuShare else { return .mwMuted }
        if share >= 0.70 { return .mwLoss }
        if share >= 0.25 { return .mwAccent }
        return .primary
    }

    private var memoryText: String {
        guard resourceAvailable, entry.hasResourceData else { return "—" }
        return Self.formatBytes(entry.residentBytes)
    }

    /// 内存的紧凑写法。自己算而不用 `ByteCountFormatter`：那东西每行一次调用，
    /// 几百行滚动时是实打实的开销，而这里只需要三档。
    private static func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.0f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
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
