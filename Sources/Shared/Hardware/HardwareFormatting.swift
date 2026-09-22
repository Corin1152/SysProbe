import Foundation

nonisolated extension Formatting {
    /// 字节数按 1024 进制显示：`1.2 GB`。
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(value))
    }

    /// 网络速率：`4 KB/s`。
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0.5 else { return "0 KB/s" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    /// 内存条那种紧凑写法：`3.6 GB`，不带空格。
    static func memory(_ value: UInt64) -> String {
        bytes(value).replacingOccurrences(of: " ", with: "")
    }
}
