import Foundation

/// 唤醒设备列表。存 `UserDefaults`。
///
/// `@AppStorage` 只吃 `String` / `Int` / `Bool` 这类原始类型，装不下 `Codable` 数组，
/// 所以这里自己编／解一次 JSON。
///
/// 编解码失败一律**降级成空列表而不抛错**：一台设备叫不醒是小事，
/// 整个维护页打不开是大事。
@MainActor
final class WakeStore: ObservableObject {

    static let storageKey = "sysprobe.wake.devices"

    @Published private(set) var devices: [WakeDevice]

    init() {
        devices = Self.load()
    }

    private static func load() -> [WakeDevice] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([WakeDevice].self, from: data)) ?? []
    }

    func add(name: String, mac: String, host: String) {
        devices.append(WakeDevice(name: name, mac: mac, host: host))
        save()
    }

    func update(_ device: WakeDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        save()
    }

    func remove(_ device: WakeDevice) {
        devices.removeAll { $0.id == device.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
