import Darwin
import Foundation

/// 一次唤醒的结果。
///
/// **部分失败也算成功** —— 只要有一个地址发出去了，魔术包就已经上路。
/// 所以界面只看 `ok`，但把两个列表都留着：排查「为什么这台叫不醒」时，
/// 「发到哪儿了」比「成功了没有」有用得多。
nonisolated struct WakeResult: Sendable {
    /// 成功发出的目标地址。
    var delivered: [String] = []
    /// 没发出去的（地址 + errno）。
    var failed: [(destination: String, code: Int32)] = []

    var ok: Bool { !delivered.isEmpty }
}

/// 魔术包的发送。
///
/// ── iOS 上真正的坑：不能用 `255.255.255.255` ────────────────────────────────
///
/// iOS 14.5 起，往 `255.255.255.255` 发 UDP 会失败：`sendto` 返回 -1，
/// errno 是 `EHOSTUNREACH`（"No route to host"），抓包也确实没发出去。
///
/// 真正能发出去的是**定向广播**：先取本机自己的 IPv4（`getifaddrs`），
/// 再把最后一段换成 255（`192.168.1.20` → `192.168.1.255`）。所以这里先算本机地址
/// 再推导广播地址，而不是图省事写死一个 `255.255.255.255`。
///
/// iOS 14 起访问本地网络还需要 `NSLocalNetworkUsageDescription`（见 `project.yml`），
/// 第一次发送时系统会弹一次「允许访问本地网络」。
nonisolated enum WakeService {

    /// WOL 的常用端口。9（discard）比 7（echo）更常见，也是多数网卡默认监听的那个。
    static let defaultPort: UInt16 = 9

    // MARK: - MAC

    /// 解析 MAC。只数十六进制字符，分隔符（`：` `-` `.` 或无）一律忽略。
    ///
    /// 因此 `"hello"` 会被抽成空串 → 长度不对 → `nil`；
    /// `"00:11:22:33:44:55:66"` 会抽成 14 位 → 同样 `nil`。
    static func parseMAC(_ text: String) -> [UInt8]? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        return bytes
    }

    /// 统一显示成 `AA:BB:CC:DD:EE:FF`。解析不出来返回 `nil`。
    static func displayMAC(_ text: String) -> String? {
        guard let bytes = parseMAC(text) else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - 本机地址

    /// 本机第一个正在用的 IPv4（跳过 loopback）。取不到返回 `nil`。
    ///
    /// 用 `getifaddrs` 而不是查某个固定接口名：Wi-Fi 与蜂窝各有一个接口，
    /// 而且接口名在不同机型上不保证一致。
    static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }

            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    /// `192.168.1.20` → `192.168.1.255`。
    ///
    /// 假设 /24 —— 家庭网络几乎全是这个掩码，而 iOS 上也只有定向广播发得出去，
    /// 拿不到掩码时这是唯一能算的东西。用户若不在 /24 上，可以自己在 `host` 里
    /// 填准确的广播地址。
    static func directedBroadcast(localIPv4: String) -> String? {
        let parts = localIPv4.split(separator: ".").map(String.init)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    // MARK: - 发送

    /// 魔术包：6 字节 0xFF + MAC 重复 16 次，共 102 字节。
    static func magicPacket(mac: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        return packet
    }

    /// 发一次唤醒包。
    ///
    /// 目标地址按这个顺序试，能发多少发多少：
    ///
    ///   1. **本机网段的定向广播** —— iOS 上真正管用的那个（见类型头）；
    ///   2. 用户填的 `host` —— 覆盖跨网段，或路由器配了静态 ARP 的情况；
    ///   3. `255.255.255.255` —— 兜底。iOS 14.5+ 基本发不出去，但在一些网络／
    ///      旧系统上仍然有效，多试一次没有代价。
    static func wake(mac: [UInt8], host: String = "", port: UInt16 = defaultPort) -> WakeResult {
        var destinations: [String] = []

        if let local = localIPv4(), let broadcast = directedBroadcast(localIPv4: local) {
            destinations.append(broadcast)
        }

        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !destinations.contains(trimmed) {
            destinations.append(trimmed)
        }

        let globalBroadcast = "255.255.255.255"
        if !destinations.contains(globalBroadcast) {
            destinations.append(globalBroadcast)
        }

        var result = WakeResult()
        for destination in destinations {
            if let code = sendOne(mac: mac, host: destination, port: port) {
                result.failed.append((destination, code))
            } else {
                result.delivered.append(destination)
            }
        }
        return result
    }

    /// 往一个地址发一次。返回 `nil` 表示成功，否则是 errno。
    private static func sendOne(mac: [UInt8], host: String, port: UInt16) -> Int32? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        // `htons` 是宏，Swift 里用不上；`bigEndian` 就是网络字节序。
        address.sin_port = port.bigEndian

        // 用 `inet_pton` 而不是 `inet_addr`：后者把非法地址表示成 `INADDR_NONE`，
        // 与合法的 `255.255.255.255` 撞车，判不出错。
        let parsed = withUnsafeMutablePointer(to: &address.sin_addr) { target in
            inet_pton(AF_INET, host, UnsafeMutableRawPointer(target))
        }
        guard parsed == 1 else { return EINVAL }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return errno }
        defer { close(fd) }

        // 广播必须显式开。不开的话 `sendto` 对广播地址返回 EACCES。
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let packet = magicPacket(mac: mac)
        let sent = packet.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &address) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                    sendto(fd, base, packet.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count ? nil : errno
    }
}
