import SwiftUI

/// 「维护」分页的分段 3 —— 频段。原来是齿轮菜单里的第二页。
///
/// 读 / 写基带允许使用的频段，按 SIM 卡槽分开。
///
/// 2026-10-11 起它不再自己撑一页：画布、光晕、导航栈、标题都由 `MaintenanceHubView`
/// 提供，这里只剩滚动容器与内容。**`ScrollView` 留在这一层**，外壳用
/// `PageHubScaffold` 而不是 `PageScaffold`（后者的内容会被塞进它自己的 `ScrollView`，
/// 变成滚动套滚动）。
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
/// 右上角只剩齿轮（装「关于」），由外壳 `PageHubScaffold` 渲染 —— 频段页不再自己
/// 声明工具栏项。
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
/// 搬成分页之后，第 1 条的意义**变得更重**：它以前是「从齿轮里点进来」的独立一层，
/// 现在它自己占一个分页，而分页里的两个分段之间只隔一次点击 —— 从「频段锁定」
/// 到「频段刷新」只要一下，一次误触就可能把 modem 刷掉线。所以那一屏警告留着。
struct BandPanels: View {

    /// 基带取数与写入。**由 `BandHubView` 注入**，不再是这里的 `@StateObject` ——
    /// 分段之间来回切会重建本视图，服务挂在视图上的话每次都重读一遍基带、
    /// 整屏盖一次转圈。详见 `BandHubView` 类型头上那段说明。
    @ObservedObject var service: BandService

    /// 设备摘要（机型 · 总容量 · iOS 版本）。
    ///
    /// **刻意不观察 `HardwareMonitor`。** 这一页原来为了显示这一行而 `@EnvironmentObject`
    /// 了它，代价是**每秒重算整页**（40 多个频段格子 + 四个动作按钮）—— 而这三个值
    /// 出厂就定死、容量十秒才变一次。改成进页面时取一次（`HardwareMonitor.deviceSummary()`）。
    @State private var deviceSummary = "—"

    /// 界面上的勾选状态：制式 → 启用的频段号。
    ///
    /// 与 `service.bandInfo.active` 分开存：前者是用户正在编辑的意图，后者是刚从
    /// Modem 读回来的事实。两者不一致就是「有未保存的修改」。
    ///
    /// **卡槽（`slot`）不在这里** —— 它跟着服务走（`service.slot`），因为「用户选的是
    /// 哪张卡」不该在切分段时丢掉。
    @State private var selection: [RadioAccessTechnology: Set<Int>] = [:]
    @State private var hasUnsavedChanges = false

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
    @State private var banner: String?
    @State private var bannerIsError = false

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
        ScrollView {
            LazyVStack(spacing: 14) {
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
                    bandPanels
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 24)
            .mwContainerWidth()
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
            // 设备摘要取一次就够（出厂就定死的机型 / 系统版本，加十秒才变一次的容量）。
            // 它是一次文件系统往返，几十微秒，放在主 actor 上无所谓。
            if deviceSummary == "—" { deviceSummary = HardwareMonitor.deviceSummary() }
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
        .onDisappear { service.stopSlotPolling() }
        // 右上角只有齿轮（装「关于」），由外壳 `PageHubScaffold` 渲染 —— 这一层
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
            banner = nil
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

    /// 设备 + 当前网络的只读状态。
    ///
    /// 每一行**只在真的有值时才画** —— 读不到就不占位置。原版会把读不到的项显示成
    /// 空白，那会让人以为「信号是 0」而不是「这一项读不到」。
    private var infoPanel: some View {
        let info = service.slotInfo
        return Panel("Current network", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Device", deviceSummary)

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
    private func bandPanel(rat: RadioAccessTechnology, info: BandSet) -> some View {
        let bands = info.supportedBands(of: rat)
        let active = selection[rat] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(verbatim: rat.title)
                    .mwCaption()
                Spacer(minLength: 8)
                // 与维护页那两个并排按钮同一个理由：不加 `.borderless` 的话，
                // 点一个会把行内两个都触发。
                Button("Select All") { setAll(rat, in: bands, on: true) }
                    .font(AppFont.text(12, weight: .semibold))
                Button("Clear") { setAll(rat, in: bands, on: false) }
                    .font(AppFont.text(12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .tint(.mwAccent)

            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(bands, id: \.self) { band in
                    bandCell(rat: rat, band: band, isOn: active.contains(band.number))
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
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(AppFont.text(12, weight: .semibold))
                    // 四列里每列只有屏宽的四分之一多一点，窄屏上要能缩。
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
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
        banner = nil
    }

    private func setAll(_ rat: RadioAccessTechnology, in bands: [Band], on: Bool) {
        selection[rat] = on ? Set(bands.map(\.number)) : []
        hasUnsavedChanges = true
        banner = nil
    }

    /// 把刚从 Modem 读回来的 active 灌进界面状态。
    ///
    /// **只在没有未保存修改时覆盖**：读回来的时机不由界面控制（进页面、换卡槽、
    /// 保存后刷新都会触发），无条件覆盖会把用户刚勾的东西抹掉。
    private func syncSelectionFromModem() {
        guard let info = service.bandInfo, !hasUnsavedChanges else { return }
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
        let ok = service.write(selection: selection, only: visibleRats, slot: service.slot)
        banner = ok
            ? Strings.text("Band settings saved.")
            : Strings.text("Could not write the band settings. Nothing was changed.")
        bannerIsError = !ok
        // 无论成没成都重读一次：失败时界面回到 Modem 的真实状态，
        // 而不是停在一个「看起来改了、其实没改」的勾选上。
        hasUnsavedChanges = false
        service.load(slot: service.slot)
    }

    private func restoreDefault() {
        let ok = service.restoreDefault(slot: service.slot)
        banner = ok
            ? Strings.text("Default band settings restored.")
            : Strings.text("Could not restore the default band settings.")
        bannerIsError = !ok
        hasUnsavedChanges = false
        service.load(slot: service.slot)
    }

    private func restartCellular() {
        let ok = DeviceActions.restartCommCenter()
        banner = ok
            ? Strings.text("Cellular service is restarting.")
            : Strings.text("Could not restart the cellular service.")
        bannerIsError = !ok
    }
}
