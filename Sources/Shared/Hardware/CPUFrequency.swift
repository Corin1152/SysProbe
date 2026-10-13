import Foundation

/// 实测 CPU 当前主频。
///
/// ## 数据来源（唯一一条）
///
/// **`sysprobe_real_cpu_frequency_mhz()`** —— IOReport 的 DVFS 加权频率
/// （CLPC 的 per-state residency），也就是 `powermetrics` 的口径。
/// 只是读内核里的计数器，**不抢性能核**，所以两个进程同时读没有副作用。
///
/// 这条链需要「沙箱例外 `IOReportUserClient` + 特权标记
/// `com.apple.private.ioreporting.access`」**两条** entitlement 才能订阅，
/// 详见 `CPUFrequencyIOReport.c`。
///
/// ## 谁在用
///
/// **只有主 App。** 负一屏在 0.0.40 撤掉了频率显示 —— iOS 不允许 appex 访问
/// IOReport（实测 `IOReportCopyAllChannels` 在扩展里返回**空通道集**，而主 App
/// 用同样的调用拿到 6036 个通道），所以那边连采样都跳过了
/// （`HardwareMonitor(includeCPUFrequency: false)`）。
///
/// ## 为什么**不做**「标称主频 ±窗口」的校验
///
/// 曾经有一道校验：读数必须落在标称主频的 1/5 ~ 1.15 倍之间。那是给**忙循环探针**
/// 准备的 —— 探针靠「依赖 `add` 的延迟 = 1 周期」这个**模型**推算，模型失效会读出
/// 离谱数字，所以需要合理性过滤。
///
/// 但 IOReport 不是模型：它是内核自己维护的档位驻留直方图，**读到的就是真实值**。
/// 套上探针的窗口反而制造了新问题：
///
///   · A11 标称 2390 MHz → 下界 = 2390 / 5 = **478**；
///   · 而 A11 的 DVFS 最低档是 **453 MHz**（IOReport 实测）；
///   · 于是 CPU 一空闲、P 核落到最低档，读数就被判为不可信 → 界面闪「—」。
///
/// 现在只保留一个哨兵检查（`1...10000`，纯粹防未初始化/脏数据）。
///
/// ## 短缓存
///
/// IOReport 给的是「这段窗口里的加权平均」。设备深度空闲时，采样窗口里可能
/// **一次非 IDLE 驻留都没有** —— 加权平均无从算起，C 层返回 0。此时沿用上一次的
/// 读数比闪一下「—」更接近事实。窗口取 3 秒：比采样节拍（1 s）宽，能盖住偶发的
/// 全空闲窗口；又足够短，真降频/真变化仍然几秒内就反映出来。
///
/// 线程：`measureMHz` 是 `nonisolated`，IOReport 那条阻塞约 200 ms，
/// **必须在主线程之外调用**。缓存用锁保护。
nonisolated enum CPUFrequency {

    /// 上一次有效读数与它的时间戳。
    private nonisolated(unsafe) static var lastGoodMHz = 0
    private nonisolated(unsafe) static var lastGoodStamp: CFAbsoluteTime = 0
    private static let cacheLock = NSLock()

    /// 上一次读数最多能沿用多久（秒）。
    private static let staleWindow: CFAbsoluteTime = 3.0

    /// 实测主频（MHz）。测不出时返回 nil。
    ///
    /// - Parameter nominalMHz: 该机型芯片的标称主频。**当前不参与可信度判定** ——
    ///   见文件头的说明。保留这个参数是为了让调用点不必改签名。
    static func measureMHz(nominalMHz: Int) -> Int? {
        _ = nominalMHz

        let measured = Int(sysprobe_real_cpu_frequency_mhz())

        // 哨兵检查：只挡未初始化 / 脏数据，不拿标称值当参照。
        if measured > 0 && measured <= 10000 {
            cacheLock.lock()
            lastGoodMHz = measured
            lastGoodStamp = CFAbsoluteTimeGetCurrent()
            cacheLock.unlock()
            return measured
        }

        // 这一拍没采到：看上一次的读数还新不新。
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
