import Foundation

/// 实测 CPU 当前主频。
///
/// 这一层只做三件事：把 C 探针的结果**校验**一遍、给一个宽松的缓存、把
/// 「不可信」翻译成 `nil`（调用方回落到机型表里的标称值）。
///
/// 为什么必须校验：探针的模型是「依赖 `add` 的延迟 = 1 周期」，这条在 Apple 的
/// ARM64 核上成立，但它终究是个模型。模型一旦不成立，读出来的会是一个离谱的数字
/// —— 那比显示标称值还糟。所以给一个宽容的窗口（标称的 1/5 到 1.15 倍）：
/// 落在外面的判为失效，回落到标称。窗口下界放得很低，是为了不把**真正的降频**
/// （热限频、低电量模式）误判成失效 —— 那是这台机器此刻真实的主频。
///
/// 线程：`measure` 是 `nonisolated` 且会阻塞约 15–20 ms，**必须在主线程之外调用**。
/// 见 `HardwareMonitor.refreshFrequencyIfNeeded`。
nonisolated enum CPUFrequency {

    /// 实测主频（MHz）。测不出或结果不可信时返回 nil。
    ///
    /// - Parameter nominalMHz: 该机型芯片的标称主频。0 表示认不出机型，此时不做校验
    ///   （没有参照物），直接采信探针的结果。
    static func measureMHz(nominalMHz: Int) -> Int? {
        let measured = Int(sysprobe_measure_cpu_frequency_mhz())
        guard measured > 0 else { return nil }
        guard nominalMHz > 0 else { return measured }

        let lowerBound = nominalMHz / 5
        let upperBound = Int(Double(nominalMHz) * 1.15)
        guard measured >= lowerBound, measured <= upperBound else { return nil }
        return measured
    }
}
