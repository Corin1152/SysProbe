import Foundation

/// 实测 CPU 当前主频。
///
/// 这一层只做三件事：把 C 层的结果**校验**一遍、给一个宽松的窗口、把「不可信」
/// 翻译成 `nil`（调用方回落到机型表里的标称值）。
///
/// ## 只有一条来源
///
/// **`sysprobe_real_cpu_frequency_mhz()`** —— IOReport 的真实 DVFS 加权频率
/// （CLPC 的 per-state residency）。只是读内核里的计数器，**不抢性能核**，
/// 所以两个进程同时读也没有副作用。
///
/// 0.0.34 起**删掉了忙循环探针的回落**（`sysprobe_measure_cpu_frequency_mhz`）：
/// 它量的是「核被顶到最高时能跑多快」（峰值，与负载关系不大），而且是 2 × 62 ms 的
/// user-interactive 忙循环、会抢前台。读不到就返回 nil，界面显示「—」
/// —— 宁可空着，也不给一个口径不对的数。
///
/// 第 1 条曾经长期不可用：iOS 上 `platform-application` 会让「每一个 IOKit user
/// client 都要显式例外」，而 IOReport 走的 `IOReportUserClient` 一直不在
/// `com.apple.security.iokit-user-client-class` 里 —— 详见 `CPUFrequencyIOReport.c`。
///
/// ## 为什么要校验
///
/// 探针的模型是「依赖 `add` 的延迟 = 1 周期」，这条在 Apple 的 ARM64 核上成立，
/// 但它终究是个模型。模型一旦不成立，读出来的会是一个离谱的数字 —— 那比显示标称值
/// 还糟。所以给一个宽容的窗口（标称的 1/5 到 1.15 倍）：落在外面的判为失效。
/// 窗口下界放得很低，是为了不把**真正的降频**（热限频、低电量模式）误判成失效
/// —— 那是这台机器此刻真实的主频。
///
/// 线程：`measure` 是 `nonisolated`，IOReport 那条阻塞约 100 ms、忙循环那条约
/// 15–20 ms，**必须在主线程之外调用**。
nonisolated enum CPUFrequency {

    /// 实测主频（MHz）。测不出或结果不可信时返回 nil。
    ///
    /// - Parameter nominalMHz: 该机型芯片的标称主频。0 表示认不出机型，此时不做校验
    ///   （没有参照物），直接采信结果。
    static func measureMHz(nominalMHz: Int) -> Int? {
        // **只走 IOReport**（0.0.34 起）。读不到就返回 nil —— 调用方据此把频率留 0、
        // 界面显示「—」，不再回落到忙循环探针：那条是 2 × 62 ms 的 user-interactive
        // 忙循环、会抢前台，而它量的是「能跑多快」的峰值，本来就不是这个数要回答的问题。
        let measured = Int(sysprobe_real_cpu_frequency_mhz())
        guard measured > 0 else { return nil }
        guard nominalMHz > 0 else { return measured }

        let lowerBound = nominalMHz / 5
        let upperBound = Int(Double(nominalMHz) * 1.15)
        guard measured >= lowerBound, measured <= upperBound else { return nil }
        return measured
    }
}
