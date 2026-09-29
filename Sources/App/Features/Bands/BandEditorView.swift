import SwiftUI

/// 「频段」。读 / 写基带允许使用的频段，按 SIM 卡槽分开。
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
struct BandEditorView: View {
    @EnvironmentObject private var hardware: HardwareMonitor

    @StateObject private var service = BandService()

    /// 当前卡槽。单卡设备上恒为 1，而且界面上不会出现卡槽选择器。
    @State private var slot = 1

    /// 界面上的勾选状态：制式 → 启用的频段号。
    ///
    /// 与 `service.bandInfo.active` 分开存：前者是用户正在编辑的意图，后者是刚从
    /// Modem 读回来的事实。两者不一致就是「有未保存的修改」。
    @State private var selection: [RadioAccessTechnology: Set<Int>] = [:]
    @State private var hasUnsavedChanges = false

    // MARK: 四层警告的持久化开关

    /// 第 1 层：入口整屏警告是否已经看过。
    @AppStorage("sysprobe.bandEntryTipsDone") private var entryTipsDone = false
    /// 第 2 层：保存前是否还要确认。
    @AppStorage("sysprobe.bandSaveConfirm") private var saveConfirm = true
    /// 第 4 层：这一项是否还出现在齿轮菜单里。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    @State private var showEntryTips = false
    @State private var showSaveConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showRestartConfirm = false

    /// 操作结果横幅。成功与失败共用一条 —— 同一时刻只会有一个结果。
    @State private var banner: String?
    @State private var bannerIsError = false

    @Environment(\.dismiss) private var dismiss

    /// 频段网格：4 列。和原版一样 —— 一屏能扫完一个制式，不用滚。
    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        ZStack {
            Color.mwCanvas
            Backdrop(glow: .mwAccent)
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let banner {
                        bannerPanel(banner)
                    }

                    if service.availability == .unavailable {
                        unavailablePanel
                    } else {
                        infoPanel
                        if service.slots.count > 1 { slotPanel }
                        bandPanels
                        actionPanel
                        entryPanel
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .mwContainerWidth()
            }
            .disabled(service.isLoading)
            .overlay {
                if service.isLoading {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .navigationTitle("Bands")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 首次进入先给整屏警告。它挡在加载之前 —— 让人先看懂风险，再看数据。
            if !entryTipsDone { showEntryTips = true }
            service.load(slot: slot)
        }
        .onChange(of: service.bandInfo) { _ in
            syncSelectionFromModem()
        }
        .onChange(of: slot) { newSlot in
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
                showBandEditor = false
                dismiss()
            }
        } message: {
            Text("Incorrect band settings can cause network problems, prevent the device from registering on the network, or result in \"No Service\".\n\nDo not disable every band of a network type — that can break VoLTE, VoNR, voice calls and SMS.\n\nSettings persist across reboots. If anything goes wrong, use \"Restore Default\" or \"Restart Cellular Service\" below.\n\nThis feature is intended for advanced users.")
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
            }
        }
    }

    /// `iPhone10,3 · 64 GB · iOS 16.5.1`。
    ///
    /// 用的是 SysProbe 已经采到的系统信息，不额外查私有接口。原版显示的是机型营销名
    /// （iPhone X），那需要一张标识符→营销名的表；这里用标识符本身，信息量一样。
    private var deviceSummary: String {
        let system = hardware.snapshot.system
        var parts: [String] = []
        if system.modelIdentifier != "—" { parts.append(system.modelIdentifier) }
        if hardware.snapshot.storage.total > 0 {
            parts.append(Formatting.bytes(hardware.snapshot.storage.total))
        }
        if system.systemVersion != "—" { parts.append("iOS \(system.systemVersion)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
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
            Picker("SIM Slot", selection: $slot) {
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
            let rats = info.editable
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

    /// 一个制式的频段网格。
    ///
    /// 没有用 `Panel`：它的 `trailing` 只收一个 `Text`，放不下「全选 / 取消全选」两个
    /// 按钮，而把这两个按钮挪到内容里会多占一整行 —— 一屏要放好几个制式，那一行不划算。
    /// 卡片底色、描边、圆角用的是同一组设计 token，视觉上与 `Panel` 一致。
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

    private func bandCell(rat: RadioAccessTechnology, band: Band, isOn: Bool) -> some View {
        Button {
            toggle(rat, band.number)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Color.mwAccent : Color.mwMuted.opacity(0.45))
                Text(verbatim: band.label)
                    .font(AppFont.text(13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            // 让整个格子都是命中区域，而不是只有图标和文字那一小块。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private var actionPanel: some View {
        Panel("Actions", systemImage: "wrench.adjustable") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    // 第 2 层：默认还要再确认一次。
                    if saveConfirm {
                        showSaveConfirm = true
                    } else {
                        save()
                    }
                } label: {
                    actionLabel("Save", systemImage: "checkmark.circle", enabled: hasUnsavedChanges)
                }
                .disabled(!hasUnsavedChanges)

                Button {
                    showRestoreConfirm = true
                } label: {
                    actionLabel("Restore Default", systemImage: "arrow.counterclockwise", enabled: true)
                }

                // 与保存**刻意解耦**：改完频段不一定要立刻重启，而且重启会短暂断网。
                // 把它并进保存流程等于替用户做了决定。
                Button {
                    showRestartConfirm = true
                } label: {
                    actionLabel("Restart Cellular Service",
                                systemImage: "antenna.radiowaves.left.and.right.slash",
                                enabled: true)
                }

                Text(hasUnsavedChanges
                     ? "You have unsaved changes."
                     : "Saved changes are written to the modem straight away.")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)
            }
        }
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20)
            Text(title)
                .font(AppFont.text(14, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(enabled ? Color.mwAccent : Color.mwMuted)
        .contentShape(Rectangle())
    }

    private var entryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show in Settings", isOn: $showBandEditor)
                    .font(AppFont.text(13))
                Text("Turning this off hides this page from the gear menu. There is no way to bring it back from inside the app — reinstall to restore it.")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)
            }
        }
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
        let ok = service.write(selection: selection, slot: slot)
        banner = ok
            ? Strings.text("Band settings saved.")
            : Strings.text("Could not write the band settings. Nothing was changed.")
        bannerIsError = !ok
        // 无论成没成都重读一次：失败时界面回到 Modem 的真实状态，
        // 而不是停在一个「看起来改了、其实没改」的勾选上。
        hasUnsavedChanges = false
        service.load(slot: slot)
    }

    private func restoreDefault() {
        let ok = service.restoreDefault(slot: slot)
        banner = ok
            ? Strings.text("Default band settings restored.")
            : Strings.text("Could not restore the default band settings.")
        bannerIsError = !ok
        hasUnsavedChanges = false
        service.load(slot: slot)
    }

    private func restartCellular() {
        let ok = DeviceActions.restartCommCenter()
        banner = ok
            ? Strings.text("Cellular service is restarting.")
            : Strings.text("Could not restart the cellular service.")
        bannerIsError = !ok
    }
}
