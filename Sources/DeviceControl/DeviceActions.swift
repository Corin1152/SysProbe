import Foundation

/// 设置页「维护」区里的两个动作。
///
/// `nonisolated`：这个类型只被视图读，不持有任何可变状态；标出来是为了让它能在
/// 后台任务里安全地构造与比较（自检那一步就跑在 `Task.detached` 上），
/// 不必为它单独开一个 actor 隔离域。
nonisolated enum DeviceAction: String, Identifiable, CaseIterable {
    /// 重启设备。整机重启。
    case reboot
    /// 注销。只重启界面层，不重启设备。
    case respring

    var id: String { rawValue }

    /// 按钮上的名字。同一个字符串也用在确认弹窗的标题与动作按钮上 ——
    /// 只留一份，免得三处漂移。
    ///
    /// 走 `Strings.text` 而不是 `LocalizedStringKey`：确认弹窗的标题是
    /// 拼接出来的（`Are you sure you want to %@?`），那个位置拿不到编译期字面量。
    var title: String {
        switch self {
        case .reboot: return Strings.text("Reboot Device")
        case .respring: return Strings.text("Respring")
        }
    }

    var systemImage: String {
        switch self {
        case .reboot: return "power"
        case .respring: return "arrow.clockwise"
        }
    }

    /// 确认弹窗里的第二行：说清这个动作会带来什么。
    var warning: String {
        switch self {
        case .reboot:
            return Strings.text("The device restarts immediately. Anything unsaved is lost.")
        case .respring:
            return Strings.text("Only the interface restarts — the device does not reboot. This app closes with it.")
        }
    }
}

/// 「关闭温控降频」这个开关的**配置**状态。
///
/// 必须把「配置」和「运行」分开看：这个开关改的是 launchd 的启动配置，
/// **要重启之后 `thermalmonitord` 才真的不再启动**。所以在重启之前，
/// `.disabled` 只代表「已经配置好」，不代表此刻已经生效 —— 界面必须把这件事说出来，
/// 否则用户会以为「开了没效果」。
nonisolated enum ThermalDaemonState: Equatable {
    /// `disabled.plist` 里有 `com.apple.thermalmonitord` 且为真。
    case disabled
    /// 那个键不在（或不是真值）—— 温控守护进程照常启动。
    case enabled
    /// 读不出来：工具不在包里、拿不到 root、plist 解析失败。
    ///
    /// **不能和 `.enabled` 合并**：前者该显示「不可用」并禁用开关，
    /// 后者该显示「关着」并允许打开。合并了就会把一个坏掉的工具
    /// 显示成一个看起来正常、拨了没反应的开关。
    case unknown
}

/// 包内特权工具（`SysProbeRootTool`）的调用入口。
///
/// 工具本身是 `Tools/RootTool.c` 编出来的裸可执行文件，由 `scripts/build-ipa.sh`
/// 拷进包根目录并**单独签名**（`Support/SysProbeRootTool.entitlements`）。
/// 路径约定与 `ChargeLimiterDaemon` 一致 —— 都在包根，都用绝对路径交给 `posix_spawn`。
///
/// 它和 `ChargeControlService` 是两条独立的链路：这里只借用了同一个
/// `ChargeSpawn.c` 里的 root 启动能力，不碰守护进程的任何状态。
nonisolated enum DeviceActions {

    /// 工具在包里的绝对路径；不在包里则 `nil`。
    ///
    /// 本地直接 `xcodebuild`（不走 `scripts/build-ipa.sh`）时会拿到 `nil` ——
    /// 那个二进制不在 Xcode 的产物里，由打包脚本单独编译后拷进去。
    static var toolPath: String? {
        let path = Bundle.main.bundlePath + "/SysProbeRootTool"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// 跑一次 `check`，确认子进程拿到的**确实是 root**。
    ///
    /// 为什么值得多起一个进程：这两个动作在权限不足时**不会把错误传到界面上**。
    /// `posix_spawn` 照样返回 0（子进程起来了），只是它以 mobile 身份跑，
    /// 于是 `reboot(2)` 返回 EPERM、`kill(SpringBoard)` 返回 EPERM ——
    /// 用户看到的就是「点了没反应」。而权限不足恰恰是最可能的失败模式：
    /// entitlements 没签进包、或者在 TrollStore 之外的环境安装。
    ///
    /// 所以这里用一次毫秒级的子进程把答案带回来，界面上明确显示「不可用」，
    /// 而不是留一个看起来能用、点了没反应的按钮。
    ///
    /// 这是**阻塞**调用（最多约 1 秒），调用方负责别放在主线程上。
    static func probe() -> Bool {
        guard let path = toolPath else { return false }
        var status: Int32 = 0
        guard sysprobe_spawn_root_tool_sync(path, "check", &status) == 0 else { return false }
        return status == 0
    }

    /// 执行一个动作。
    ///
    /// 返回 `false` **只代表进程没起来**，不代表动作成功 —— 这两个动作一个会把设备
    /// 重启掉、一个会让本 App 被系统收掉，都不可能回读结果。所以界面只在返回
    /// `false` 时提示，成功后什么都不做（也来不及做）。
    @discardableResult
    static func perform(_ action: DeviceAction) -> Bool {
        guard let path = toolPath else { return false }
        return sysprobe_spawn_root_tool(path, action.rawValue) == 0
    }

    /// 重启蜂窝网络服务（CommCenter）。
    ///
    /// **刻意不放进 `DeviceAction`**：那一组是「维护」区并排的两个按钮，由
    /// `allCases` 驱动；这个是频段设置页的**逃生通道**，位置与语义都不同 ——
    /// 塞进去会让维护区凭空多出第三个按钮。
    ///
    /// 频段写错导致「无服务」时，杀掉 CommCenter 会让它重新读一遍配置，
    /// 多数情况下能回到可用状态。返回 `false` 同样只代表进程没起来。
    @discardableResult
    static func restartCommCenter() -> Bool {
        guard let path = toolPath else { return false }
        return sysprobe_spawn_root_tool(path, "restart-commcenter") == 0
    }

    /// 读「温控守护进程是否已被配置为禁用」。
    ///
    /// 退出码的约定写在 `Tools/RootTool.c` 的 `enum` 里：**0 = 已禁用，5 = 未禁用**，
    /// 其余（3 = 没拿到 root、4 = 读写失败）一律归为 `.unknown`。
    /// 那个 `5` 是刻意加的一种「正常」—— 它必须能和 0 / 4 区分开，
    /// 否则界面分不清「没开」与「读不出来」。
    ///
    /// 这是**阻塞**调用（起子进程并等它，最多约 1 秒），调用方负责别放在主线程上。
    static func thermalState() -> ThermalDaemonState {
        guard let path = toolPath else { return .unknown }
        var status: Int32 = 0
        guard sysprobe_spawn_root_tool_sync(path, "thermal-status", &status) == 0 else {
            return .unknown
        }
        switch status {
        case 0: return .disabled
        case 5: return .enabled
        default: return .unknown
        }
    }

    /// 写入「禁用 / 恢复」温控守护进程的配置。
    ///
    /// 返回 `true` 表示**子进程正常收尾且回读校验通过**（工具自己会回读一次），
    /// 但仍**不代表已经生效** —— 生效要重启。界面必须把这件事说出来。
    ///
    /// 这也是**阻塞**调用，同样别放在主线程上。
    @discardableResult
    static func setThermalDisabled(_ disabled: Bool) -> Bool {
        guard let path = toolPath else { return false }
        var status: Int32 = 0
        let command = disabled ? "thermal-disable" : "thermal-enable"
        guard sysprobe_spawn_root_tool_sync(path, command, &status) == 0 else { return false }
        return status == 0
    }
}
