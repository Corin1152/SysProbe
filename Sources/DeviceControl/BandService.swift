import Foundation

/// 桥接层是所有卡槽共用的一条队列。
///
/// 放在**文件作用域**而不是类型里：`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` 会把
/// 类型里的 `static let` 也判成主 actor 隔离，那样下面那些 `nonisolated static func`
/// 就访问不到它了。`nonisolated(unsafe)` 是必需的 —— 全局可变状态的隔离检查，
/// 而这里本来就是刻意的跨线程共享（队列自己保证串行）。
private nonisolated(unsafe) let bandQueue = DispatchQueue(label: "com.corin.sysprobe.band")

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

    /// 探测到有数据的卡槽。单卡设备只有 `[1]`。
    ///
    /// 判定方式很直接：**读得到就是这个卡槽存在**。上游用
    /// `getSlotCount()` + `getSlotSIMStatus` 一整套私有接口来判断，为了一个卡槽
    /// 选择器不值得再引入那么多私有 API。
    @Published private(set) var slots: [Int] = [1]

    /// 当前卡槽的频段。`nil` = 还没读到 / 读不到。
    @Published private(set) var bandInfo: BandSet?

    /// 正在读。
    @Published private(set) var isLoading = false

    // MARK: - 读

    /// 读 `slot`，并顺带探测一次卡槽数量（只探一次）。
    ///
    /// 结果在主 actor 上发布，调用方可以直接观察 `bandInfo` / `availability`。
    func load(slot: Int) {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = BandService.readSync(slot: slot)
            let extraSlots = BandService.probeExtraSlots(primary: slot)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.apply(result)
                if !extraSlots.isEmpty {
                    self.slots = ([slot] + extraSlots).sorted()
                }
            }
        }
    }

    /// 只在第一次加载时探一次第二卡槽 —— 单卡设备上它会读失败，于是不进 `slots`。
    private nonisolated static func probeExtraSlots(primary: Int) -> [Int] {
        guard primary == 1 else { return [] }
        return readSync(slot: 2) == nil ? [] : [2]
    }

    private nonisolated static func readSync(slot: Int) -> BandSet? {
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

    private func apply(_ entity: BandSet?) {
        bandInfo = entity
        availability = entity == nil ? .unavailable : .available
    }

    // MARK: - 写

    /// 保存勾选结果。返回是否成功。
    ///
    /// **写之前必须已经读过同一个卡槽** —— 桥接层是从读回来的那个对象出发改的，
    /// 没有它就没得改。界面上的流程天然满足这一点（进页面先读）。
    func write(selection: [RadioAccessTechnology: Set<Int>], slot: Int) -> Bool {
        guard let supported = bandInfo?.supported else { return false }
        let payload = BandSet.payload(selection: selection, supported: supported)

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
