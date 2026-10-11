import Foundation

/// 「存储清理」的扫描报告（`SysProbeRootTool clean-scan` 写出的 JSON）。
///
/// 字段与 `Tools/RootTool.c` 里 `clean_write_scan_report` 一一对应。工具只写实测值
/// —— 没有任何占位数据（样本 iOSCleanerPro 里那组「Safari 150 MB」式的硬编码
/// 条目是刻意不要的），取不到显示名时 `name` 直接退回 bundle id。
nonisolated struct StorageScanReport: Codable {
    // 嵌套类型要各自标 `nonisolated`：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    // 会给未标注的声明加主 actor 隔离，而这些类型的 `init(from:)` 是在
    // `Task.detached` 里被 `JSONDecoder` 调的 —— 隔离成主 actor 就调不动了。
    // 顶层那个 `nonisolated` 不替嵌套类型兜底（同 `RadioAccessTechnology.Family`）。
    nonisolated struct Category: Codable {
        let bytes: Int64
    }

    nonisolated struct AppEntry: Codable {
        /// 真实 bundle id，来自容器根的 MCM 元数据（`MCMMetadataIdentifier`）。
        let bundle: String
        /// 显示名。取不到时工具已经退回 bundle id，所以这里实际总有值。
        let name: String
        /// .app 的安装路径。有值时 App 用它找图标；系统应用没有安装容器，为空。
        let bundlePath: String?
        let bytes: Int64
    }

    /// 一条预览样本：某个目录顶层的一个条目及其实测大小。
    nonisolated struct Sample: Codable {
        /// 顶层条目的文件名（不是完整路径 —— 界面上只显示名字）。
        let name: String
        let bytes: Int64
    }

    let categories: [String: Category]
    /// 四类目录各自的预览样本，键与 `categories` 相同（`system` / `logs` / `temp` / `update`），
    /// 每类按大小降序、最多 6 条 —— 工具侧已经排好序并截断，这里不再处理。
    ///
    /// 可选：旧版工具没有这个键，缺了只该少一块预览，不该让整次扫描判成失败。
    let samples: [String: [Sample]]?
    let apps: [AppEntry]
    /// 工具回传的逐项计数（已经是人读的字符串，App 原样显示、不解析）。
    ///
    /// 可选：工具版本比 App 旧时没有这个键，缺了不该让整次扫描判成失败。
    /// 2026-10-03 加 —— 应用缓存恒为 0 时，「容器目录打不开」「MCM 元数据读不出」
    /// 「Caches 真是空的」三种情况在界面上完全一样，靠这几行才能分开。
    let diagnostics: [String]?
}

/// 清理报告（`clean-run` 写出的 JSON）。
nonisolated struct StorageCleanReport: Codable {
    let scope: String
    /// 按「单个应用」清理时是那个 bundle id，其余为空串。
    let bundle: String?
    /// 本次实际释放的字节数（按删掉之前的文件大小累加）。
    let freedBytes: Int64
    /// 删不掉的条目。个别文件正被占用删不掉是常态 —— 有错误不等于清理失败。
    let errors: [String]?
}

/// 「存储清理」的范围。rawValue 直接作为工具子命令的 scope 参数，
/// 两边的拼写必须一致（CI 的构建断言只保证子命令在、不保证拼写对）。
nonisolated enum StorageCleanScope: String {
    /// `/var/mobile/Library/Caches` 的内容（顶层有排除名单，见 RootTool.c）。
    case system
    /// `/var/mobile/Library/Logs` 与 `/var/mobile/Library/Preferences/Logs` 的内容。
    case logs
    /// `/var/tmp` 的内容。
    case temp
    /// 系统更新包。工具查两个候选路径，哪个存在清哪个：
    /// `/var/mobile/Library/Assets/com_apple_MobileAsset_SoftwareUpdate`（现行）与
    /// `/var/mobile/Library/SoftwareUpdate`（旧系统）。都没有就是 0。
    case update
    /// 所有应用容器的可清目录（`Library/Caches` / `tmp` / `Library/Logs` /
    /// `Library/Saved Application State`）。
    case apps
    /// 单个应用（bundle id 作为附加参数传给工具）。
    case app
    /// 以上全部。
    case all
}

/// 一次扫描的结果。已经从工具的 JSON 翻译成界面直接能用的形状。
nonisolated struct StorageScanResult {
    /// 同上：嵌套类型自己标 `nonisolated`。这个结构体整个要跨
    /// `Task.detached` 边界传回主 actor，成员被推成主 actor 隔离就不满足
    /// `Sendable` 了。
    nonisolated struct AppCache: Identifiable {
        let bundle: String
        let name: String
        let bundlePath: String?
        let bytes: Int64

        var id: String { bundle }
    }

    /// 一类目录的一条预览条目。`id` 用条目名：同一个目录里不可能有重名条目。
    nonisolated struct Preview: Identifiable {
        let name: String
        let bytes: Int64

        var id: String { name }
    }

    let systemBytes: Int64
    let logsBytes: Int64
    let tempBytes: Int64
    /// 系统更新包。没下载过更新的设备恒为 0 —— 那是正常状态，不是「扫描没扫到」。
    let updateBytes: Int64
    /// 按缓存大小降序，工具已经排好。
    let apps: [AppCache]
    /// 四类目录的预览条目，键是 `StorageCleanScope` 的 rawValue。
    /// 工具没给（旧版本）时是空字典，取出来就是空数组。
    let previews: [String: [Preview]]

    /// 某一类目录的预览条目。空数组 = 这类没有可预览的内容（或工具没给）。
    ///
    /// 方法名**刻意不叫 `previews(for:)`** —— 与上面那个同名的存储属性挤在一起，
    /// 虽然按 Swift 的全名规则（`previews` vs `previews(for:)`）不冲突，
    /// 但读起来容易以为是同一个东西。
    func previewEntries(for scope: StorageCleanScope) -> [Preview] {
        previews[scope.rawValue] ?? []
    }

    /// 界面上「可清理」的口径：四类目录 + 未被保护的应用缓存。
    ///
    /// **扣掉 `protected` 里的应用**，而不是用原始合计 —— 按钮上写多少就该删多少，
    /// 否则用户按完发现少了一块，会以为清理没跑全。
    func cleanableBytes(protecting protected: Set<String>) -> Int64 {
        systemBytes + logsBytes + tempBytes + updateBytes
            + apps.reduce(Int64(0)) { $0 + (protected.contains($1.bundle) ? 0 : $1.bytes) }
    }

    /// 工具回传的诊断行，原样显示。空数组 = 工具没给（旧版本工具）。
    let diagnostics: [String]
}

/// 一次清理的结果。
nonisolated struct StorageCleanResult {
    let freedBytes: Int64
    let errors: [String]
}

/// 包内特权工具（`SysProbeRootTool`）的存储清理入口。
///
/// 与 `DeviceActions` 同一条链路：同一个工具二进制、同一个 root persona 启动方式
/// （`ChargeSpawn.c`），只是走的是 `clean-scan` / `clean-run` 子命令，并且用带
/// 超时预算的 `sysprobe_spawn_root_tool_sync_args` —— 扫描和清理是几十秒级的活，
/// 自检那个 1 秒预算会把正在干活的子进程误判成超时。
///
/// 两个阻塞调用都**必须放在主线程之外**跑（调用方用 `Task.detached`），
/// 与 `DeviceActions.probe()` 的约定一致。
nonisolated enum StorageCleaner {

    /// 一次扫描的等待预算。几百个容器的递归统计在老设备上可能要几十秒。
    ///
    /// 类型必须是 `Int32`：C 的 `int timeoutMs` 在 Swift 里是 `Int32`，而 Swift
    /// **不会**把 `Int` 隐式转过去（项目里所有 C `int` 参数都显式转换，
    /// 如 `sysprobe_local_port_open(Int32(ChargeBridge.port))`）。
    private static let scanTimeoutMs: Int32 = 120_000
    /// 一次「全部清理」的预算。删几十万个小文件是 IOPS 活，给足余量。
    private static let cleanTimeoutMs: Int32 = 300_000

    /// 跑一次扫描。任何一步失败都返回 `nil` —— 界面把它当「扫描失败」处理。
    ///
    /// 工具把 JSON 报告写到 App tmp 目录里的一个路径（构造为 `argv` 传下去），
    /// 读完就地删除。用 UUID 命名是为了在极端情况下（工具超时没写成报告）
    /// 也不会读到上一次的旧报告。
    static func scan() -> StorageScanResult? {
        guard let toolPath = DeviceActions.toolPath else { return nil }
        let reportPath = makeReportPath()

        var status: Int32 = 0
        // 扫描不需要任何附加参数 —— 三个位全传 nil。`nil` 只允许出现在**尾部**，
        // 这里全是 nil 所以合法（见 ChargeSpawn.h）。
        let spawnResult = sysprobe_spawn_root_tool_sync_args(
            toolPath, "clean-scan", reportPath, nil, nil, nil, scanTimeoutMs, &status)
        guard spawnResult == 0, status == toolExitOK else {
            removeReport(reportPath)
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: reportPath)),
              let report = try? JSONDecoder().decode(StorageScanReport.self, from: data) else {
            removeReport(reportPath)
            return nil
        }
        removeReport(reportPath)

        return StorageScanResult(
            systemBytes: report.categories["system"]?.bytes ?? 0,
            logsBytes: report.categories["logs"]?.bytes ?? 0,
            tempBytes: report.categories["temp"]?.bytes ?? 0,
            updateBytes: report.categories["update"]?.bytes ?? 0,
            apps: report.apps
                .filter { $0.bytes > 0 }
                .map { entry in
                    // 工具对取不到安装路径的应用写的是**空串**而不是 null ——
                    // 归一成 nil，别让界面拿 "" 去拼图标路径。
                    let bundlePath = entry.bundlePath.flatMap { $0.isEmpty ? nil : $0 }
                    return StorageScanResult.AppCache(bundle: entry.bundle,
                                                      name: entry.name,
                                                      bundlePath: bundlePath,
                                                      bytes: entry.bytes)
                },
            previews: (report.samples ?? [:]).mapValues { samples in
                samples.map { StorageScanResult.Preview(name: $0.name, bytes: $0.bytes) }
            },
            diagnostics: report.diagnostics ?? []
        )
    }

    /// 按范围清理。返回 `nil` 表示清理没能执行（工具不在包里 / 没拿到 root /
    /// 报告写不出来）；返回值代表**工具跑完了**，个别文件删不掉的明细在
    /// `errors` 里 —— 那是常态，不是失败。
    ///
    /// `exclude` 是「受保护」的应用 bundle id。工具只在清理**全部**应用容器时
    /// 用它，所以按 `app` 点名清一个应用时它不生效（那边也没传）。
    @discardableResult
    static func clean(_ scope: StorageCleanScope,
                      bundleId: String? = nil,
                      exclude: [String] = []) -> StorageCleanResult? {
        guard let toolPath = DeviceActions.toolPath else { return nil }
        let reportPath = makeReportPath()

        // 排除名单用逗号连接。bundle id 的字符集是 `[A-Za-z0-9.-]`，逗号不可能
        // 出现在里面，所以这个分隔符无歧义 —— 与工具侧 `clean_bundle_is_excluded`
        // 是同一套约定。
        let excludeCsv = exclude.isEmpty ? nil : exclude.joined(separator: ",")

        // `execve` 的 argv 在第一个 NULL 处截断，**不能有中间空位**（见 ChargeSpawn.h）：
        // 要传 `excludeCsv` 就必须先把 `bundleId` 那一格占住，用空串当占位。
        // 工具侧把空串与 NULL 同等看待（`do_clean_run` 开头归一）。
        let bundleArg: String?
        if let bundleId {
            bundleArg = bundleId
        } else if excludeCsv != nil {
            bundleArg = ""
        } else {
            bundleArg = nil
        }

        var status: Int32 = 0
        let spawnResult = sysprobe_spawn_root_tool_sync_args(
            toolPath, "clean-run", scope.rawValue, reportPath, bundleArg, excludeCsv,
            cleanTimeoutMs, &status)
        guard spawnResult == 0, status == toolExitOK else {
            removeReport(reportPath)
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: reportPath)),
              let report = try? JSONDecoder().decode(StorageCleanReport.self, from: data) else {
            removeReport(reportPath)
            return nil
        }
        removeReport(reportPath)

        return StorageCleanResult(freedBytes: report.freedBytes, errors: report.errors ?? [])
    }

    /// 与 `Tools/RootTool.c` 的退出码 enum 对齐：0 = 成功。
    /// 3（非 root）/ 4（失败）在这里都归为「没跑成」，界面上由 `toolReady`
    /// 自检先行兜住，不需要更细的区分。
    private static let toolExitOK: Int32 = 0

    private static func makeReportPath() -> String {
        let tmp = NSTemporaryDirectory() as NSString
        return tmp.appendingPathComponent("sysprobe-clean-\(UUID().uuidString).json")
    }

    private static func removeReport(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
