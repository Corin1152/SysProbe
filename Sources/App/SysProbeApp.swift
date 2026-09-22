import SwiftUI

@main
struct SysProbeApp: App {
    // iOS 16: `ObservableObject` instances are held in `@StateObject` and injected
    // with `environmentObject` — the Observation framework is iOS 17 only.
    @StateObject private var monitor = PowerMonitor()
    @StateObject private var hardware = HardwareMonitor()
    @StateObject private var optimizer = MemoryOptimizer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(monitor)
                .environmentObject(hardware)
                .environmentObject(optimizer)
        }
    }
}
