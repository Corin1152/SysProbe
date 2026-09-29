import SwiftUI

/// 「频段设置」。读 / 写基带允许使用的频段。
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
///   4. **「重启蜂窝服务」** —— 另一个逃生通道，与保存解耦，让用户自己决定何时重启；
///   5. **不可用时不画任何可点的东西**，并说明原因（没权限 / 无卡）。
///
/// 第 5 条尤其重要：CommCenter 权限没生效时，读会失败、写会**静默失败**
/// （调用不抛异常、不打日志）。不给一个「点了没反应」的保存按钮。
struct BandEditorView: View {
    @StateObject private var service = BandService()

    /// 当前卡槽。单卡设备上恒为 1。
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
    /// 第 4 层：这一项是否还出现在设置菜单里。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    @State private var showEntryTips = false
    @State private var showSaveConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showRestartConfirm = false

    /// 操作结果横幅。成功与失败共用一条 —— 同一时刻只会有一个结果。
    @State private var banner: String?
    @State private var bannerIsError = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.mwCanvas
            Backdrop(glow: .mwAccent)
            Form {
                if let banner {
                    Section {
                        Text(verbatim: banner)
                            .font(AppFont.text(13))
                            .foregroundStyle(bannerIsError ? Color.mwDanger : Color.mwAccent)
                    }
                }

                switch service.availability {
                case .unavailable:
                    unavailableSection
                case .unknown, .available:
                    if service.slots.count > 1 { slotSection }
                    bandSections
                    actionSection
                    entryToggleSection
                }
            }
            .scrollContentBackground(.hidden)
            .disabled(service.isLoading)
            .overlay {
                if service.isLoading {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .navigationTitle("Network Bands")
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
            // 换卡槽必须重新读 —— 每张卡的频段配置是独立的。缓存也是按卡槽存的，
            // 不重读的话桥接层手里还是上一张卡的对象。
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

    // MARK: - 分区

    private var unavailableSection: some View {
        Section {
            Label("Unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.mwDanger)
        } header: {
            Text("Network Bands")
        } footer: {
            // 说清两种可能。只写「不可用」会让人以为是 App 坏了。
            Text("The baseband did not answer. This usually means the CommCenter entitlement is not in effect for this build, or there is no SIM in the device. Reading bands is refused the same way as writing them, so nothing here can be edited until it works.")
        }
    }

    private var slotSection: some View {
        Section {
            Picker("SIM Slot", selection: $slot) {
                ForEach(service.slots, id: \.self) { index in
                    Text(verbatim: Strings.text("Slot %d", index)).tag(index)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("SIM Slot")
        } footer: {
            Text("Each SIM keeps its own band configuration.")
        }
    }

    @ViewBuilder
    private var bandSections: some View {
        if let info = service.bandInfo {
            let rats = info.editable
            if rats.isEmpty {
                Section {
                    Text("No bands reported")
                        .foregroundStyle(Color.mwMuted)
                }
            } else {
                ForEach(rats, id: \.self) { rat in
                    bandSection(rat: rat, info: info)
                }
            }
        }
    }

    private func bandSection(rat: RadioAccessTechnology, info: BandSet) -> some View {
        let bands = info.supportedBands(of: rat)
        let active = selection[rat] ?? []
        return Section {
            // 全选 / 取消全选做成**第一行**而不是 Section header 里的按钮：
            // header 里的 Button 在 `Form` 里命中区域不可靠，而这一页最不能出的
            // 问题就是「点了没反应」。
            HStack {
                Button("Select All") { setAll(rat, in: bands, on: true) }
                Spacer()
                Button("Clear") { setAll(rat, in: bands, on: false) }
            }
            .font(AppFont.text(13, weight: .semibold))
            // 与维护页那两个并排按钮同一个理由：不加 `.borderless` 的话，
            // 点一个会把行内两个都触发。
            .buttonStyle(.borderless)

            ForEach(bands, id: \.self) { band in
                Button {
                    toggle(rat, band.number)
                } label: {
                    HStack {
                        Text(verbatim: band.label)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if active.contains(band.number) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.mwAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
        } header: {
            Text(verbatim: rat.title)
        } footer: {
            if rat == info.editable.last {
                Text("Only bands the device reports as supported are listed. Unchecking a band removes it from the list the network may use.")
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button("Save") {
                // 第 2 层：默认还要再确认一次。
                if saveConfirm {
                    showSaveConfirm = true
                } else {
                    save()
                }
            }
            .disabled(!hasUnsavedChanges)

            Button("Restore Default") { showRestoreConfirm = true }

            // 与保存**刻意解耦**：改完频段不一定要立刻重启，而且重启会短暂断网。
            // 把它并进保存流程等于替用户做了决定。
            Button("Restart Cellular Service") { showRestartConfirm = true }
        } header: {
            Text("Actions")
        } footer: {
            Text(hasUnsavedChanges
                 ? "You have unsaved changes."
                 : "Saved changes are written to the modem straight away.")
        }
    }

    private var entryToggleSection: some View {
        Section {
            Toggle("Show in Settings", isOn: $showBandEditor)
        } footer: {
            Text("Turning this off hides this page from the settings menu. There is no way to bring it back from inside the app — reinstall to restore it.")
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
        guard let info = service.bandInfo else { return }
        let ok = service.write(selection: selection, slot: slot)
        if ok {
            hasUnsavedChanges = false
            banner = Strings.text("Band settings saved.")
            bannerIsError = false
        } else {
            banner = Strings.text("Could not write the band settings. Nothing was changed.")
            bannerIsError = true
        }
        // 无论成没成都重读一次：失败时界面回到 Modem 的真实状态，
        // 而不是停在一个「看起来改了、其实没改」的勾选上。
        hasUnsavedChanges = false
        service.load(slot: slot)
        _ = info
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
