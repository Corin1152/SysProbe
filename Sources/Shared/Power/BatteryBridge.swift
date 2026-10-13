import Foundation

/// 守护进程报上来的电池读数（`get_bat_info` 的 `data`）。
///
/// **2026-10-13 从 `ChargeBatteryInfo` 搬到这里并改名。** 原因是负一屏要显示电芯
/// 温度，而它拿不到 `Sources/ChargeControl`（那一层带着充电控制的全套界面与服务，
/// 扩展的编译源里没有它）。温度是**电池**的属性、不是充电控制的属性，放在
/// `Shared/Power` 才对，两边也就自然共用同一份解析。
///
/// 字段单位与原版前端一致，别改：
/// - `Temperature` 是**百分之一摄氏度**（守护进程自己也是 `/100` 用的）；
/// - `BootVoltage` / `Voltage` 是毫伏；
/// - `CurrentCapacity` 已经是百分比，不是 mAh。
nonisolated struct BatteryInfo: Equatable {
    var currentCapacity: Int?
    var nominalChargeCapacity: Int?
    var designCapacity: Int?
    var temperature: Double?
    var isCharging = false
    var isInstalled = false
    var cycleCount: Int?
    var amperage: Int?
    var bootVoltage: Int?
    var voltage: Int?
    var serial: String?
    var updateTime: Date?

    /// 健康度 = 实际容量 / 设计容量。原版前端的算法，保持一致。
    var healthPercent: Double? {
        guard let nominal = nominalChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(nominal) / Double(design) * 100
    }

    init() {}

    init(_ raw: [String: Any]) {
        currentCapacity = Self.int(raw["CurrentCapacity"])
        nominalChargeCapacity = Self.int(raw["NominalChargeCapacity"])
        designCapacity = Self.int(raw["DesignCapacity"])
        // 百分之一摄氏度。读出来就是坏值（比如没装电池时是 0）时按缺失处理，
        // 免得界面上出现一个 0.0 °C 的「读数」。
        if let hundredths = Self.int(raw["Temperature"]), hundredths > 0 {
            temperature = Double(hundredths) / 100
        }
        isCharging = (raw["IsCharging"] as? NSNumber)?.boolValue ?? false
        isInstalled = (raw["BatteryInstalled"] as? NSNumber)?.boolValue ?? false
        cycleCount = Self.int(raw["CycleCount"])
        amperage = Self.int(raw["Amperage"])
        bootVoltage = Self.int(raw["BootVoltage"])
        voltage = Self.int(raw["Voltage"])
        serial = raw["Serial"] as? String
        if let seconds = Self.int(raw["UpdateTime"]), seconds > 0 {
            updateTime = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

/// 只做一件事：向守护进程要一份电池读数。
///
/// 与 `ChargeBridge` 分开，是因为调用方不同：这里是「负一屏 / 主 App 想知道电池温度」，
/// 那里是「电源页要读写充电配置」。两边的生命周期也完全不同 —— 前者每秒一次、
/// 只为取一个数；后者跟着界面走。
nonisolated enum BatteryBridge {

    /// 守护进程没起来时返回 nil（超时或非 200 都会走到这里）。
    static func batteryInfo() async -> BatteryInfo? {
        guard let payload = await DaemonBridge.payload(["api": "get_bat_info"]) else { return nil }
        return BatteryInfo(payload)
    }
}
