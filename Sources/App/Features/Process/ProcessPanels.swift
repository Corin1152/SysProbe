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
/// 想找自己装的 App 得翻很久；分开之后两组各自好找。
///
/// 两组**都可以折叠**（2026-10-15 要求），默认展开：系统那一组动辄三百行，而这一页
/// 大多数时候要找的是自己装的 App —— 收起系统组，列表就只剩十几行。
///
/// ── 排序（2026-10-15 要求）──────────────────────────────────────────────────
///
/// 标题行右侧一个菜单，三种口径：**应用名 / CPU 占用 / 内存占用**（见
/// `ProcessSortOrder`）。排序**在组内做**，两组之间不混 —— 分组是这个列表的
/// 第一层结构，排序是第二层，把两组合起来重排就等于把分组取消了。
///
/// **睡着的进程一律排在组内末尾**，与选了哪种口径无关。理由是这一页要回答的是
/// 「谁在吃 CPU / 内存」，而睡着的进程在这两个维度上都是 0 —— 它们会把真正在动的
/// 那几行挤到中间去。这一条在「按名称排」时尤其要紧：`backboardd` 这样的名字
/// 按字母序会落在中段，而它此刻什么都没干。
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

    /// 右上角齿轮菜单的回调，由 `RootView` 给。
    ///
    /// 2026-10-15：参数从 `() -> Void` 变成 `(SettingsDestination) -> Void` ——
    /// 齿轮从一个动作变成一个菜单（维护 / 关于）。
    let openSettings: @MainActor (SettingsDestination) -> Void

    /// 采样器。**在这一层持有**（`@StateObject`）而不是像 `HardwareMonitor` 那样
    /// 挂在 App 级：这一页的数据只有这一页用，而它的生命周期就该跟着这一页走。
    @StateObject private var monitor = ProcessMonitor()

    /// 筛选词。空 = 全部。
    @State private var query = ""

    /// 排序口径。**默认按应用名** —— 这一页最常见的用途是「找到那个 App」，
    /// 而按占用排是「排查异常」时才需要的第二件事。
    @State private var sortOrder: ProcessSortOrder = .name

    /// 已经折叠的分组。**默认空 = 两组都展开**。
    ///
    /// 与频段页的折叠一样不持久化：折叠是一次浏览里的临时姿态，每次进这一页都从
    /// 「全展开」开始，用户想收起系统组时再收。
    @State private var collapsedGroups: Set<ProcessGroup> = []

    var body: some View {
        // `spacing: 8`（默认 14）—— 这一页几百行**每一行都是这个 `LazyVStack`
        // 的直接子视图**，所以页面级间距就是行间距。14 加行自身上下各 9 的内边距，
        // 相邻两行的边框之间要空出 32 pt，用户反馈「行间隙太大」。压到 8 之后是
        // 8 + 6 + 6 = 20 pt（`ProcessRow` 的内边距同时从 9 收到 6）。
        PageScaffold("Processes", glow: .mwAccent, spacing: 8, openSettings: openSettings) {
            // 概览单独成一个子视图：它观察 `HardwareMonitor`（每秒发布一次），
            // 而列表是几百行 —— 把那份订阅留在这一层，等于每秒让整页 body
            // 重算一遍、把整个列表 diff 一次。拆出去之后只有这个小面板跟着重算。
            ProcessOverviewPanel(monitor: monitor)

            if monitor.processes.isEmpty {
                emptyPanel
            } else {
                toolbarRow

                // `ForEach` 直接挂在外层 `LazyVStack`（`PageScaffold` 里的那个）下，
                // 每一行才是独立的懒加载元素。把它整个包进一个 `Panel` 会让
                // LazyVStack 只看到一个子视图，于是几百行**全部**立刻建出来。
                //
                // 分组标题也是这个 LazyVStack 的兄弟节点，而不是套在组外面 ——
                // 套一层 `Section` 或 `VStack` 会重新把组内所有行变成「一次性建出来」。
                //
                // 折叠用的 `if` **不破坏这件事**：条件渲染不产生容器，展开时
                // `ForEach` 仍然是那个 LazyVStack 的直接子视图。
                if !userApps.isEmpty {
                    groupHeader(.userApps, count: userApps.count)
                    if !collapsedGroups.contains(.userApps) {
                        ForEach(userApps) { row(for: $0) }
                    }
                }
                if !systemProcesses.isEmpty {
                    groupHeader(.system, count: systemProcesses.count)
                    if !collapsedGroups.contains(.system) {
                        ForEach(systemProcesses) { row(for: $0) }
                    }
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

    /// 用户安装的 App（含它们的扩展进程），已排序。
    private var userApps: [ProcessEntry] {
        arranged(filtered.filter(\.isUserApp))
    }

    /// 系统自带的进程，已排序。**是「非用户 App」而不是「uid == 0」** ——
    /// 系统那一组里绝大多数是各自的专用 uid（`_securityd` 之类），
    /// 按 uid 判会把它们全漏掉。
    private var systemProcesses: [ProcessEntry] {
        arranged(filtered.filter { !$0.isUserApp })
    }

    /// 按当前口径排一组进程。**排序在组内做** —— 理由见类型头。
    ///
    /// 三条规则依次生效：
    ///
    ///   1. **睡着的沉底**（`isSleeping`）。放在最前面判，所以它与选了哪种口径无关；
    ///   2. 选中的口径（名称升序 / CPU 降序 / 内存降序）；
    ///   3. **平手时按 pid 升序**。这一步不是装饰：`sorted(by:)` 要求严格弱序，
    ///      而 CPU 与内存大量进程取同一个值（一堆 0），只比主键的话比较函数对
    ///      这些元素两两都返回 `false` —— 那是合法的弱序，但顺序会**在每次
    ///      采样后跳来跳去**，看起来像列表在自己乱动。加一个全序的兜底键就定了。
    private func arranged(_ entries: [ProcessEntry]) -> [ProcessEntry] {
        let shares = monitor.cpuShare
        return entries.sorted { lhs, rhs in
            if lhs.isSleeping != rhs.isSleeping { return !lhs.isSleeping }
            switch sortOrder {
            case .name:
                // `localizedStandardCompare` 而不是 `<`：它对数字段做自然排序
                // （`Core 2` 排在 `Core 10` 前面），而 App 名里带数字的不少。
                let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if order != .orderedSame { return order == .orderedAscending }
            case .cpu:
                let left = shares[lhs.pid] ?? 0
                let right = shares[rhs.pid] ?? 0
                if left != right { return left > right }
            case .memory:
                if lhs.residentBytes != rhs.residentBytes { return lhs.residentBytes > rhs.residentBytes }
            }
            return lhs.pid < rhs.pid
        }
    }

    // MARK: 版式

    /// 分组标题 —— 同时是这一组的折叠开关。
    ///
    /// 整行都可点（不只是那个小三角）：这一行除了文字没有别的东西，而手指按得中
    /// 比看得清更难。收起之后**计数照留**，所以「系统组有 312 个进程」这件事
    /// 不用展开也看得到。
    private func groupHeader(_ group: ProcessGroup, count: Int) -> some View {
        let isCollapsed = collapsedGroups.contains(group)
        return Button {
            if isCollapsed {
                collapsedGroups.remove(group)
            } else {
                collapsedGroups.insert(group)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(AppFont.text(10, weight: .bold))
                    .foregroundStyle(Color.mwMuted)
                    // 同一个图形转 90° 表示展开 —— 与频段页那张卡片的折叠按钮
                    // 是同一个手法，读的人一眼能连上「同一个东西换了姿态」。
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(group.title)
                    .font(AppFont.text(12, weight: .semibold))
                    .foregroundStyle(Color.mwMuted)
                Text(verbatim: "\(count)")
                    .font(AppFont.mono(11))
                    .foregroundStyle(Color.mwMuted.opacity(0.75))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            // 竖向留白给足：命中区域不能只有那一行文字的 15 pt 高。
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(for entry: ProcessEntry) -> ProcessRow {
        ProcessRow(entry: entry,
                   cpuShare: monitor.cpuShare[entry.pid],
                   resourceAvailable: monitor.resolvedCount > 0)
    }

    /// 列表顶部那一行：筛选框 + 排序菜单。
    ///
    /// ── 排序为什么在这里，而不是导航栏 ──────────────────────────────────────
    ///
    /// 导航栏右侧被齿轮占着（它是全局入口，不该被本页的功能挤走）。放在筛选框旁边
    /// 是这两个控件本来就该挨着：一个决定「看到哪几条」，一个决定「按什么顺序看」，
    /// 都作用在下面整个列表上。
    private var toolbarRow: some View {
        HStack(spacing: 8) {
            searchField
            sortMenu
        }
    }

    /// 排序菜单。`Picker` 而不是几个 `Button` —— 系统会在菜单里给当前项画上勾，
    /// 「现在按什么排」不用自己再写一遍选中态。
    private var sortMenu: some View {
        Menu {
            Picker(Strings.text("Sort"), selection: $sortOrder) {
                ForEach(ProcessSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(AppFont.text(14, weight: .semibold))
                .foregroundStyle(Color.mwAccent)
                // 与筛选框同一组内边距，两者高度才对得齐 —— 差 1 pt 都看得出来。
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
        .accessibilityLabel(Text("Sort"))
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

            intervalMenu

            Button {
                monitor.refresh(manual: true)
            } label: {
                // ── 2026-10-15：两个状态必须占同一块地方 ────────────────────────
                //
                // 这里原来是 `if isSampling { ProgressView } else { Image }` 直接
                // 二选一。`ProgressView(.mini)` 与 13 pt 的 `arrow.clockwise` 高度
                // 不一样（差 2–3 pt），于是**每一拍采样开始与结束时这一行的高度都会
                // 变一次** —— 它下面的列表跟着上下跳一格。自动刷新开着时就是每秒跳
                // 两次，正是用户报的那个现象。
                //
                // 修法不是把两者调成一样高（那要猜 `ProgressView` 的内部尺寸，
                // 换个系统版本就失效），而是给这一格**写死**一个 frame：
                // `ZStack` 让两个状态叠在同一个位置上，谁都不撑开谁。
                //
                // ── 同一天再改：圈只跟**手动**刷新走 ─────────────────────────────
                //
                // 判据从 `isSampling` 换成 `isManualRefresh`。原来自动刷新也置
                // `isSampling`，于是那个圈每 3 秒转一次、看着像「一直在转」。
                // 手动点一下转一下，自动刷新期间保持静止的箭头。
                ZStack {
                    if monitor.isManualRefresh {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(AppFont.text(13, weight: .semibold))
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.mwAccent)
            // 也跟手动状态走：自动刷新那几十毫秒里按钮**仍然可点** ——
            // 否则用户点了没反应（`refresh` 里那句 `guard !samplingInFlight`
            // 会把这一拍丢掉），看起来就是「按钮坏了」。
            .disabled(monitor.isManualRefresh)
            .accessibilityLabel(Text("Refresh"))
        }
    }

    /// 采样间隔菜单，摆在刷新按钮**左边** —— 它管「多久自动刷一次」，刷新按钮管
    /// 「现在立刻刷一次」，从慢到快的顺序读下来更顺。
    ///
    /// 用 `Picker` 而不是几个 `Button`：当前档位由系统在菜单里画勾，不必自己再维护
    /// 一份选中态。档位全部取自 `ProcessMonitor.intervalOptions`，`setInterval` 会
    /// 校验并落盘，所以这里不需要做任何边界处理。
    ///
    /// 图标右边带一个当前档位的小字（`3s`）。没有它的话，用户改完间隔从菜单退出来
    /// 就看不到自己设成了几秒 —— 只有图标是没法回读的。数值用 `.monospacedDigit()`
    /// 并且整块给固定宽度，否则 `1s` 与 `30s` 宽度不同，会把右边的刷新按钮推来推去。
    private var intervalMenu: some View {
        Menu {
            Picker(Strings.text("Refresh interval"),
                   selection: Binding(get: { monitor.interval },
                                      set: { monitor.setInterval($0) })) {
                ForEach(ProcessMonitor.intervalOptions, id: \.self) { seconds in
                    Text(verbatim: "\(Int(seconds))s").tag(seconds)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(AppFont.text(12, weight: .semibold))
                Text(verbatim: "\(Int(monitor.interval))s")
                    .font(AppFont.text(11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.mwAccent)
            // 与右边的刷新按钮同一个 22 pt 高 —— 这一行的高度由这两个控件定，
            // 哪一个高一截都会把下面的列表整体顶下去（就是上次那个跳动）。
            .frame(minWidth: 42, minHeight: 22, alignment: .center)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Refresh interval"))
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
        // 上下各 9 → 6（2026-10-15）：行间隙的另一半。与页面级间距（进程页传 8）
        // 合起来把相邻两行边框之间的距离从 32 pt 收到 20 pt。
        .padding(.vertical, 6)
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

// MARK: - 排序与分组的口径

/// 列表的排序口径。
///
/// 三种都是「这一页要回答的问题」的直接翻译：**应用名**是「我要找那个 App」、
/// **CPU** 是「谁在烧电」、**内存**是「谁把内存占满了」。
///
/// 放在文件作用域而不是 `ProcessPanels` 里面：默认 MainActor 隔离下嵌套类型的隔离
/// 跟着外层走，而它只被 `Picker` 与 `ForEach` 读，与那个视图没有关系。
nonisolated enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case name
    case cpu
    case memory

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .name: return "App name"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        }
    }

    var systemImage: String {
        switch self {
        case .name: return "textformat.abc"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        }
    }
}

/// 列表的两个分组。
///
/// 用枚举而不是两个 `Bool`：折叠状态是一个 `Set<ProcessGroup>`，加第三组时
/// 只多一个 case，不用再多一个开关、再多一处 `if`。
nonisolated enum ProcessGroup: String, CaseIterable, Identifiable {
    /// 用户安装的 App 及其扩展进程。
    case userApps
    /// 系统自带的一切（守护进程、系统 App 的扩展、内核任务）。
    case system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .userApps: return "User Apps"
        case .system: return "System"
        }
    }
}
