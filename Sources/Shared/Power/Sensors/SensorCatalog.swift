import CoreGraphics
import Foundation

/// Where in the phone a temperature sensor sits.
///
/// Sensor names differ between iPhone models, so nothing is matched exactly:
/// every name falls into a zone by keyword, and anything unrecognised lands in
/// `.other` and is still shown. A new phone model degrades to a longer "other"
/// list rather than to an empty screen.
nonisolated enum ThermalZone: String, CaseIterable, Identifiable {
    case battery
    case charger
    case wirelessCoil
    case soc
    case storage
    case radio
    case display
    case camera
    case surface
    case other

    var id: String { rawValue }

    /// 译文由 `Strings.text` 直接查表得到，返回 `String`。
    ///
    /// 这里一度返回 `LocalizedStringKey` —— 那是 SwiftUI 的类型，而本层是主 App 与
    /// 负一屏扩展共用的。扩展那一侧必须完全脱离 SwiftUI（见 `TodayStyle`），
    /// 所以整层的 `LocalizedStringKey` 都换掉了。
    var title: String {
        switch self {
        case .battery: return Strings.text("Battery")
        case .charger: return Strings.text("Charge IC")
        case .wirelessCoil: return Strings.text("Wireless coil")
        case .soc: return Strings.text("SoC dies")
        case .storage: return Strings.text("Storage")
        case .radio: return Strings.text("Radios")
        case .display: return Strings.text("Display")
        case .camera: return Strings.text("Camera")
        case .surface: return Strings.text("Chassis")
        case .other: return Strings.text("Other sensors")
        }
    }

    var symbol: String {
        switch self {
        case .battery: return "battery.100"
        case .charger: return "bolt.square"
        case .wirelessCoil: return "wave.3.right.circle"
        case .soc: return "cpu"
        case .storage: return "internaldrive"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .display: return "square.on.square"
        case .camera: return "camera"
        case .surface: return "iphone"
        case .other: return "sensor"
        }
    }

    /// Schematic position on the phone silhouette, in unit coordinates
    /// (0,0 = top-left, 1,1 = bottom-right).
    ///
    /// iOS reports sensor names and temperatures and nothing else — there are no
    /// coordinates to read — so these are fixed per zone and identical on every
    /// model, while real internal layouts differ from generation to generation.
    /// They follow the usual arrangement of a recent iPhone: the logic board with
    /// the SoC and storage stacked in the upper third behind the camera plateau,
    /// the battery as the large mass through the middle and lower half, and the
    /// charge IC down by the port. That is why the top of the phone runs hot to
    /// the touch near the cameras while charging: the SoC is what is under there,
    /// not the cameras.
    var position: CGPoint {
        switch self {
        case .camera: return CGPoint(x: 0.28, y: 0.11)
        case .radio: return CGPoint(x: 0.63, y: 0.12)
        case .soc: return CGPoint(x: 0.37, y: 0.24)
        case .display: return CGPoint(x: 0.70, y: 0.31)
        case .storage: return CGPoint(x: 0.31, y: 0.35)
        case .wirelessCoil: return CGPoint(x: 0.52, y: 0.50)
        case .battery: return CGPoint(x: 0.44, y: 0.65)
        case .surface: return CGPoint(x: 0.73, y: 0.71)
        case .charger: return CGPoint(x: 0.50, y: 0.87)
        case .other: return CGPoint(x: 0.26, y: 0.83)
        }
    }

    /// Display order, hottest-interest first.
    var order: Int { ThermalZone.allCases.firstIndex(of: self) ?? 99 }
}

nonisolated enum SensorCatalog {
    /// Human labels for the sensors we understand. Everything else keeps its raw name.
    private static let labels: [String: String] = [
        "Charger VQ0u": "USB-C input voltage",
        "Charger IQ0u": "USB-C input current",
        "Charger VQ1u": "Wireless input voltage",
        "Charger IQ1u": "Wireless input current",
        "Charger VQ0l": "Battery rail voltage",
        "Charger IQ0B": "Current into battery",
        "PMU VP0u": "Battery pack voltage",
        "gas gauge battery": "Battery cell",
        "Charger TQ0j": "Charge IC junction",
        "Charger TQ0d": "Charge IC die",
    ]

    /// The translated label for a sensor we recognise, or nil for one we do not.
    /// Callers show the hardware name itself in that case — `Charger VQ0u` is not
    /// copy, and must never reach the string catalog as a lookup key.
    static func label(for name: String) -> String? {
        labels[name].map { Strings.text($0) }
    }

    /// Sorts a sensor name into a zone by whole words rather than by substring.
    ///
    /// Substring matching was wrong in both directions: "surface" contains "rf"
    /// and would have been filed as a radio, while "cellular" contains "cell" and
    /// would have been filed as the battery. Names are split into words and a word
    /// has to start with the keyword, which keeps "tdie1" matching "tdie" without
    /// letting "surface" match "rf".
    static func zone(for name: String) -> ThermalZone {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func has(_ keywords: String...) -> Bool {
            keywords.contains { keyword in words.contains { $0.hasPrefix(keyword) } }
        }
        // Order matters: the first zone that matches wins, so the specific names
        // are tested before the ones that would also match something generic.
        if has("modem", "baseband", "wifi", "antenna", "cellular", "nfc", "uwb", "bt") { return .radio }
        if has("cam") { return .camera }
        if has("wlc", "coil", "magsafe", "wireless", "qi") { return .wirelessCoil }
        if has("charger", "chg", "tcpm", "usb", "vbus") { return .charger }
        if has("battery", "batt", "gauge", "gas", "cell", "pack") { return .battery }
        if has("nand", "ssd", "flash", "nvme") { return .storage }
        if has("display", "lcd", "oled", "backlight") { return .display }
        if has("tdie", "tcal", "soc", "cpu", "gpu", "ane", "pmu", "die") { return .soc }
        if has("skin", "chassis", "enclosure", "front", "back", "rear", "case") { return .surface }
        return .other
    }
}
