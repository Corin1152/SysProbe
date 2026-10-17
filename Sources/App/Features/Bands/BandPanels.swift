import SwiftUI

/// 「频段」页的上半截 —— 频段锁定。**这是一段内容，不是页面。**
///
/// 读 / 写基带允许使用的频段，按 SIM 卡槽分开。
///
/// 2026-10-11 起它不再自己撑一页：画布、光晕、导航栈、标题都由外壳提供。
///
/// ── 2026-10-15：频段页收成单页 ──────────────────────────────────────────────
///
/// 原来这一页是「频段锁定 / 频段刷新」两个分段，靠一个 `Picker` 切。按要求取消分段：
/// 这一半在上（锁哪些频段），另一半在下（什么时候重载 modem）。于是**滚动容器也交回
/// 外壳** —— 这一层从 `ScrollView` + `LazyVStack` 改成 `Group`，与 `PowerView` /
/// `ChargeControlPanels` 同一个形状、同一个理由（`Group` 不产生布局容器，子视图被
/// 展平成外层 `LazyVStack` 的直接元素，每张卡片仍是独立的懒加载单元）。
///
/// 同一天还并进来两样：
///
///   · **「当前网络」卡片**：两个分段各有一张同名的，现在合成一张（上半网络、
///     下半刷新引擎），重复的 RSRP 去了一份，设备型号与卡槽两行整个去掉；
///   · **4G 频段卡片默认折叠**：折叠时标题旁边显示「选了几个 / 一共几个」，
///     展开后才是那一屏 24 个格子。
///
/// ## 四个动作按钮：一排，在「当前网络」卡片上方
///
/// 2026-10-14 定稿的布局：**恢复默认 / 重启蜂窝网络服务 / 刷新 / 保存** 四个按钮
/// 并排一行，放在页面最顶部（「当前网络」卡片正上方）。它们原先分成两处 —— 保存与
/// 刷新在导航栏右上，恢复默认与重启在页面最底部；导航栏那一版的问题是「保存」这个
/// 最重要的动作离内容最远，而底部那两个逃生通道要滚过整页频段网格才够得着。
///
/// 顺序即优先级：**恢复 → 重启 → 刷新 → 保存**。前两个是「出事了怎么办」，
/// 后两个是日常操作；把保存排在最后不是降级，而是它旁边必须有一个明确的参照物 ——
/// 它写的是基带，而基带写错了靠的就是前两个按钮救回来。
///
/// ## 这一页是整个 App 里唯一会「写系统状态」的地方
///
/// 别的页面读不到数据，最坏结果是难看。这里写错频段会导致**无服务、无法注册网络、
/// VoLTE / VoNR / 语音通话 / 短信异常**，而且是持久的 —— 原版文案里写着「设置完成后，
/// 即使重启设备，频段设置仍会保持」。
///
/// 所以安全措施全部保留，改动这一页时别把它们去掉：
///
///   1. **入口整屏警告**（首次进入，说清风险，可关）；
///   2. **保存前二次确认**（可关，关掉是用户自己的选择）；
///   3. **恢复默认前确认** —— 它是写错之后的主要逃生通道；
///   4. **「重启蜂窝网络服务」** —— 另一个逃生通道，与保存解耦，让用户自己决定何时重启；
///   5. **不可用时不画任何可点的东西**，并说明原因（没权限 / 无卡）。
///
/// 第 5 条尤其重要：CommCenter 权限没生效时，读会失败、写会**静默失败**
/// （调用不抛异常、不打日志）。不给一个「点了没反应」的保存按钮。
///
/// **频段网格默认折叠**（2026-10-15）也在这一条下面：一进页面就是一屏 24 个可点的
/// 格子，而每一次误触都可能被「保存」写进基带。折叠之后要先展开才能勾 —— 多出来的
/// 那一次点击，正是这一页唯一需要的缓冲。
struct BandPanels: View {

    /// 基带取数与写入。**由 `BandView` 注入**，不再是这里的 `@StateObject` ——
    /// 服务挂在视图上的话，页面重建一次就重读一遍基带、整屏盖一次转圈。
    /// 详见 `BandView` 类型头上那段说明。
    @ObservedObject var service: BandService

    /// 自动刷新的参数。**由 `BandView` 注入** —— 「当前网络」卡片下半截要按它决定
    /// 画哪几行（见 `RefreshStatusRows`），而参数的持有者是页面层。
    ///
    /// ── 2026-10-17：从 `let` 改成 `@Binding` ────────────────────────────────
    ///
    /// 「参数」那张卡片挪到了这一层（排在 4G 频段卡片**上方**，见 `body`），
    /// 它要能改值，光读不够。持有者仍是 `BandView` —— 落盘、下发守护进程、
    /// 重排定时器都挂在那边（见 `BandView.syncRefreshExecutor`）。
    @Binding var refreshConfig: BandAutoRefreshConfig

    /// 界面上的勾选状态：制式 → 启用的频段号。
    ///
    /// 与 `service.bandInfo.active` 分开存：前者是用户正在编辑的意图，后者是刚从
    /// Modem 读回来的事实。两者不一致就是「有未保存的修改」。
    ///
    /// **卡槽（`slot`）不在这里** —— 它跟着服务走（`service.slot`），因为「用户选的是
    /// 哪张卡」不该在切分段时丢掉。
    @State private var selection: [RadioAccessTechnology: Set<Int>] = [:]
    @State private var hasUnsavedChanges = false

    /// 已经展开的频段网格。**默认空 = 全部折叠**（2026-10-15 要求）。
    ///
    /// 刻意**不持久化**（不是 `@AppStorage`）：折叠是一次浏览里的临时姿态，每次进
    /// 这一页都从「全折叠」开始 —— 那正是这个改动想要的效果。持久化的话，用户某次
    /// 展开过之后就再也回不到默认的收拢状态了。
    @State private var expandedRats: Set<RadioAccessTechnology> = []

    // MARK: 四层警告的持久化开关

    /// 第 1 层：入口整屏警告是否已经看过。
    @AppStorage("sysprobe.bandEntryTipsDone") private var entryTipsDone = false
    /// 第 2 层：保存前是否还要确认。
    @AppStorage("sysprobe.bandSaveConfirm") private var saveConfirm = true
    /// 第 4 层：这一页是否还出现。
    ///
    /// 2026-10-14：它控制的已经是**整个「频段」分页**（见 `RootView.tabs`），
    /// 不再是「维护」页里的一格 —— 频段搬出来独占第 4 个分页之后，关掉就等于
    /// 把底部分页栏那一项收走。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    @State private var showEntryTips = false
    @State private var showSaveConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showRestartConfirm = false

    /// 操作结果横幅。成功与失败共用一条 —— 同一时刻只会有一个结果。
    ///
    /// ── 2026-10-15：它现在会自动消失 ────────────────────────────────────────
    ///
    /// 原来它挂上就一直在。最明显的是重启蜂窝服务：按下之后页面顶部那句
    /// 「Cellular service is restarting.」会常驻，网络早就回来了也不走 ——
    /// 用户唯一能让它消失的办法是切一次卡槽（那会清 `banner`）或者退出页面。
    /// 一条**结果**通知不该有这种生命周期，何况这句话在网络恢复之后本身就是错的。
    ///
    /// 现在每次挂横幅都排一个 5 秒后的收尾，用 `bannerToken` 认领：这 5 秒里
    /// 又出了新的、或用户自己动了界面把它清掉，旧的那次收尾就作废 ——
    /// 否则「先保存、再重启」时前一条的定时器会把后一条提前抹掉。
    @State private var banner: String?
    @State private var bannerIsError = false
    /// 当前这条横幅的序号。见 `showBanner`。
    @State private var bannerToken = 0

    /// 保存后「写 → 回读」的校验现场。`nil` = 没有在途校验。见 `BandWriteVerify`。
    @State private var verify: BandWriteVerify?
    /// 驱动校验回读的定时任务。换卡槽、再次保存、离开页面、用户又动了勾选都会取消它。
    @State private var verifyTask: Task<Void, Never>?

    /// 最后一次**被 Modem 回读确认过**的勾选。
    ///
    /// 只活在这一个界面实例里（不落盘）：它的唯一用途是「重启蜂窝服务之后，判断
    /// CommCenter 有没有把这次写入丢掉」（见 `scheduleRestartCheck`）。跨启动保留
    /// 反而危险 —— 那是别的会话里的期望值，拿来对比只会误报。
    @State private var confirmedSelection: [RadioAccessTechnology: Set<Int>]?

    /// 正在做「重启后校验」。为真时不许 `syncSelectionFromModem` 覆盖界面 ——
    /// 否则用户会先看到勾选跳回旧值，再被我们改成期望值，白闪一次。
    @State private var restartCheckActive = false
    /// 驱动重启后校验的定时任务。
    @State private var restartCheckTask: Task<Void, Never>?

    /// 频段网格：4 列。和原版一样 —— 一屏能扫完一个制式，不用滚。
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    /// 基带一次都还没问过 —— 也就是**首读**。
    ///
    /// 只有这一种情况才盖整屏转圈、才禁用交互。第二次进来（含分段切回来）时
    /// `availability` 已经有值，走的是静默刷新：界面照旧显示上一次的数据。
    ///
    /// 不带 `&& service.isLoading`：`.task` 跑起来之前 `isLoading` 还是 false，
    /// 带上它会在第一帧先画一屏空面板再盖上转圈 —— 那正是要修掉的「闪一下」。
    /// 判据只看「问过基带没有」，首读的整个过程（含等待开始的那一帧）都被盖住。
    private var isInitialLoad: Bool {
        service.availability == .unknown
    }

    var body: some View {
        // ── 为什么这里是 `VStack`，而电源页那边是 `Group` ──────────────────────
        //
        // 两处看着像同一件事（都是「一段内容」），但 `Group` 有个必须知道的性质：
        // **挂在 `Group` 上的修饰符会被应用到组内每一个子视图上**。这一层下面挂着
        // 一整套生命周期与弹窗（`.task` / `.onAppear` / `.onDisappear` / 四个
        // `.onChange` / `.alert` / 三个 `.confirmationDialog` / `.disabled` /
        // `.overlay`）—— 换成 `Group` 会变成「每个子视图各弹一次保存确认」，
        // 而且不报任何错。
        //
        // 包一层 `VStack` 就能把这一整套收在一个视图上。代价是这一层从「外层
        // `LazyVStack` 的四个元素」变成一个元素，懒加载范围小了一格 —— 而它内部
        // 只有四块、且都在页面顶部，省不下什么。
        //
        // 间距与外层 `PageScaffold` 用的**是同一个数**（2026-10-17 起两边都是 4，
        // 也就是进程页的卡片间距）：这一层包住的卡片与外面的卡片在用户眼里是同一
        // 列东西，两处不一致的话同一页会出现两种卡片间隙。
        VStack(spacing: 4) {
            if let banner {
                bannerPanel(banner)
            }

            if service.availability == .unavailable {
                unavailablePanel
            } else {
                // 四个动作按钮：一排，紧贴页面顶部（「当前网络」卡片上方）。
                //
                // 2026-10-14 定稿：保存 / 刷新从导航栏右上搬下来，恢复默认 /
                // 重启蜂窝网络服务从页面最底部搬上来，四个并排。
                actionRow
                infoPanel
                if service.slots.count > 1 { slotPanel }
                // ── 2026-10-17：与 4G 频段卡片换了位置 ─────────────────────────
                //
                // 原来顺序是「频段卡片 → 参数卡片」，现按要求改成「参数卡片 →
                // 频段卡片」：参数是这一页的前置条件（多久看一次、什么条件下才
                // 动手），而频段网格是一片要点很多次的格子 —— 先看条件，再动手。
                AutoRefreshParametersPanel(config: $refreshConfig)
                bandPanels
            }
        }
        .disabled(isInitialLoad)
        .overlay {
            if isInitialLoad {
                ProgressView().controlSize(.large)
            }
        }
        // 只在**第一次**读回来之前盖转圈、并且只在第一次禁用交互。
        //
        // 原来这两个条件都是 `service.isLoading`，于是「静默刷新」也会把整页盖住 ——
        // 用户看到的就是「一进这一页整屏刷一次」。判据改成 `availability == .unknown`
        // （基带一次都还没问过）：第二次进来时它已经有值，刷新在后台进行，
        // 界面照旧显示上一次读回来的数据，直到新数据替换上来。
        //
        // 顺带解决另一个问题：基带慢的时候（`copyCellInfo` 最坏等 1 秒）整页会
        // 卡在不可交互状态，而现在只有真正的首读才这样。
        .task {
            // 首次进入先给整屏警告。它挡在加载之前 —— 让人先看懂风险，再看数据。
            if !entryTipsDone { showEntryTips = true }
            // 读 / 探卡槽都在服务里（已经读过就是静默刷新，见 `BandService.ensureLoaded`）。
            await service.ensureLoaded()
        }
        // 勾选状态从「已经读回来的那份数据」铺一次。
        //
        // 需要这一句是因为 `.onChange(of: service.bandInfo)` 只在**值真的变了**时才触发，
        // 而分段切回来时数据是缓存的、值没变 —— 少了它，第二次进来所有勾都是空的。
        .onAppear {
            syncSelectionFromModem()
            // 「当前网络」这一组是实时量，进页面就开始每秒刷新（见 `startSlotPolling`）。
            service.startSlotPolling()
        }
        // 离开就停表：切分段、切分页都会走到这里。定时器挂在 `.default` 模式上，
        // 滚动期间本来就会让路，这一句管的是「人已经不在这页了」那种情况。
        .onDisappear {
            service.stopSlotPolling()
            // 人已经走了：在校验里的那几次回读没有意义，也省得它稍后弹一条
            // 用户根本没在看的横幅。
            cancelVerify()
            cancelRestartCheck()
        }
        // 右上角只有齿轮（维护 / 关于），由外壳 `PageScaffold` 渲染 —— 这一层
        // 不再声明任何工具栏项。2026-10-14 之前保存 / 刷新 / 齿轮三个按钮走
        // `.toolbar` 排在导航栏右侧，现在这四个动作全部搬到页面顶部（见 `actionRow`）。
        .onChange(of: service.bandInfo) { _ in
            syncSelectionFromModem()
        }
        .onChange(of: service.slot) { newSlot in
            // 换卡槽必须重新读 —— 每张卡的频段配置是独立的。桥接层手里留的是
            // 上一张卡的对象，不重读就没得写。
            selection = [:]
            hasUnsavedChanges = false
            // 换卡了：上一张卡的校验现场没有意义，回读会读到另一张卡。
            cancelVerify()
            cancelRestartCheck()
            confirmedSelection = nil
            dismissBanner()
            service.load(slot: newSlot)
        }
        .alert("Before you continue", isPresented: $showEntryTips) {
            Button("I understand") {
                entryTipsDone = true
            }
            Button("Hide this page", role: .destructive) {
                // 第 4 层：关掉入口。**没有地方能再打开** —— 这是故意的，
                // 一个能随手关掉又能随手打开的开关挡不住误触。
                //
                // 2026-10-14：关掉之后是整个「频段」分页从底部分页栏消失 ——
                // 由 `RootView` 的 `onChange` 把选中态挪回「维护」，
                // 否则分页栏会显示成「一个都没选」。
                showBandEditor = false
            }
        } message: {
            Text("Incorrect band settings can cause network problems, prevent the device from registering on the network, or result in \"No Service\".\n\nDo not disable every band of a network type — that can break VoLTE, VoNR, voice calls and SMS.\n\nSettings persist across reboots. If anything goes wrong, use \"Restore Default\" or \"Restart Cellular Service\" at the top of this page.\n\nThis feature is intended for advanced users.")
        }
        .confirmationDialog(
            Text(verbatim: Strings.text("Save the current band settings?")),
            isPresented: $showSaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Save", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Incorrect band settings may cause cellular network issues, such as \"No Service\".")
        }
        .confirmationDialog(
            Text(verbatim: Strings.text("Restore the default band settings?")),
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore Default", role: .destructive) { restoreDefault() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All bands the device supports will be enabled again.")
        }
        .confirmationDialog(
            Text(verbatim: Strings.text("Restart cellular service?")),
            isPresented: $showRestartConfirm,
            titleVisibility: .visible
        ) {
            Button("Restart", role: .destructive) { restartCellular() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cellular connectivity is interrupted for a few seconds. If your SIM or eSIM is PIN-protected you may need to enter the PIN again.")
        }
    }

    // MARK: - 顶部信息

    /// 设备 + 当前网络的只读状态 + 自动刷新引擎的状态。
    ///
    /// 每一行**只在真的有值时才画** —— 读不到就不占位置。原版会把读不到的项显示成
    /// 空白，那会让人以为「信号是 0」而不是「这一项读不到」。
    ///
    /// ── 2026-10-15：与「频段刷新」那一张同名的卡片合并 ──────────────────────
    ///
    /// 两张卡片说的是同一件事的两半：这张说「网络本身什么样」，那张说「刷新引擎
    /// 此刻在干什么」。分段取消之后，两张同名卡片分在两处只会让人以为看花了眼。
    ///
    /// 合并时去掉了三样：
    ///
    ///   · **设备型号**（`Device`）—— 那是机型 / 容量 / 系统版本，与「当前网络」
    ///     没有任何关系，它在硬件页有专门的位置；
    ///   · **卡槽**（`Slot`）—— 下面那张「SIM Slot」卡片就是它的选择器，同一页
    ///     画两遍只会让人分不清哪个能点；
    ///   · **重复的 RSRP** —— 两边各有一行。保留这一份（读的是 `copyCellInfo`，
    ///     是这一页的主体读数），去掉刷新引擎那一份。
    private var infoPanel: some View {
        let info = service.slotInfo
        return Panel("Current network", systemImage: "antenna.radiowaves.left.and.right") {
            // 10 → 8（2026-10-16，压卡片高度）：这一张有 11 行，行间共十处间隔，
            // 收 20 pt —— 三页里这一张减得最多，因为它本来就最高。
            VStack(alignment: .leading, spacing: 8) {
                if let name = info?.carrierName {
                    infoRow("Carrier", name)
                }
                if let name = info?.networkName, name != info?.carrierName {
                    // 和运营商名相同时不重复一行 —— 中国移动的卡上这两个就是同一个值，
                    // 原版会连写两遍。
                    infoRow("Network", name)
                }
                if let bars = info?.bars, let maxBars = info?.maxBars, maxBars > 0 {
                    infoRow("Signal", "\(bars) / \(maxBars)")
                }
                if let rat = info?.ratDisplay {
                    infoRow("Technology", rat)
                }
                if let band = info?.band {
                    infoRow("Serving band", servingBandLabel(band, rat: info?.rat))
                }
                if let rsrp = info?.rsrp {
                    infoRow("RSRP", "\(rsrp) dBm")
                }
                if let snr = info?.snr {
                    infoRow("SNR", String(format: "%.1f dB", snr))
                }
                // 小区标识。与「服务频段」来自同一次 `copyCellInfo` —— 上游 CellularInfo
                // 「卡 1 → 射频」那一栏显示的就是这三个值。
                if let pci = info?.pci {
                    infoRow("Physical Cell ID", String(pci))
                }
                if let tac = info?.tac {
                    infoRow("Tracking Area Code", String(tac))
                }
                if let lac = info?.lac {
                    // LTE/NR 下它与 TAC 同值（桥接层就是这么填的）。2G/3G 时那一个键
                    // 不出现，这一行也就整行不显示。
                    infoRow("Location Area Code", String(lac))
                }
                if let cellId = info?.cellId {
                    infoRow("Cell ID", String(cellId))
                }

                // ── 下半截：自动刷新引擎 ────────────────────────────────────────
                //
                // 分隔线在这里是必需的：上下两半的字号、灰度完全一样，不加线的话
                // 「State」那一行会被读成上面网络的又一个字段。见 `RefreshStatusRows`。
                Divider().overlay(Color.mwCardStroke)

                RefreshStatusRows(config: refreshConfig)
            }
        }
    }

    /// 服务小区频段号转成通行写法。
    ///
    /// **频段号本身不含制式信息** —— 同一个数字在 LTE 下是 `B8`、在 NR 下是 `n8`。
    /// 所以制式读不到时只显示数字，不要瞎猜一个前缀。
    private func servingBandLabel(_ band: Int, rat: String?) -> String {
        guard let rat else { return String(band) }
        if rat.contains("NR") { return "n\(band)" }
        if rat.contains("LTE") { return "B\(band)" }
        if rat.contains("CDMA") { return "BC\(band)" }
        return String(band)
    }

    /// 一行「标签 —— 值」。读数走 `Text(verbatim:)`：它是测量值，不是文案。
    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(AppFont.text(13))
                .foregroundStyle(Color.mwMuted)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(AppFont.text(13, weight: .semibold))
                .multilineTextAlignment(.trailing)
        }
    }

    private var slotPanel: some View {
        Panel("SIM Slot", systemImage: "simcard") {
            Picker("SIM Slot", selection: $service.slot) {
                ForEach(service.slots, id: \.self) { index in
                    Text(verbatim: Strings.text("Slot %d", index)).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - 频段网格

    @ViewBuilder
    private var bandPanels: some View {
        if let info = service.bandInfo {
            let rats = visibleRats
            if rats.isEmpty {
                Panel("Bands", systemImage: "antenna.radiowaves.left.and.right") {
                    Text("No bands reported")
                        .font(AppFont.text(13))
                        .foregroundStyle(Color.mwMuted)
                }
            } else {
                ForEach(rats, id: \.self) { rat in
                    bandPanel(rat: rat, info: info)
                }
            }
        }
    }

    /// 界面上画哪些制式。**只画 4G**（2026-10-05 按要求收窄）。
    ///
    /// 3G / 2G / 5G 的分组不再展示，但**它们不会被清空**：`save()` 只把这一组交给
    /// 写回，其余制式由桥接层从原 `fActiveBands` 里原样带回去（见 `BandSet.payload`
    /// 的 `only:`）。**「不展示」和「禁用」是两件事** —— 改这里时别顺手把 `only:`
    /// 换成 `info.editable`，那等于把 3G / 2G 全部关掉。
    ///
    /// 判据用 `family == .lte` 而不是比对 rawKey：rawKey 在不同 iOS 版本上有
    /// `LTE` / `kCTCellMonitorRadioAccessTechnologyLTE` 等写法，`Family` 已经
    /// 把这件事收敛过了。
    private var visibleRats: [RadioAccessTechnology] {
        (service.bandInfo?.editable ?? []).filter { $0.family == .lte }
    }

    /// 一个制式的频段网格。现在页面上只有 4G 一个（见 `visibleRats`）。
    ///
    /// 没有用 `Panel`：它的 `trailing` 只收一个 `Text`，放不下「全选 / 取消全选」两个
    /// 按钮，而把这两个按钮挪到内容里会多占一整行。卡片底色、描边、圆角用的是同一组
    /// 设计 token，视觉上与 `Panel` 一致。
    ///
    /// ── 2026-10-15：默认折叠 ────────────────────────────────────────────────
    ///
    /// 一进页面就是一屏 24 个可点的格子，而这一页的每一次勾选都可能被「保存」写进
    /// 基带。折叠之后要先展开才能勾 —— 多出来的那一次点击，正是这一页唯一需要的缓冲。
    ///
    /// **折叠时标题旁边补一个「选了几个 / 一共几个」**：不然收起之后这一页什么都不说，
    /// 用户得逐张展开才知道自己锁了什么，而「我到底锁了哪些」正是来这一页要看的第一件事。
    ///
    /// 「全选 / 清空」在折叠时**不画**。它们是盲操作 —— 看不到勾选状态时一键改掉全部
    /// 频段，而下一步就是写基带，这正是要避免的组合。展开之后它们照常在。
    private func bandPanel(rat: RadioAccessTechnology, info: BandSet) -> some View {
        let bands = info.supportedBands(of: rat)
        let active = selection[rat] ?? []
        let isExpanded = expandedRats.contains(rat)
        // 12 → 10（2026-10-16，压卡片高度）：标题行与下面的频段列表之间。
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // 整行标题都是折叠按钮（不只是那个小三角）—— 手指按得中比看得清更难，
                // 而这一行除了文字没有别的东西。
                Button {
                    if isExpanded {
                        expandedRats.remove(rat)
                    } else {
                        expandedRats.insert(rat)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(AppFont.text(11, weight: .bold))
                            .foregroundStyle(Color.mwAccent)
                            // 90° 而不是换成另一个符号：同一个图形转过去，读的人
                            // 一眼能连上是「同一个东西换了姿态」。
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(verbatim: rat.title)
                            .mwCaption()
                        if !isExpanded {
                            Text(verbatim: "\(active.count) / \(bands.count)")
                                .font(AppFont.text(12, weight: .semibold))
                                .foregroundStyle(Color.mwAccent)
                        }
                    }
                    // 让整行的空白处也能点，而不是只有图标和文字那一小块。
                    .contentShape(Rectangle())
                }
                // `.plain` 覆盖外层那个 `.borderless`：标题不是「一行里的一个动作」，
                // 它是这一整块的开合开关，不该带按钮的高亮底色。
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                if isExpanded {
                    // 与维护页那两个并排按钮同一个理由：不加 `.borderless` 的话，
                    // 点一个会把行内两个都触发。
                    Button("Select All") { setAll(rat, in: bands, on: true) }
                        .font(AppFont.text(12, weight: .semibold))
                    Button("Clear") { setAll(rat, in: bands, on: false) }
                        .font(AppFont.text(12, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .tint(.mwAccent)

            if isExpanded {
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(bands, id: \.self) { band in
                        bandCell(rat: rat, band: band, isOn: active.contains(band.number))
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.mwCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwCardStroke, lineWidth: 1)
        )
    }

    /// 一个频段格子。
    ///
    /// 圆圈与文字在 2026-10-04 整体放大（15→19 / 13→15）：4 列网格里每个格子还有
    /// 富余宽度，而原来那个尺寸在手机上偏小 —— 手指按得中，但**看得清**是另一回事，
    /// 而这一页的每一次勾选都会写进基带，看清楚再点是前提。
    /// 缩小时用 `minimumScaleFactor`，所以放大不会把「TD 34」这类长标签挤断行。
    private func bandCell(rat: RadioAccessTechnology, band: Band, isOn: Bool) -> some View {
        Button {
            toggle(rat, band.number)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isOn ? Color.mwAccent : Color.mwMuted.opacity(0.45))
                Text(verbatim: band.label)
                    .font(AppFont.text(15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            // 让整个格子都是命中区域，而不是只有图标和文字那一小块。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    /// 四个动作按钮，并排一行，在页面最顶部（「当前网络」卡片上方）。
    ///
    /// 2026-10-14 定稿的排布与顺序：**恢复默认 → 重启蜂窝网络服务 → 刷新 → 保存**。
    ///
    /// 为什么是这四个挤成一排：这一页的操作以前散在两处 —— 保存与刷新在导航栏右上，
    /// 两个逃生通道在页面最底部。右上角那一版的问题是「保存」这个最常用的动作离内容
    /// 最远，而底部那两个要滚过整页频段网格才够得着。四合一之后，勾完同一屏里就能
    /// 按下保存，出事了也一眼能看到「恢复」。
    ///
    /// 顺序即优先级：前两个救场，后两个日常。**把保存排最后不是降级** —— 它旁边必须
    /// 有那两个逃生通道作参照：这一页写的是基带，而基带写错了靠的就是它们。
    ///
    /// 图标四枚，风格统一（都是 SF Symbols，16pt 半粗，线性实心混排）：
    /// `arrow.counterclockwise`（恢复）、`antenna.radiowaves.left.and.right.slash`
    /// （重启）、`arrow.clockwise`（刷新）、`checkmark`（保存）。
    private var actionRow: some View {
        // 显式的 `VStack` 而不是「一个 body 里两条语句」—— 前者不依赖隐式 result
        // builder，任何工具链都编得过；视觉上就是「一排按钮 + 一行提示」。
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                actionButton(title: "Restore",
                             systemImage: "arrow.counterclockwise",
                             accessibilityLabel: "Restore Default",
                             // **灰色**，不是主题青（2026-10-14 要求）。
                             //
                             // 它是这一排里唯一的「逃生通道」：按下就把 active 整个换回
                             // supported，是一次不可逆的覆盖。与另外三个日常动作同色的话，
                             // 手指落在这一排上分不出哪个是「会改回去」的那个 ——
                             // 灰下来之后，它与「重启 / 刷新 / 保存」在视觉上就是两类。
                             // 只是配色降级，**不是禁用**：真出事时它必须还能按。
                             tint: .mwMuted,
                             // 读不到的时候「恢复」一样写不进去（桥接层拿不到那个对象
                             // 就直接失败），所以跟「刷新」一起禁掉 —— 不给一个按了
                             // 没反应的按钮。
                             disabled: isInitialLoad || service.availability == .unavailable) {
                    showRestoreConfirm = true
                }
                actionButton(title: "Restart",
                             systemImage: "antenna.radiowaves.left.and.right.slash",
                             accessibilityLabel: "Restart Cellular Service",
                             tint: .mwDanger,
                             disabled: isInitialLoad) {
                    showRestartConfirm = true
                }
                actionButton(title: "Refresh",
                             systemImage: "arrow.clockwise",
                             accessibilityLabel: "Refresh",
                             tint: .mwAccent,
                             disabled: isInitialLoad || service.availability == .unavailable) {
                    service.load(slot: service.slot)
                }
                actionButton(title: "Save",
                             systemImage: "checkmark",
                             accessibilityLabel: "Save",
                             tint: .mwAccent,
                             disabled: !hasUnsavedChanges) {
                    // 第 2 层：默认还要再确认一次。
                    if saveConfirm {
                        showSaveConfirm = true
                    } else {
                        save()
                    }
                }
            }
            // 与维护页同一条理由：一行里放多个按钮时默认样式会把整行当成一个
            // 命中区域，点哪儿都会把行内所有按钮一起触发。
            .buttonStyle(.borderless)

            // 提示文案回答「我改的东西存了没」。它跟着按钮走 —— 按钮挪到顶部之后，
            // 这句话就不再需要滚到底才看得到了。
            Text(hasUnsavedChanges
                 ? "You have unsaved changes. Tap \"Save\" to write them to the modem."
                 : "Saved changes are written to the modem straight away.")
                .font(AppFont.text(11))
                .foregroundStyle(Color.mwMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 与维护页 `DeviceActionButton` 同构：上图标、下文字、等宽、居中。
    ///
    /// 四枚按钮共用这一个外形（等宽、圆角底色、图标在上）—— 长得不一样只会让人
    /// 在按下去之前多犹豫一次，而这一页按下去就会改基带。
    ///
    /// 闭包类型写成 `@MainActor () -> Void` 而不是 `() -> Void`：闭包体里要碰主
    /// actor 隔离的状态，而项目默认主 actor 隔离，`() -> Void` 会在这里丢掉隔离域。
    private func actionButton(title: LocalizedStringKey,
                              systemImage: String,
                              accessibilityLabel: LocalizedStringKey,
                              tint: Color,
                              disabled: Bool = false,
                              tap: @escaping @MainActor () -> Void) -> some View {
        // 用 `Button { tap() } label:` 而不是 `Button(action: tap)`：后者要把闭包直接
        // 交给 SwiftUI，会再撞一次上面那个隔离域转换的问题。
        Button {
            tap()
        } label: {
            // ── 2026-10-17：整排矮一截（按要求「四个按钮高度调小一些」）──────
            //
            // 上下内边距 10 → 6（合计 −8）、图标 16 → 15、图标与文字间距 4 → 3，
            // 一个按钮大约矮 10 pt。四个并排时这一排本来就是页面上最占高度的一块，
            // 而它上面只有导航栏 —— 压下来整页第一屏能多露出一张卡片。
            //
            // 文字仍 12 semibold：再小在窄屏上就要靠 `minimumScaleFactor` 缩，
            // 四个按钮的字号一缩就不一致了，比多那 2 pt 高度更难接受。
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(AppFont.text(12, weight: .semibold))
                    // 四列里每列只有屏宽的四分之一多一点，窄屏上要能缩。
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var unavailablePanel: some View {
        Panel("Bands", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Unavailable")
                    .font(AppFont.text(14, weight: .semibold))
                    .foregroundStyle(Color.mwDanger)
                // 说清两种可能。只写「不可用」会让人以为是 App 坏了。
                Text("The baseband did not answer. This usually means the CommCenter entitlement is not in effect for this build, or there is no SIM in the device. Reading bands is refused the same way as writing them, so nothing here can be edited until it works.")
                    .font(AppFont.text(12))
                    .foregroundStyle(Color.mwMuted)
            }
        }
    }

    private func bannerPanel(_ text: String) -> some View {
        Panel {
            Text(verbatim: text)
                .font(AppFont.text(13))
                .foregroundStyle(bannerIsError ? Color.mwDanger : Color.mwAccent)
        }
    }

    // MARK: - 横幅的挂与收

    /// 挂一条结果横幅，**并在 5 秒后自动收起**。
    ///
    /// 5 秒是「够读完一句」与「不碍事」之间的折中：这几条文案都只有一行
    /// （"Band settings saved." / "Cellular service is restarting." 之类），
    /// 扫一眼就够；而重启蜂窝服务那一条尤其不该久留 —— 它说的是「正在重启」，
    /// 网络一回来这句话就是错的。
    ///
    /// 失败也走 5 秒：那条文案（"Could not restart the cellular service."）同样
    /// 只是一次动作的回执，而真正的失败原因在别处（关于页的 Root tool 那一行）。
    ///
    /// ── 2026-10-17：加 `duration` 参数，默认仍是 5 秒 ────────────────────────
    ///
    /// 唯一改时长的是「重启后 Modem 把频段退回去了」那一条：它不是一次动作的回执，
    /// 而是一件**需要用户处理**的事（要去点保存重新写入），5 秒不够看清就没了。
    private func showBanner(_ text: String, isError: Bool, duration: Double = 5) {
        banner = text
        bannerIsError = isError
        let token = bannerToken &+ 1
        bannerToken = token
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            // 这 5 秒里又出过新横幅（或它已被别处清掉）就什么都不做。
            guard bannerToken == token else { return }
            banner = nil
        }
    }

    /// 主动收起横幅（用户改了勾选、换了卡槽）。**递增序号**，让在途的那次延迟
    /// 收尾作废 —— 不然它可能在 5 秒后把一条刚挂上的新横幅抹掉。
    private func dismissBanner() {
        bannerToken = bannerToken &+ 1
        banner = nil
    }

    // MARK: - 编辑

    private func toggle(_ rat: RadioAccessTechnology, _ value: Int) {
        var set = selection[rat] ?? []
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
        selection[rat] = set
        hasUnsavedChanges = true
        // 用户开始改新的了 —— 上一轮的写后校验连同它的重试一起作废，否则它会在
        // 几次回读之后弹一句「Modem 没确认」，说的却是用户早就改掉的旧设置。
        cancelVerify()
        cancelRestartCheck()
        // 用户已经开始改了，上一次动作的回执就不再成立 —— 连同它那个在途的
        // 定时器一起作废（见 `dismissBanner`）。
        dismissBanner()
    }

    private func setAll(_ rat: RadioAccessTechnology, in bands: [Band], on: Bool) {
        selection[rat] = on ? Set(bands.map(\.number)) : []
        hasUnsavedChanges = true
        cancelVerify()
        cancelRestartCheck()
        dismissBanner()
    }

    /// 把刚从 Modem 读回来的 active 灌进界面状态。
    ///
    /// **只在没有未保存修改、也没有在途写后校验时覆盖**：读回来的时机不由界面控制
    /// （进页面、换卡槽、保存后刷新都会触发），无条件覆盖会把用户刚勾的东西抹掉。
    ///
    /// `verify != nil` 那一条是 2026-10-17 补的：保存成功后 `hasUnsavedChanges`
    /// 已经置为 false，光靠它挡不住「刚写完就读到旧值」的那一读 —— 校验窗口内
    /// 由 `verifyReadback` 自己决定界面该不该动（见 `BandWriteVerify`）。
    ///
    /// `restartCheckActive` 同理：重启蜂窝服务之后的第一次回读，结果由
    /// `compareAfterRestart` 处理，不让它先闪一下再被改回来。
    private func syncSelectionFromModem() {
        guard let info = service.bandInfo,
              !hasUnsavedChanges,
              verify == nil,
              !restartCheckActive else { return }
        var next: [RadioAccessTechnology: Set<Int>] = [:]
        for rat in info.supported.keys {
            next[rat] = info.activeNumbers(of: rat)
        }
        selection = next
    }

    // MARK: - 动作

    private func save() {
        // 只提交界面上画出来的制式（现在就是 4G）。没画出来的 3G / 2G 由桥接层
        // 从原对象里原样带回去 —— 不展示不等于禁用。
        let expected = selection
        let ok = service.write(selection: selection, only: visibleRats, slot: service.slot)
        showBanner(ok
            ? Strings.text("Band settings saved.")
            : Strings.text("Could not write the band settings. Nothing was changed."),
            isError: !ok)
        hasUnsavedChanges = false
        if ok {
            // ── 2026-10-17：成功路径不再「立刻回读」 ───────────────────────────
            //
            // `write()` 返回成功只代表 XPC 收下了，CommCenter 里 `fActiveBands`
            // 还要过一小会儿才变。立刻 `load()` 会读到旧值，再经
            // `syncSelectionFromModem` 铺回界面 —— 用户看到的就是「保存后过一两秒
            // 勾选自己跳回改之前」。改成延迟 + 校验，见 `BandWriteVerify`。
            beginVerify(expected: expected)
        } else {
            // 写失败：没有「等落地」这回事，直接回读真实状态，让界面回到 Modem
            // 的样子，而不是停在一个「看起来改了、其实没改」的勾选上。
            cancelVerify()
            service.load(slot: service.slot)
        }
    }

    private func restoreDefault() {
        // 恢复默认 = 把 active 整个换成 supported，所以预期值就是「可见制式下
        // 全部支持的频段」。写入后同样存在落地延迟，走同一套校验。
        let expected: [RadioAccessTechnology: Set<Int>] = service.bandInfo.map { info in
            var next: [RadioAccessTechnology: Set<Int>] = [:]
            for rat in visibleRats {
                next[rat] = Set((info.supported[rat] ?? []).map(\.number))
            }
            return next
        } ?? [:]
        let ok = service.restoreDefault(slot: service.slot)
        showBanner(ok
            ? Strings.text("Default band settings restored.")
            : Strings.text("Could not restore the default band settings."),
            isError: !ok)
        hasUnsavedChanges = false
        if ok {
            beginVerify(expected: expected)
        } else {
            cancelVerify()
            service.load(slot: service.slot)
        }
    }

    private func restartCellular() {
        let ok = DeviceActions.restartCommCenter()
        showBanner(ok
            ? Strings.text("Cellular service is restarting.")
            : Strings.text("Could not restart the cellular service."),
            isError: !ok)
        // ── 2026-10-17：重启之后要**自己验一次**，不能等用户发现勾选跳回去了 ──
        //
        // 真机现象：保存后 5 秒内一切正常（写后校验也确认过），可一旦点这个按钮，
        // 几秒后勾选回到改之前。也就是「CommCenter 的运行时状态改了，重启后读回来
        // 的还是旧值」。
        //
        // 真因在 Modem / CommCenter 的持久化那一侧（RootTool 那一处已改成先
        // SIGTERM 再兜底 SIGKILL，见 `do_restart_commcenter`）。App 这边能做的是
        // **别让它悄无声息地发生**：重启后等 CommCenter 回来，把实际值与我们确认
        // 过的值比一次；退回去了就把勾选恢复成用户想要的，并说明「需要重新写入」。
        if ok, let expected = confirmedSelection {
            scheduleRestartCheck(expected: expected)
        }
    }

    // MARK: - 重启后校验

    /// 重启蜂窝服务之后，等 CommCenter 回来并把频段读出来，与我们确认过的值比一次。
    ///
    /// 为什么要「等」：`kill` 是异步的，CommCenter 退出、launchd 重新拉起、基带重新
    /// 附着，加起来几秒钟。这段时间里的读要么失败，要么还是**老进程**在回答（它手里
    /// 是刚写进去的新值），早早比一次会得出「一切正常」的假结论。
    ///
    /// 判定「已经换了一个进程」用两条线索：① 读到过失败（老进程已经没了）；
    /// ② 或者已经过了 8 秒（老进程无论如何活不到这时）。之后再读到第一份成功结果
    /// 才开始比。
    ///
    /// 走 `probeBands` 而不是 `service.load`：后者会把 `availability` 打成
    /// `.unavailable`，整页在重启期间闪一次「不可用」。
    private func scheduleRestartCheck(expected: [RadioAccessTechnology: Set<Int>]) {
        restartCheckTask?.cancel()
        restartCheckActive = true
        restartCheckTask = Task { @MainActor in
            let started = Date()
            var sawDown = false
            var mismatchStreak = 0
            while !Task.isCancelled, Date().timeIntervalSince(started) < 20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                guard let info = await service.probeBands(slot: service.slot) else {
                    // 读不到 = CommCenter 正处在「被杀了 / 还没起来」的窗口里。
                    sawDown = true
                    continue
                }
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(started)
                if !sawDown && elapsed < 8 {
                    // 从来没读到过失败，而且时间还短 —— 回答的可能是老进程，再等等。
                    continue
                }
                if matches(info, expected) {
                    finishRestartCheck(expected: expected, info: info)
                    return
                }
                // 不一致也要**连读两次**才算数：刚起来的 CommCenter 第一拍偶尔会给
                // 一份还没填全的配置，拿它当「回退」会误报。
                mismatchStreak += 1
                if mismatchStreak >= 2 {
                    finishRestartCheck(expected: expected, info: info)
                    return
                }
            }
            // 超时（CommCenter 一直没回来）：什么都不改，界面保持原样。
            restartCheckActive = false
            restartCheckTask = nil
        }
    }

    /// 一份读回来的频段，是否就是我们确认过的那一份（只比 `expected` 里出现的制式）。
    private func matches(_ info: BandSet,
                         _ expected: [RadioAccessTechnology: Set<Int>]) -> Bool {
        for (rat, bands) in expected where info.activeNumbers(of: rat) != bands {
            return false
        }
        return true
    }

    /// 比对并收尾。
    private func finishRestartCheck(expected: [RadioAccessTechnology: Set<Int>],
                                    info: BandSet) {
        var actual: [RadioAccessTechnology: Set<Int>] = [:]
        for rat in expected.keys {
            actual[rat] = info.activeNumbers(of: rat)
        }
        restartCheckActive = false
        restartCheckTask = nil

        // 无论一致与否都把卡片刷新一次：`probeBands` 刻意不动界面状态，
        // 重启之后「当前网络」那一块也需要一份新数据。
        service.load(slot: service.slot)

        guard actual != expected else { return }

        // 退回去了。界面恢复成用户**上次保存的那一份**，并明确标成「未保存」——
        // 这一页的底色是「界面必须说实话」：勾选回到旧值本身没错，错的是不说一声。
        // 而把它改回旧值也不是答案：那是用户明确要的配置，他要的是「重新写进去」。
        selection = expected
        hasUnsavedChanges = true
        showBanner(Strings.text("The modem went back to the previous bands after the restart. Your last saved selection is restored — tap \"Save\" to write it again."),
                   isError: true,
                   duration: 12)
    }

    private func cancelRestartCheck() {
        restartCheckTask?.cancel()
        restartCheckTask = nil
        restartCheckActive = false
    }

    // MARK: - 写后校验

    /// 保存成功后开始一轮写后校验。见 `BandWriteVerify`。
    private func beginVerify(expected: [RadioAccessTechnology: Set<Int>]) {
        cancelVerify()
        cancelRestartCheck()
        verify = BandWriteVerify(expected: expected, slot: service.slot)
        scheduleVerifyRead(after: BandWriteVerify.firstDelay)
    }

    /// 排一次「回读」。写入后 Modem 需要一小段时间才生效，所以第一次要先等 ——
    /// 这一段等待就是上游 `asyncAfter(0.5)` 在做的事。
    private func scheduleVerifyRead(after delay: Double) {
        verifyTask?.cancel()
        verifyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let pending = verify else { return }
            service.load(slot: pending.slot)
            // 等这一读真正落地再比，否则比的是上一次的 `bandInfo`。
            await waitForLoadToFinish()
            guard !Task.isCancelled, verify != nil else { return }
            verifyReadback()
        }
    }

    /// 等 `service.load` 这一读落地（`isLoading` 由 `load` 置起、`apply` 之后落下）。
    ///
    /// 不用 `bandInfo` 的 `onChange` 判：回读值与上一次**完全相同**时不会触发
    /// `onChange`，校验就永远卡在等一个不来的事件上。`isLoading` 是这一读自己的
    /// 进度，谁来读都一样。
    private func waitForLoadToFinish() async {
        // 上限 2 秒：`copyCellInfo` 最坏等 1 秒，再留一倍余量。超时也往下走 ——
        // 读不到就按「没确认」处理（会重试或认账），不把校验悬在半空。
        var waited = 0.0
        while service.isLoading && waited < 2.0 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
    }

    /// 一次回读的结果：一致 → 收工；不一致 → 重试，次数用完才认账。
    private func verifyReadback() {
        guard let pending = verify else { return }
        var actual: [RadioAccessTechnology: Set<Int>] = [:]
        // 读不到 `bandInfo`（基带无响应）按「没确认」处理，而不是直接 return ——
        // 那样 `verify` 会一直挂着，`syncSelectionFromModem` 就再也不放行了。
        if let info = service.bandInfo {
            for rat in pending.expected.keys {
                actual[rat] = info.activeNumbers(of: rat)
            }
        }
        let matched = service.bandInfo != nil && actual == pending.expected

        if matched {
            // 落地了。放开守卫，把（已经一致的）值铺一次，之后恢复正常联动。
            // 记下这一份「Modem 确认过的勾选」—— 重启蜂窝服务之后要拿它对比。
            confirmedSelection = pending.expected
            verify = nil
            verifyTask = nil
            syncSelectionFromModem()
            return
        }

        if pending.attempt + 1 < BandWriteVerify.maxAttempts {
            var next = pending
            next.attempt += 1
            verify = next
            scheduleVerifyRead(after: BandWriteVerify.retryDelay)
            return
        }

        // 三次都不一致：Modem 确实没接受这次写入。这时才按真实值铺回界面，
        // 并且把原因说出来 —— 与「界面抢跑」区分开，否则用户无从判断。
        verify = nil
        verifyTask = nil
        showBanner(Strings.text("The modem did not confirm the new band settings."),
                   isError: true)
        syncSelectionFromModem()
    }

    private func cancelVerify() {
        verifyTask?.cancel()
        verifyTask = nil
        verify = nil
    }
}

/// 保存成功后「写 → 回读」的校验现场。
///
/// ## 为什么需要它
///
/// `write()` 的 XPC 返回成功**不等于**新值已经在 CommCenter 里生效：
/// `getBandInfo:` 在返回后的一小段时间里仍然给旧的 `fActiveBands`。原先 `save()`
/// 是「返回成功就立刻 `load()`」，那一读正好落在这个窗口里 —— 读到旧值，
/// `syncSelectionFromModem()` 又把旧值无条件铺回界面，于是表现为
/// **「保存后过一两秒，勾选自己跳回改之前」**。
///
/// 上游 CellularInfo 早就撞过同一个坑，它用 `asyncAfter(0.5)` 延迟刷新绕开
/// （注释原话：「延迟刷新 这样UI就不会已选/未选的频段CheckBox闪一下了」）。
/// 这里把「延迟」和「校验」一起做，因为延迟只能避开窗口、不能证明写成功：
///
///   1. 先记下这次想写成的 `expected`，等 `firstDelay` 再回读；
///   2. 与 `expected` 一致就收工；
///   3. 不一致**不动界面**（`syncSelectionFromModem` 在 `verify != nil` 时直接
///      返回），隔 `retryDelay` 再读，最多读 `maxAttempts` 次（合计约 3.2 秒）；
///   4. 全都对不上才认账：按 Modem 的真实值铺回界面，并明确提示
///      「Modem 没有确认这次设置」。
///
/// 第 4 步是这套东西比单纯延迟更有价值的地方 —— 真没写进去的时候，界面必须
/// 说实话，而不是停在一个假的勾选状态上。
private struct BandWriteVerify {
    /// 这次想写成的勾选，按制式分组。
    let expected: [RadioAccessTechnology: Set<Int>]
    /// 写的是哪张卡。回读必须读同一张。
    let slot: Int
    /// 已经重试过几次（首次回读不计）。
    var attempt = 0

    /// 回读总次数（首次 + 2 次重试）。
    static let maxAttempts = 3
    /// 首次回读前等多久。量级对齐上游那 0.5 秒，再留一点余量。
    static let firstDelay: Double = 0.8
    /// 重试间隔。三次加起来约 3.2 秒，仍在「人会觉得是刚保存完」的范围里。
    static let retryDelay: Double = 1.2
}
