import SwiftUI

@main
struct SysProbeApp: App {
    // iOS 16: `ObservableObject` instances are held in `@StateObject` and injected
    // with `environmentObject` — the Observation framework is iOS 17 only.
    @StateObject private var app = AppState()
    @StateObject private var monitor = PowerMonitor()
    @StateObject private var hardware = HardwareMonitor()
    @StateObject private var optimizer = MemoryOptimizer()

    init() {
        // 必须在第一帧之前把 `Bundle.main` 的类换掉：文案是渲染时从 `Bundle.main`
        // 取出来的，晚一步第一屏就会走原路径，留下半屏英文。
        LocalizationBootstrap.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(monitor)
                .environmentObject(hardware)
                .environmentObject(optimizer)
        }
    }
}
