import Foundation

// ══════════════════════════════════════════════════════════════════════════════
//  充电配置的桥
//
//  守护进程在 127.0.0.1:1230 上跑一个 GCDWebServer，协议只有一条：
//
//      POST /bridge      body: {"api": "...", ...}
//                        resp: {"status": 0, "data": {...}}
//
//  它同时也会把一份网页界面托管在 `/`（`SysProbe.app/www`，随包发布）。App 里
//  **不用**那个界面 —— 见 `ChargeControlPanels` 里的说明 —— 但留着它有两个用处：
//  出问题时可以在 Safari 里直接开 `http://127.0.0.1:1230` 手动停充，
//  以及它本来就是这个守护进程的 web root，删掉反而多一种失败模式。
//
//  ══════════════════════════════════════════════════════════════════════════
//  2026-10-13：这个文件瘦身了
//  ══════════════════════════════════════════════════════════════════════════
//
//  搬走两样东西，都挪到了 `Sources/Shared/Power/`：
//
//  · `ChargeBatteryInfo`（电池读数结构）→ `BatteryInfo`
//    （`Shared/Power/BatteryBridge.swift`）。负一屏要显示电芯温度，而它编译不到
//    本目录 —— 温度是**电池**的属性，放在 `Shared/Power` 才能两边共用。
//  · HTTP 桥的底层（`port` / `interfaceURL` / `session` / `post` / `payload` /
//    `status`）→ `DaemonBridge`（`Shared/Power/DaemonBridge.swift`）。
//
//  这个文件现在只剩「充电配置」这一件事：`ChargeConfig`、两个枚举，以及它的读写。
//
//  ## 为什么桥接层返回类型化结构而不是 `[String: Any]`
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
        // 这两个回退值必须与上面属性的默认值（35 / 10）**一致**，也必须与守护进程
        // `initConf` 里的值一致。原来这里写的是 40 / 35 —— 属性默认值改对了、回退漏改了，
        // 于是守护进程没起来（或 conf 里缺这两个键）时界面显示的是一组并非生效中的值，
        // 正好是上面那段注释要避免的情形。
        temperatureAbove = Self.int(raw["charge_temp_above"]) ?? 35
        temperatureBelow = Self.int(raw["charge_temp_below"]) ?? 10
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
    /// 下游 `ChargeControlPanels` 里的 `ForEach(ChargeMode.allCases)` 只好退而选中
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
///
/// **2026-10-11：这个枚举只剩「配置字段的类型」这一个用途了。**
/// 它的 `title`（Off / Standard / Light / Moderate / Heavy）随「热模拟」「PPM 模拟」
/// 两个下拉项一起删掉了 —— `ChargeConfig.thermalMode` / `ppmMode` 仍然从守护进程读回来，
/// 只是不再显示、也不再能改。
nonisolated enum CuffMode: String {
    case off, nominal, light, moderate, heavy
}

// 「行为」（`ChargeAction`：None / Notification）2026-10-11 整个删掉了 ——
// 那个下拉项从「基础」卡片移除之后没有任何使用者。`ChargeConfig.action` 字段保留，
// 同样是「读回来但不显示」。

/// 配置接口的客户端。
///
/// 每个方法都在超时或非 200 时安静地返回 `nil` / `false`：对调用方来说
/// 「连不上」和「超时」是同一件事（服务没起来），界面上也只有一句提示。
///
/// **HTTP 桥的底层在 `DaemonBridge`**（`Shared/Power/`）—— 这里只负责
/// 「把配置结构体 ↔ 请求体互转」这一层。
nonisolated enum ChargeBridge {

    // MARK: - 读

    static func config() async -> ChargeConfig? {
        guard let payload = await DaemonBridge.payload(["api": "get_conf"]) else { return nil }
        return ChargeConfig(payload)
    }

    // MARK: - 写

    static func set(_ key: String, _ value: Bool) async -> Bool {
        await DaemonBridge.status(["api": "set_conf", "key": key, "val": value])
    }

    static func set(_ key: String, _ value: Int) async -> Bool {
        await DaemonBridge.status(["api": "set_conf", "key": key, "val": value])
    }

    static func set(_ key: String, _ value: String) async -> Bool {
        await DaemonBridge.status(["api": "set_conf", "key": key, "val": value])
    }

    // ── 2026-10-11：删掉了两个写接口 ──────────────────────────────────────
    //
    // `setChargeStatus`（`set_charge_status`，「正在充电」那个即时动作）与
    // `resetConfig`（`reset_conf`）—— 它们在 App 里的唯一入口分别是「充电中」卡片
    // 与「重置全部设置」按钮，两个界面项都已移除。
    //
    // 守护进程**仍然提供这两个 API**（`Resources/www/js/app.js` 里还在用，
    // 浏览器打开 `http://127.0.0.1:1230` 照样能操作），这里只是 App 侧不再调用。

    // ── 2026-10-13：`batteryInfo()` 也搬走了 ─────────────────────────────
    //
    // 它现在在 `BatteryBridge`（`Shared/Power/`），因为负一屏也要用它、而负一屏
    // 编译不到本目录。电源页请改用 `BatteryBridge.batteryInfo()`。
}
