import Foundation

// ══════════════════════════════════════════════════════════════════════════════
//  ChargeLimiter 守护进程的 HTTP 桥
//
//  守护进程在 127.0.0.1:1230 上跑一个 GCDWebServer，协议只有一条：
//
//      POST /bridge      body: {"api": "...", ...}
//                        resp: {"status": 0, "data": {...}}
//
//  它同时也会把一份网页界面托管在 `/`（`SysProbe.app/www`，随包发布）。App 里
//  **不用**那个界面 —— 见 `ChargeControlView` 里的说明 —— 但留着它有两个用处：
//  出问题时可以在 Safari 里直接开 `http://127.0.0.1:1230` 手动停充，
//  以及它本来就是这个守护进程的 web root，删掉反而多一种失败模式。
//
//  ## 为什么这一层返回的是类型化结构，而不是 `[String: Any]`
//
//  `[String: Any]` 不是 `Sendable`。`URLSession` 的回调跑在后台线程，把它带回
//  `@MainActor` 的 `ChargeControlService` 在 Swift 6 下直接编译不过（而本工程
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所有类型默认就是主 actor 隔离的）。
//  所以解析在**非隔离**的这一层里做完，只把 `Sendable` 的结构体送回去。
//
//  ## 为什么这一层也不碰 `LocalizedStringKey`
//
//  本文件只 `import Foundation` —— 桥接层不该依赖 SwiftUI（同 `SensorCatalog`，
//  那边整层也是为这个把 `LocalizedStringKey` 换成了 `String`）。所以下面那几个
//  枚举的 `title` / `detail` 返回 `String`，译文由 `Strings.text` 查表得到；
//  调用点 `Text(mode.title)` 拿到的是已经译好的字符串，不会二次查表。
// ══════════════════════════════════════════════════════════════════════════════

/// 守护进程暴露的一份配置。
///
/// 键名与 `daemon.mm` 的 `handleReq` / `initConf` **逐字一致** —— 这样文案表、
/// 默认值、以及 `/var/root/aldente.conf` 里已经存在的那份配置都能直接复用。
nonisolated struct ChargeConfig: Equatable {
    var enable = false
    /// `charge_on_plug` 或 `edge_trigger`。
    var mode = ChargeMode.chargeOnPlug
    /// 秒。守护进程的检查间隔。
    var updateFrequency = 1
    /// `""` = 不动作，`noti` = 发本地通知。
    var action = ""
    var chargeBelow = 20
    var chargeAbove = 80
    var enableTemperature = false
    /// 两个默认值与守护进程 `initConf` 里的一致（`charge_temp_above` = 35、
    /// `charge_temp_below` = 10）。不一致的话，守护进程没起来时界面会显示一组
    /// 并不是它实际在用的值 —— 用户会照着那个数去理解「现在设的是多少」。
    var temperatureAbove = 35
    var temperatureBelow = 10
    var preferSmartBattery = false
    var predictiveInhibit = false
    var disableInflow = false
    var thermalMode = CuffMode.off
    var ppmMode = CuffMode.off
    var limitInflow = false

    init() {}

    init(_ raw: [String: Any]) {
        enable = Self.bool(raw["enable"])
        mode = ChargeMode(rawValue: Self.string(raw["mode"])) ?? .chargeOnPlug
        updateFrequency = Self.int(raw["update_freq"]) ?? 1
        action = Self.string(raw["action"])
        chargeBelow = Self.int(raw["charge_below"]) ?? 20
        chargeAbove = Self.int(raw["charge_above"]) ?? 80
        enableTemperature = Self.bool(raw["enable_temp"])
        temperatureAbove = Self.int(raw["charge_temp_above"]) ?? 40
        temperatureBelow = Self.int(raw["charge_temp_below"]) ?? 35
        preferSmartBattery = Self.bool(raw["adv_prefer_smart"])
        predictiveInhibit = Self.bool(raw["adv_predictive_inhibit_charge"])
        disableInflow = Self.bool(raw["adv_disable_inflow"])
        // 这两项守护进程默认给空串，空串按 off 显示 —— 否则界面上那一行是空白。
        thermalMode = CuffMode(rawValue: Self.string(raw["adv_def_thermal_mode"])) ?? .off
        ppmMode = CuffMode(rawValue: Self.string(raw["ppm_simulate_mode"])) ?? .off
        limitInflow = Self.bool(raw["adv_limit_inflow"])
    }

    /// `NSNumber` 会同时匹配 `as? Bool` 与 `as? Int`，所以先问 `Bool`。
    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func string(_ value: Any?) -> String {
        (value as? String) ?? ""
    }
}

/// 「模式」的两种取值。
nonisolated enum ChargeMode: String, CaseIterable, Identifiable {
    /// 插上电就充，充到阈值停。
    case chargeOnPlug = "charge_on_plug"
    /// 只在越过下限时才开始充 —— 也就是「低于 x% 才开始」那一组阈值真正生效的模式。
    case edgeTrigger = "edge_trigger"

    var id: String { rawValue }

    /// 译文由 `Strings.text` 直接查表得到，返回 `String`。
    ///
    /// 这里一度返回 `LocalizedStringKey`，那是个**编译期就过不去**的写法，而且报错
    /// 指向的地方看不出根因：本文件只 `import Foundation`，`LocalizedStringKey` 是
    /// SwiftUI 的类型，于是 `title` 成了错误类型 → `Identifiable` 一致性判不出来 →
    /// 下游 `ChargeControlView` 里的 `ForEach(ChargeMode.allCases)` 只好退而选中
    /// SwiftUI 那个 `Binding<C>` 重载，`mode` 被当成 `Binding<ChargeMode>`，
    /// `Text(mode.title)` 就成了 `Text<Binding<Subject>>` —— 一屏全是「无法推断泛型」
    /// 之类的错，真正的原因却在另一个文件里。
    ///
    /// 本层是**桥接层**，本来就不该依赖 SwiftUI（`SensorCatalog` 那一层是同样的处理，
    /// 理由也一样）。改回 `String` 之后，调用点 `Text(mode.title)` 走的是
    /// `Text(verbatim:)` 那条路 —— 拿到的**已经是译文**，不会二次查表。
    var title: String {
        switch self {
        case .chargeOnPlug: return Strings.text("Charge on plug")
        case .edgeTrigger: return Strings.text("Threshold trigger")
        }
    }

    var detail: String {
        switch self {
        case .chargeOnPlug:
            return Strings.text("Charging starts as soon as power is connected and stops at the upper threshold.")
        case .edgeTrigger:
            return Strings.text("Charging only starts once the level falls below the lower threshold.")
        }
    }
}

/// 热模拟与 PPM 模拟共用的一档 —— 原版里它们指向的就是同一个数组。
nonisolated enum CuffMode: String, CaseIterable, Identifiable {
    case off, nominal, light, moderate, heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        // 原版这一档叫 "Nominal"，但那个键在本工程里已经被热状态（`Nominal` = 正常）占了。
        // 文案表的键就是英文原文，不能有两条同名的，所以这里换个词 —— 语义一样，
        // 而且避免了两处不相干的功能共用一条译文（改一处会牵动另一处）。
        case .off: return Strings.text("Off")
        case .nominal: return Strings.text("Standard")
        case .light: return Strings.text("Light")
        case .moderate: return Strings.text("Moderate")
        case .heavy: return Strings.text("Heavy")
        }
    }
}

/// 「行为」：到点之后除了停充，还要不要做别的。
nonisolated enum ChargeAction: String, CaseIterable, Identifiable {
    case none = ""
    case notify = "noti"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return Strings.text("None")
        case .notify: return Strings.text("Notification")
        }
    }
}

/// 守护进程报上来的电池读数（`get_bat_info` 的 `data`）。
///
/// 字段单位与原版前端一致，别改：
/// - `Temperature` 是**百分之一摄氏度**（守护进程自己也是 `/100` 用的）；
/// - `BootVoltage` / `Voltage` 是毫伏；
/// - `CurrentCapacity` 已经是百分比，不是 mAh。
nonisolated struct ChargeBatteryInfo: Equatable {
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

/// 7 个 API 的客户端。
///
/// 每个方法都在超时或非 200 时安静地返回 `nil` / `false`：对调用方来说
/// 「连不上」和「超时」是同一件事（服务没起来），界面上也只有一句提示。
nonisolated enum ChargeBridge {

    static let port: Int = 1230

    /// `GET /` 就是守护进程托管的那个网页界面。设置页里显示它，出问题时可以
    /// 直接在 Safari 里打开手动停充 —— 那是这个 App 之外最后一道保险。
    static let interfaceURL = URL(string: "http://127.0.0.1:1230")!

    private static var bridgeURL: URL { interfaceURL.appendingPathComponent("bridge") }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        // 服务没起来时立刻失败，别让 URLSession 在后台一直等网络可用。
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: - 读

    static func config() async -> ChargeConfig? {
        guard let payload = await payload(["api": "get_conf"]) else { return nil }
        return ChargeConfig(payload)
    }

    static func batteryInfo() async -> ChargeBatteryInfo? {
        guard let payload = await payload(["api": "get_bat_info"]) else { return nil }
        return ChargeBatteryInfo(payload)
    }

    // MARK: - 写

    static func set(_ key: String, _ value: Bool) async -> Bool {
        await status(["api": "set_conf", "key": key, "val": value])
    }

    static func set(_ key: String, _ value: Int) async -> Bool {
        await status(["api": "set_conf", "key": key, "val": value])
    }

    static func set(_ key: String, _ value: String) async -> Bool {
        await status(["api": "set_conf", "key": key, "val": value])
    }

    /// 「正在充电」是**即时动作**，不是配置项 —— 它走 `set_charge_status`。
    static func setChargeStatus(_ on: Bool) async -> Bool {
        await status(["api": "set_charge_status", "flag": on ? 1 : 0])
    }

    static func resetConfig() async -> Bool {
        await status(["api": "reset_conf"])
    }

    // MARK: - 内部

    /// `{"api": ...}` → 响应里的 `data` 字典。
    private static func payload(_ body: [String: Any]) async -> [String: Any]? {
        guard let data = await post(body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["data"] as? [String: Any]
    }

    /// `{"api": ...}` → 响应里的 `status == 0`。
    private static func status(_ body: [String: Any]) async -> Bool {
        guard let data = await post(body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["status"] as? Int
        else { return false }
        return code == 0
    }

    /// 只把 `Data` 送出去 —— 它是 `Sendable` 的。
    ///
    /// 请求体在这里就地序列化，所以 `[String: Any]` 全程没有跨过任何隔离边界
    /// （见文件头的说明）。`requestCachePolicy` 之类都在 `session` 上配好了。
    private static func post(_ body: [String: Any]) async -> Data? {
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: bridgeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return data
    }
}
