import Combine
import Foundation

/// 桥接层是所有卡槽共用的一条队列。
///
/// 放在**文件作用域**而不是类型里：`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` 会把
/// 类型里的 `static let` 也判成主 actor 隔离，那样下面那些 `nonisolated static func`
/// 就访问不到它了。`nonisolated(unsafe)` 是必需的 —— 全局可变状态的隔离检查，
/// 而这里本来就是刻意的跨线程共享（队列自己保证串行）。
private nonisolated(unsafe) let bandQueue = DispatchQueue(label: "com.corin.sysprobe.band")

/// 卡槽的只读状态。频段页顶部那一段用。
///
/// 每个字段都可选，而且**「没有」就是「不显示那一行」** —— 基带读不到的项不该在界面上
/// 占一行写着「未知」，那只会让人以为哪里坏了。
nonisolated struct SlotInfo: Equatable {
    var carrierName: String?
    var networkName: String?
    var bars: Int?
    var maxBars: Int?
    /// 当前网络制式，CoreTelephony 给的原始串（如 `CTRadioAccessTechnologyLTE`）。
    var rat: String?
    /// 服务小区的频段号。
    var band: Int?
    /// 物理小区 ID（PCI）。LTE 下 0–503。
    var pci: Int?
    /// 跟踪区码（TAC）。LTE/NR 才有。
    var tac: Int?
    /// 位置区码（LAC）。
    ///
    /// 桥接层在 LTE/NR 下直接把 TAC 填进这个键（2G/3G 时那一个键不出现）——
    /// 上游 CellularInfo 的界面也是这么显示的：4G/5G 两栏同一个数。
    var lac: Int?
    /// 基站 ID（Cell ID）。
    var cellId: Int?
    var rsrp: Int?
    var snr: Double?

    /// 制式转成人看的写法。
    ///
    /// 原始串长这样：`CTRadioAccessTechnologyLTE` / `CTRadioAccessTechnologyNR` /
    /// `CTRadioAccessTechnologyNRNSA` / `CTRadioAccessTechnologyWCDMA` …… 直接显示太长，
    /// 而只截后几位又会把 `NRNSA` 和 `NR` 弄混（前者是 5G NSA，后者是 5G SA）。
    /// 所以**按整串精确匹配**一张表，认不出来就原样显示。
    var ratDisplay: String? {
        guard let rat else { return nil }
        let known: [String: String] = [
            "CTRadioAccessTechnologyNRNSA": "5G (NSA)",
            "CTRadioAccessTechnologyNR": "5G (NR)",
            "CTRadioAccessTechnologyLTE": "4G (LTE)",
            "CTRadioAccessTechnologyHSUPA": "3G (HSUPA)",
            "CTRadioAccessTechnologyHSDPA": "3G (HSDPA)",
            "CTRadioAccessTechnologyWCDMA": "3G (WCDMA)",
            "CTRadioAccessTechnologyeHRPD": "3G (eHRPD)",
            "CTRadioAccessTechnologyEVDOB": "3G (EVDO-B)",
            "CTRadioAccessTechnologyEVDOA": "3G (EVDO-A)",
            "CTRadioAccessTechnologyEVDO": "3G (EVDO)",
            "CTRadioAccessTechnologyCDMA1x": "2G (CDMA 1x)",
            "CTRadioAccessTechnologyEdge": "2G (EDGE)",
            "CTRadioAccessTechnologyGPRS": "2G (GPRS)",
            "CTRadioAccessTechnologyGSM": "2G (GSM)",
        ]
        return known[rat] ?? rat
    }

    static func parse(_ raw: [String: Any]) -> SlotInfo {
        var info = SlotInfo()
        info.carrierName = raw["carrierName"] as? String
        info.networkName = raw["networkName"] as? String
        info.bars = (raw["bars"] as? NSNumber)?.intValue
        info.maxBars = (raw["maxBars"] as? NSNumber)?.intValue
        info.rat = raw["rat"] as? String
        info.band = (raw["band"] as? NSNumber)?.intValue
        info.pci = (raw["pci"] as? NSNumber)?.intValue
        info.tac = (raw["tac"] as? NSNumber)?.intValue
        info.lac = (raw["lac"] as? NSNumber)?.intValue
        info.cellId = (raw["cellId"] as? NSNumber)?.intValue
        info.rsrp = (raw["rsrp"] as? NSNumber)?.intValue
        info.snr = (raw["snr"] as? NSNumber)?.doubleValue
        return info
    }
}

/// 「频段设置」的取数与写入。
///
/// 一层薄封装，真正干活的是 `CommCenterBridge.m`（运行时解析 CoreTelephony 的私有
/// XPC）。这里负责三件事：**串行化**、**把结果翻译成界面能用的模型**、
/// 以及**把「不可用」这件事说出来**。
///
/// ## 为什么要串行化
///
/// 桥接层在 `CommCenterBridge.m` 里按卡槽缓存了读回来的 `CTBandInfo` 对象 ——
/// 写回时要用它（只替换 active，supported 原样带回去）。读和写都要碰那份缓存，
/// 所以全部走同一条串行队列。
///
/// ## 为什么读是异步、写是同步
///
/// 读发生在**进入页面时**，那一下不该让界面等 —— 失败时（没权限、无卡、基带服务
/// 正在重启）这次 XPC 可能比平时慢得多。所以读丢到后台队列，结果回主 actor。
///
/// 写是**用户按了确认之后**才发生的，而且必须当场知道成没成（失败要弹原因），
/// 所以保持同步。成功路径上它是一次毫秒级的本地 XPC 往返。
@MainActor
final class BandService: ObservableObject {

    /// 频段读写能不能用。
    ///
    /// 三态而不是 `Bool`：`unknown` 表示「还没试过」，界面不该在第一次读回来之前
    /// 就把入口画成「不可用」。
    enum Availability: Equatable {
        case unknown
        case available
        case unavailable
    }

    @Published private(set) var availability: Availability = .unknown

    /// 探测到的卡槽。单卡设备只有 `[1]`。
    ///
    /// 判据是 `sysprobe_slot_has_sim`（**确实插着卡**），不是「频段读得回来」——
    /// 频段配置是设备级的，没插卡也可能读得到。所以只有一个卡槽时界面上不会出现
    /// 卡槽选择器：给一个只有一项的分段控件，除了占地方没有别的用处。
    @Published private(set) var slots: [Int] = [1]

    /// 当前卡槽的频段。`nil` = 还没读到 / 读不到。
    @Published private(set) var bandInfo: BandSet?

    /// 当前卡槽的只读状态（运营商、网络名、信号格、制式、频段、RSRP/SNR）。
    ///
    /// 每一项都可能缺 —— 基带读不到就不显示那一行，而不是显示一个「未知」占位。
    @Published private(set) var slotInfo: SlotInfo?

    /// 正在读。
    @Published private(set) var isLoading = false

    /// 当前卡槽。
    ///
    /// **由这里记住，不再是视图的 `@State`。** 分段之间来回切会重建分段视图，而
    /// 「用户选的是哪张卡」不该跟着丢 —— 它同时决定这一页画哪张卡的频段，以及
    /// 自动刷新往守护进程下发哪个卡槽。默认 1；单卡设备上恒为 1。
    ///
    /// 是可写的：卡槽选择器直接绑它（`$service.slot`），换卡槽由调用方的
    /// `.onChange` 去重读 —— 与它原来在视图里当 `@State` 时是同一套写法。
    @Published var slot = 1

    /// 「该选哪张卡」探过没有。见 `ensureLoaded` —— 与「读过基带没有」是两件事。
    private var didProbeSlot = false

    /// 「当前网络」那一组的每秒刷新定时器（`sysprobe_slot_info`）。
    ///
    /// **只有页面停留在频段锁定分段时才跑。** 方法见 `startSlotPolling` 上的说明。
    private var slotPoller: AnyCancellable?

    // MARK: - 「当前网络」每秒刷新

    /// 开始每秒刷新 `slotInfo`（运营商 / 信号格 / RSRP / 小区标识那一组）。
    ///
    /// ── 为什么需要它 ────────────────────────────────────────────────────────
    ///
    /// 「当前网络」这一组是**实时量**：RSRP 每秒都在变，小区标识在移动中也会变。
    /// 而它原来只在进页面 / 换卡槽 / 保存后各读一次 —— 用户停在页面上盯着看时
    /// 它是不动的，得手动点「刷新」。用户要求「前台打开查看时 1s 自动刷新一次」。
    ///
    /// ── 为什么是 1 Hz，及为什么不动 `bandInfo` ───────────────────────────────
    ///
    /// 每秒一次对齐硬件页 / 电源页的节奏（同 App 一致的一秒一拍）。只刷 `slotInfo`，
    /// **不重读频段配置**：那份东西是上千毫秒级的 XPC（`copyCellInfo` 最坏等 1 秒），
    /// 而且它本来就不该每秒动 —— 用户正在打勾的界面更不该被它搅。
    ///
    /// ── 为什么不在主线程上读 ────────────────────────────────────────────────
    ///
    /// `sysprobe_slot_info` 是同步 XPC（内部等回调，最坏 1 秒）。留在主线程会把
    /// 主线程按住最多一秒 —— 那正是「点什么都卡一下」的来源。
    func startSlotPolling() {
        guard slotPoller == nil else { return }
        // 先立刻读一次，别等下一个整秒。
        pollSlotInfo()
        // 挂在 `.default` 模式：滚动期间自动让路，松手接上。与两个 Monitor 同一取向。
        slotPoller = Timer.publish(every: 1, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollSlotInfo()
            }
    }

    func stopSlotPolling() {
        slotPoller?.cancel()
        slotPoller = nil
    }

    /// 一次刷新：后台读，回主 actor 发布。读不到就保持上一次的值不变。
    private func pollSlotInfo() {
        // `slot` 是主 actor 隔离的属性，而本类是 `@MainActor` 的 —— 进 detached 之前
        // 先在本层把它取出来。`slotInfo` 的比较也要在主 actor 上做（它同样是隔离的）。
        let slot = self.slot
        Task.detached(priority: .utility) { [weak self] in
            let info = BandService.readInfoSync(slot: slot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard info != self.slotInfo else { return }
                self.slotInfo = info
            }
        }
    }

    // MARK: - 读

    /// 进页面时调一次。
    ///
    /// **已经有数据就不重新探卡槽。** `preferredSlot()` 是几次**同步 XPC**，而
    /// 「一进这一页整页刷一次」正是要修掉的那个现象：分段切回来会重建分段视图，
    /// 每次都重探卡槽、重读基带、再把整屏盖成转圈的话，用户看到的就是一次强制刷新
    /// （滚动位置也一并归零）。
    ///
    /// 已经有数据时走的是**静默刷新**：界面照旧显示上一次读回来的值 ——
    /// 转圈只在首读出现（见 `BandPanels.isInitialLoad`），刷新结果回来再替换。
    ///
    /// 判据用 `availability != .unknown` 而不是 `bandInfo != nil`：读失败
    /// （没权限 / 无卡）之后 `availability` 是 `.unavailable`，那也是一种「已经问过
    /// 基带了」的状态，不该每次进来都重问一遍。
    func ensureLoaded() async {
        guard availability == .unknown else {
            load(slot: slot)
            return
        }
        // 探卡槽这件事**只做一次**（`didProbeSlot`），与「读过没有」分开记：
        // 两个分段的视图各自会调本方法，而第一次探出来的卡槽若与默认值不同，
        // 是靠调用方的 `.onChange(of: slot)` 去重读的 —— 那一侧可能还没挂上，
        // 于是这次调用不读、下一次调用（分段挂上来之后）才读。少了这个标记，
        // 中间那次会把同一件事再探一遍。
        if !didProbeSlot {
            didProbeSlot = true
            // **必须丢到 detached 里跑**：这个探测是几次同步 XPC，而本类是
            // `@MainActor` 的 —— 留在主线程会卡住进这一页的第一帧。
            let preferred = await Task.detached { BandService.preferredSlot() }.value
            if preferred != slot {
                // 换卡槽由调用方的 `.onChange(of: slot)` 去重读 —— 与它原来在视图里
                // 当 `@State` 时是同一条路，那条路还会顺带清掉界面上的勾选与横幅。
                slot = preferred
                return
            }
        }
        load(slot: slot)
    }

    /// 读 `slot`，并顺带探测一次卡槽数量（只探一次）。
    ///
    /// 结果在主 actor 上发布，调用方可以直接观察 `bandInfo` / `availability`。
    func load(slot: Int) {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let bands = BandService.readBandsSync(slot: slot)
            let info = BandService.readInfoSync(slot: slot)
            let otherSlots = BandService.otherSlots(primary: slot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.apply(bands)
                self.slotInfo = info
                // 只列**主卡槽 + 确实插着卡的那些**。单卡设备上 `otherSlots` 是空的，
                // 界面上就不会出现卡槽选择器 —— 只有一个卡槽时给一个只有一项的分段控件，
                // 除了占地方没有别的用处。
                self.slots = ([slot] + otherSlots).sorted()
            }
        }
    }

    /// 只读一次频段，**不碰任何 `@Published` 状态**。
    ///
    /// 给「重启蜂窝服务之后的校验」用。那几秒里 CommCenter 正好被杀了又拉起，
    /// 走 `load()` 会把 `availability` 打成 `.unavailable`、`bandInfo` 置空 ——
    /// 整页跟着闪一次「不可用」。这条路径只把结果交给调用方，界面状态由调用方
    /// 在确认 CommCenter 回来之后才刷新。
    func probeBands(slot: Int) async -> BandSet? {
        await Task.detached(priority: .utility) {
            BandService.readBandsSync(slot: slot)
        }.value
    }

    /// 除主卡槽之外、确实插着卡的卡槽。
    ///
    /// 走 `sysprobe_slot_has_sim` 而不是「频段读得回来」：频段配置是设备级的，没插卡
    /// 也可能读得到。而那个函数刻意做得很轻，单卡设备上这次探测只是两次快速失败的
    /// 字符串查询，不会让进页面多等。
    private nonisolated static func otherSlots(primary: Int) -> [Int] {
        (1...2).filter { $0 != primary && sysprobe_slot_has_sim(Int32($0)) }
    }

    /// 一进页面该选哪个卡槽。
    ///
    /// 上游 CellularInfo 的规则是「卡 1 未启用而卡 2 启用就选卡 2；两张都启用就选
    /// **首选数据卡**」。这里合并成一条，因为它天然覆盖那两种情形：
    ///
    ///   1. 拿首选数据卡槽（`getPreferredDataSubscriptionContextSync`）；
    ///   2. 它必须**确实插着卡**（`sysprobe_slot_has_sim`）才采用 —— 否则退回第一个
    ///      插着卡的卡槽；
    ///   3. 一个都没有（无卡 / 无基带）才退回 1。
    ///
    /// 不照搬上游那两条 if 的原因：它用 `getDeviceSlotEnabled` 判断「卡槽启用」，
    /// 那个接口本身也依赖完整 context；而这里已经有「插着卡吗」这个更直接的判据。
    nonisolated static func preferredSlot() -> Int {
        let available = (1...2).filter { sysprobe_slot_has_sim(Int32($0)) }
        guard !available.isEmpty else { return 1 }
        let preferred = Int(sysprobe_preferred_data_slot())
        return available.contains(preferred) ? preferred : (available.first ?? 1)
    }

    private nonisolated static func readBandsSync(slot: Int) -> BandSet? {
        var entity: BandSet?
        bandQueue.sync {
            guard let raw = sysprobe_read_bands(Int32(slot)) as? [String: Any] else {
                return
            }
            var parsed = BandSet()
            parsed.active = BandSet.parse((raw["active"] as? [String: Any]) ?? [:])
            parsed.supported = BandSet.parse((raw["supported"] as? [String: Any]) ?? [:])
            entity = parsed
        }
        return entity
    }

    private nonisolated static func readInfoSync(slot: Int) -> SlotInfo {
        var info = SlotInfo()
        bandQueue.sync {
            guard let raw = sysprobe_slot_info(Int32(slot)) as? [String: Any] else {
                return
            }
            info = SlotInfo.parse(raw)
        }
        return info
    }

    private func apply(_ entity: BandSet?) {
        bandInfo = entity
        availability = entity == nil ? .unavailable : .available
    }

    // MARK: - 写

    /// 保存勾选结果。返回是否成功。
    ///
    /// **写之前必须已经读过同一个卡槽** —— 桥接层是从读回来的那个对象出发改的，
    /// 没有它就没得改。界面上的流程天然满足这一点（进页面先读）。
    ///
    /// `only` 限定只写这些制式，界面上没画出来的那些一概不碰（理由见
    /// `BandSet.payload` 的注释）。现在界面只画 4G，所以这里传的也是 4G ——
    /// **3G / 2G 的勾选状态原样留在 Modem 里**，不受这一页影响。
    func write(selection: [RadioAccessTechnology: Set<Int>],
               only: [RadioAccessTechnology],
               slot: Int) -> Bool {
        guard let supported = bandInfo?.supported else { return false }

        // `only` 为空 = 一个可写的制式都没有。这时候不能往下走：桥接层会拿一个
        // 空字典去调 `setActiveBandInfo:`，那一下**可能照样返回成功** ——
        // 界面就会显示「已保存」而其实什么都没变，而且白白触发一次基带重配置。
        // 直接判失败，让 banner 说实话。
        //
        // 正常情况下走不到这里（没有可编辑的制式时，界面上也就没有能勾的东西，
        // 保存按钮是灰的）；这是给「读了半天但没读出 4G」那种边角情况兜底。
        guard !only.isEmpty else { return false }

        let payload = BandSet.payload(selection: selection, supported: supported, only: only)

        var ok = false
        bandQueue.sync {
            ok = sysprobe_write_active_bands(Int32(slot), payload)
        }
        return ok
    }

    /// 恢复默认：把 active 整个换成 supported。
    func restoreDefault(slot: Int) -> Bool {
        var ok = false
        bandQueue.sync {
            ok = sysprobe_restore_default_bands(Int32(slot))
        }
        return ok
    }
}
