import Foundation

// ══════════════════════════════════════════════════════════════════════════════
//  ChargeLimiter 守护进程的 HTTP 桥 —— 底层
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
//  为什么这一层在 Shared/Power 而不是 ChargeControl
//  ══════════════════════════════════════════════════════════════════════════
//
//  2026-10-13：负一屏要显示**电芯温度**，而那个值只有守护进程报得上来
//  （`get_bat_info` 的 `Temperature`）。但负一屏扩展的编译源里**没有**
//  `Sources/ChargeControl` —— 那一层带着充电控制的全套界面与服务，扩展用不到，
//  也不该为了一个温度把它们全拖进去。
//
//  所以把「连守护进程 + 发一条请求 + 取 data」这三件事放到这里，两边共用：
//  `Sources/ChargeControl` 用它读写配置，`Sources/Shared/Power` 用它读电池。
//
//  ## 为什么返回类型化结构而不是 `[String: Any]`
//
//  `[String: Any]` 不是 `Sendable`。`URLSession` 的回调跑在后台线程，把它带回
//  `@MainActor` 的服务类在 Swift 6 下直接编译不过（而本工程
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所有类型默认就是主 actor 隔离的）。
//  所以解析在**非隔离**的这一层里做完，只把 `Sendable` 的结构体送回去。
//
//  ## 为什么这一层不碰 `LocalizedStringKey`
//
//  本文件只 `import Foundation` —— 桥接层不该依赖 SwiftUI（同 `SensorCatalog`）。
// ══════════════════════════════════════════════════════════════════════════════

nonisolated enum DaemonBridge {

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

    /// `{"api": ...}` → 响应里的 `data` 字典。
    static func payload(_ body: [String: Any]) async -> [String: Any]? {
        guard let data = await post(body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["data"] as? [String: Any]
    }

    /// `{"api": ...}` → 响应里的 `status == 0`。
    static func status(_ body: [String: Any]) async -> Bool {
        guard let data = await post(body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["status"] as? Int
        else { return false }
        return code == 0
    }

    /// 只把 `Data` 送出去 —— 它是 `Sendable` 的。
    ///
    /// 请求体在这里就地序列化，所以 `[String: Any]` 全程没有跨过任何隔离边界
    /// （见文件头的说明）。超时与非 200 一律安静地返回 nil：对调用方来说
    /// 「连不上」和「超时」是同一件事（服务没起来）。
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
