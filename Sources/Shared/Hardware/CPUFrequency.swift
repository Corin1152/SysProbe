import Foundation

/// 实测 CPU 当前主频。
///
/// ## 数据来源（唯一一条）
///
/// **`sysprobe_real_cpu_frequency_mhz()`** —— IOReport 的 DVFS 加权频率
/// （CLPC 的 per-state residency），也就是 `powermetrics` 的口径。
/// 只是读内核里的计数器，**不抢性能核**，所以两个进程同时读没有副作用。
///
/// 这条链曾经长期不可用：需要「沙箱例外 `IOReportUserClient` + 特权标记
/// `com.apple.private.ioreporting.access`」**两条** entitlement 才能订阅，
/// 详见 `CPUFrequencyIOReport.c`。
///
/// ## 为什么**不再做**「标称主频 ±窗口」的校验（0.0.37 删除）
///
/// 0.0.34~0.0.36 这里有一道校验：读数必须落在标称主频的 1/5 ~ 1.15 倍之间，
/// 否则判为「不可信」。那道校验是给**忙循环探针**准备的 —— 探针靠「依赖 `add`
/// 的延迟 = 1 周期」这个**模型**推算频率，模型一旦不成立就会读出离谱数字，
/// 所以需要一层合理性过滤。
///
/// 但 IOReport 不是模型：它是内核自己维护的档位驻留直方图，**读到的就是真实值**，
/// 不存在「模型失效」这回事。给它套上探针的过滤窗口反而制造了新问题：
///
///   · A11 标称 2390 MHz → 下界 = 2390 / 5 = **478**；
///   · 而 A11 的 DVFS 最低档是 **453 MHz**（IOReport 实测）；
///   · 于是 CPU 一空闲、P 核落到最低档，读数就被判为不可信 → 界面闪「—」。
///
/// 这正是「频率偶发「—」、而且越空闲越频繁」的来源。现在只保留一个哨兵检查
/// （`1...10000`，纯粹防未初始化/脏数据），不再拿标称值当参照物。
///
/// ## 短缓存（保留）
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
    /// - Parameter nominalMHz: 该机型芯片的标称主频。**当前只用于诊断输出**，
    ///   不再参与可信度判定 —— 见文件头的说明。
    static func measureMHz(nominalMHz: Int) -> Int? {
        let measured = Int(sysprobe_real_cpu_frequency_mhz())
        let status = String(cString: sysprobe_ioreport_last_status())

        // 哨兵检查：只挡未初始化 / 脏数据，不拿标称值当参照。
        if measured > 0 && measured <= 10000 {
            cacheLock.lock()
            lastGoodMHz = measured
            lastGoodStamp = CFAbsoluteTimeGetCurrent()
            cacheLock.unlock()
            writeDiagnosis(status: status, value: measured, nominal: nominalMHz)
            return measured
        }

        // 这一拍没采到：看上一次的读数还新不新。
        cacheLock.lock()
        let cached = lastGoodMHz
        let age = CFAbsoluteTimeGetCurrent() - lastGoodStamp
        cacheLock.unlock()

        writeDiagnosis(status: status, value: 0, nominal: nominalMHz)
        if cached > 0 && age < staleWindow {
            return cached
        }
        return nil
    }

    // MARK: - 诊断

    /// 把最近一次 IOReport 调用的结果落到一个**容器外**的固定路径。
    ///
    /// 为什么需要：主 App 能读出频率、负一屏读不出，而 IOReport 的失败是**静默**的
    /// （订阅返回 NULL，调用方只看到 0）。没有这个文件就只能靠猜。
    ///
    /// 只在内容变化时写，所以稳态下几乎不产生 I/O。两个进程各写各的文件
    /// （用 bundle id 区分），不会互相覆盖。
    private static func writeDiagnosis(status: String, value: Int, nominal: Int) {
        let id = Bundle.main.bundleIdentifier ?? "unknown"
        let line = "bundle=\(id) pid=\(ProcessInfo.processInfo.processIdentifier) "
            + "status=\(status) value=\(value) nominal=\(nominal)\n"
        let path = "/var/mobile/Library/Caches/sysprobe_ioreport_\(id).txt"

        cacheLock.lock()
        let changed = (line != lastDiagLine)
        if changed { lastDiagLine = line }
        cacheLock.unlock()
        guard changed else { return }

        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private nonisolated(unsafe) static var lastDiagLine = ""
}
