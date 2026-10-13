import Foundation

/// 实测 CPU 当前主频。
///
/// 这一层做三件事：把 C 层的结果**校验**一遍、给一个宽容的窗口、把「不可信」
/// 翻译成 `nil`；另外给「这一拍恰好没采到」加一道短缓存，避免界面闪烁。
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
/// 这条链曾经长期不可用：iOS 上 `platform-application` 会让「每一个 IOKit user
/// client 都要显式例外」，而 IOReport 走的 `IOReportUserClient` 一直不在
/// `com.apple.security.iokit-user-client-class` 里；并且还要
/// `com.apple.private.ioreporting.access` 这个特权标记。详见 `CPUFrequencyIOReport.c`。
///
/// ## 为什么要校验
///
/// 读数的窗口是标称主频的 1/5 到 1.15 倍。窗口下界放得很低，是为了不把**真正的
/// 降频**（热限频、低电量模式）误判成失效 —— 那是这台机器此刻真实的主频；
/// 上界卡在 1.15 倍则是防「读到离谱数字」，那比显示标称值还糟。
///
/// ## 为什么要短缓存（0.0.35）
///
/// IOReport 给的是「这段窗口里的**加权平均**」。设备空闲时，采样窗口里可能
/// **一次非 IDLE 驻留都没有** —— 加权平均无从算起，C 层返回 0。但 CPU 并不是
/// 「没有频率」，只是这一拍恰好全空闲；此时沿用上一次的读数比闪一下「—」更接近事实。
/// （C 层同时把窗口从 100 ms 拉到了 200 ms 来降低发生概率，但那只降低概率。）
///
/// 缓存窗口取 3 秒：比采样节拍（1 s）宽，能盖住偶发的全空闲窗口；又足够短，
/// 不会让一个过期的值长期挂着 —— 真降频/真变化仍然几秒内就反映出来。
///
/// 线程：`measureMHz` 是 `nonisolated`，IOReport 那条阻塞约 200 ms，
/// **必须在主线程之外调用**。缓存用锁保护，因为调用方可能不止一个队列。
nonisolated enum CPUFrequency {

    /// 上一次**通过校验**的读数与它的时间戳。
    private nonisolated(unsafe) static var lastGoodMHz = 0
    private nonisolated(unsafe) static var lastGoodStamp: CFAbsoluteTime = 0
    private static let cacheLock = NSLock()

    /// 上一次读数最多能沿用多久（秒）。
    private static let staleWindow: CFAbsoluteTime = 3.0

    /// 实测主频（MHz）。测不出或结果不可信时返回 nil。
    ///
    /// - Parameter nominalMHz: 该机型芯片的标称主频。0 表示认不出机型，此时不做校验
    ///   （没有参照物），直接采信结果。
    static func measureMHz(nominalMHz: Int) -> Int? {
        // **只走 IOReport**。读不到就交给下面的缓存判定。
        let measured = Int(sysprobe_real_cpu_frequency_mhz())
        if measured > 0 {
            let plausible = nominalMHz <= 0
                || (measured >= nominalMHz / 5 && measured <= Int(Double(nominalMHz) * 1.15))
            if plausible {
                cacheLock.lock()
                lastGoodMHz = measured
                lastGoodStamp = CFAbsoluteTimeGetCurrent()
                cacheLock.unlock()
                return measured
            }
        }

        // 这一拍没采到（或不可信）：看上一次的读数还新不新。
        cacheLock.lock()
        let cached = lastGoodMHz
        let age = CFAbsoluteTimeGetCurrent() - lastGoodStamp
        cacheLock.unlock()

        if cached > 0 && age < staleWindow {
            return cached
        }
        return nil
    }
}
