import Foundation

// MARK: - 共享 CPU 指标（由 Statusbar / Helium 的 HUD 发布）

/// 读取 Statusbar（Helium）发布的 CPU 指标。
///
/// **为什么要有这一层**：两个进程各自采样永远不可能显示同一个数 —— 采样相位错开，
/// 而频率的忙循环探针还会互相抢性能核。所以让常驻的 Helium HUD 当唯一采集者、
/// 把结果写进共享文件，本 App 读同一份，两边显示的就是同一个数。
///
/// 读不到（没装 Helium / HUD 没跑）或过期时返回 `nil`，调用方回落到自己采样。
///
/// ## 这个文件是唯一的跨进程契约
///
/// Helium 与 SysProbe 之间没有 App Group、也没有 XPC —— 只有下面那两个路径。读的
/// 一方打开同一个文件、解析同一批键，所以**任何一项改动都会静默地弄坏另一边**：
/// 它照样能读，只是取不到那个键，于是回落成 0 或「—」，日志里一个字都不会有。
/// 属于契约的有：
///
/// - 键名与类型（`ts` / `usage` / `per_core` / `freq_mhz` / `freq_source`）
/// - 单位（占用是 0…1 而不是 0…100；频率是 MHz 而不是 Hz）
/// - 两个路径，以及尝试的先后顺序
/// - 本文件里那个新鲜度窗口
///
/// 改其中任何一项，都要同时改 Helium 的 `CPUMetricsPublisher.mm`，并且两个 App
/// 一起发。这边的解析刻意写得宽容 —— 认不出的键直接忽略、文件不存在也不算错误 ——
/// 所以格式对不上时的表现是**数字不对**，而不是报错。
nonisolated enum CPUSharedMetrics {

    struct Reading {
        /// 发布时刻。
        let date: Date
        /// 0…1，全核平均占用。
        let usage: Double
        /// 0…1，每个逻辑核的占用。
        let perCore: [Double]
        /// MHz。0 表示发布方也没有有效读数。
        let frequencyMHz: Int
        /// 频率来源：`ioreport`（真实档位）或 `probe`（忙循环）。
        let frequencySource: String
    }

    static func read(now: Date = .now) -> Reading? {
        // 这两个常量**刻意写在函数体里**，不放文件作用域：本工程设了
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，它会把文件作用域的 `let`
        // 也判成主 actor 隔离，于是 `nonisolated` 的 static func 里访问不到 ——
        // CI 会直接报 "main actor-isolated let ... can not be referenced from a
        // nonisolated context"。
        //
        // 候选路径：发布方（Helium 的 HUD）两个都写，这里按序取第一个能读的。
        // `/var/tmp` 是主路径；Caches 那份重启后仍在，覆盖 `/var/tmp` 不可写的情况。
        let paths = [
            "/var/tmp/cpu_metrics.json",
            "/var/mobile/Library/Caches/cpu_metrics.json",
        ]
        // 超过这个秒数就认为发布方已经停了 —— 宁可自己采，也不显示一个陈旧的数。
        let freshnessWindow: TimeInterval = 5

        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let object = json as? [String: Any],
                  let timestamp = object["ts"] as? Double else {
                continue
            }

            let date = Date(timeIntervalSince1970: timestamp)
            // 允许一点点时钟回拨，但拒绝明显过期的文件。
            guard now.timeIntervalSince(date) <= freshnessWindow else { continue }

            let usage = (object["usage"] as? Double) ?? 0
            let perCore = (object["per_core"] as? [Double]) ?? []
            let frequencyMHz = (object["freq_mhz"] as? NSNumber)?.intValue ?? 0
            let source = (object["freq_source"] as? String) ?? "unknown"

            return Reading(date: date,
                           usage: min(max(usage, 0), 1),
                           perCore: perCore.map { min(max($0, 0), 1) },
                           frequencyMHz: max(frequencyMHz, 0),
                           frequencySource: source)
        }
        return nil
    }
}
