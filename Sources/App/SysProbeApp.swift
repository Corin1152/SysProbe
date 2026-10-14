import SwiftUI

@main
struct SysProbeApp: App {
    // iOS 16: `ObservableObject` instances are held in `@StateObject` and injected
    // with `environmentObject` — the Observation framework is iOS 17 only.
    @StateObject private var app = AppState()
    @StateObject private var monitor = PowerMonitor()
    @StateObject private var hardware = HardwareMonitor()
    @StateObject private var optimizer = MemoryOptimizer()
    /// 充电控制。它管着 1230 端口上那个守护进程的存活，以及从它那里读回来的
    /// 配置与电池读数 —— 见 `ChargeControlService`。
    @StateObject private var charge = ChargeControlService()

    init() {
        // 语言要在第一帧之前就位。`AppFont` 与 `Strings.text` 读的是
        // `AppLanguage.current` 这个全局，而 `@StateObject` 的自动闭包要等到第一次
        // 求值 `body` 才跑 —— 那时第一屏已经在渲染了。
        //
        // 这里不再需要给 `Bundle.main` 换类：SwiftUI 的 `Text("…")` 不走
        // `localizedString(forKey:value:table:)`，换类对它一个字都不生效。
        // 语言固定跟随系统，没有用户可设的开关（2026-10-11）。
        AppLanguage.current = .systemPreferred
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(monitor)
                // 页面外壳专用的低频状态（降频 / 无线 / 插电）。与 `monitor` 分开注入：
                // 外壳只该观察它，观察 `monitor` 等于每秒重算一次整页外壳。见 `PowerContext`。
                .environmentObject(monitor.context)
                .environmentObject(hardware)
                .environmentObject(optimizer)
                .environmentObject(charge)
                // 转场（启动第一帧、切分页、弹／收设置页）里若有一帧还没画上内容，
                // 露出来的就是窗口底色。铺一层画布色，省得闪出系统白／系统黑。
                .background(Color.mwCanvas.ignoresSafeArea())
        }
    }
}
