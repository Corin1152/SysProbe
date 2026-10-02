import Foundation

/// 一台可以被网络唤醒的设备。
///
/// ── 为什么 MAC 是必需的，而 IP 只是可选 ──────────────────────────────────────
///
/// 魔术包的载荷里装的是 **MAC 地址**（0xFF×6，后面接 MAC 重复 16 次）。目标机器关机时
/// 它的 IP 协议栈根本不工作：网卡只留一小块电路在监听链路层帧，比对的是
/// 「这个帧里有没有我自己的 MAC」。所以**只知道 IP 是叫不醒它的** ——
/// 除非路由器上配了静态 ARP 绑定加端口转发那一套。
///
/// `host` 的用途是**指定往哪儿发**：留空就用本机所在网段的定向广播（`a.b.c.255`）。
/// 填了就额外发一份到那个地址，用来覆盖跨网段、或路由器做了定向广播转发的情况。
nonisolated struct WakeDevice: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// MAC 地址。`AA:BB:CC:DD:EE:FF` / `AA-BB-CC-DD-EE-FF` / `AABBCCDDEEFF` 都认。
    var mac: String
    /// 可选的目标地址。可以是广播地址（`192.168.1.255`），也可以是设备自己的 IP。
    var host: String

    init(id: UUID = UUID(), name: String, mac: String, host: String = "") {
        self.id = id
        self.name = name
        self.mac = mac
        self.host = host
    }

    /// 列表里那一行下面的小字。
    ///
    /// MAC 优先显示成统一格式；IP 有就并排带上。两者都没有时退回原样显示 ——
    /// 那台设备是「填了一半」的状态，让它自己露出来比藏起来好。
    var subtitle: String {
        let formatted = WakeService.displayMAC(mac)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (formatted, trimmedHost.isEmpty) {
        case (.some(let value), false): return "\(value) · \(trimmedHost)"
        case (.some(let value), true): return value
        case (.none, false): return trimmedHost
        case (.none, true): return mac
        }
    }

    /// 能不能唤醒。缺 MAC 就不行 —— 见类型头上的说明。
    ///
    /// 界面据此禁用唤醒按钮，而不是等点了之后才报错。
    var canWake: Bool { WakeService.parseMAC(mac) != nil }
}
