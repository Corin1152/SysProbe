import Foundation
import Combine
import Darwin

/// 「内存优化」。
///
/// iOS 沙箱下无法释放别的 App 的内存 —— 内存由内核按进程管理，系统通过 jetsam
/// 自行回收，第三方 App 没有跨进程释放的手段。这里做的是业界通行的做法：
/// **短时间内申请一大块内存并逐页写入，把系统内存压力顶上去，逼内核回收文件缓存
/// 与其它进程的可回收页，然后立刻全部释放。**
///
/// 另外还做两件确实有效的事：清掉本 App 自己的缓存（`URLCache` 等），以及记录
/// 清理前后的可用内存做对比。
///
/// 诚实地说一句：这一步的效果**天生有限**。「可用」= free + purgeable + speculative，
/// 而我们交还的那几百兆进了 free —— 面板上读得到的就是这一轮真正**逼出去的缓存**。
/// 它的意义是让系统当下多一块连续空闲页，不是「把别人的内存收回来」——
/// 那件事沙箱里做不到。
///
/// 出于安全考虑，分配上限被限制在物理内存的一个比例，并且在可用内存过低时提前
/// 停止，避免自己触发 jetsam 被系统杀掉。
final class MemoryOptimizer: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running(progress: Double, allocated: UInt64)
        case finished(before: UInt64, after: UInt64)
        case failed(reason: String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastRun: Date?

    func run() {
        guard !phase.isRunning else { return }
        phase = .running(progress: 0, allocated: 0)

        // 先清本 App 自己的缓存，这部分是真实有效的。放在主 actor 上做，
        // 免得在下面那个 `@Sendable` 闭包里碰 `URLCache.shared` 这种非 Sendable 全局。
        URLCache.shared.removeAllCachedResponses()

        let cap = min(UInt64(Double(ProcessInfo.processInfo.physicalMemory) * MemoryReclaimer.maxFraction),
                      MemoryReclaimer.maxBytes)

        // 分配与逐页写入要占住 CPU，不能放在主 actor 上 —— 否则界面会僵住一秒多。
        // 这个闭包是 `@Sendable` 的，所以它只能碰 `MemoryReclaimer`（非隔离）里的
        // 东西；回主线程更新状态走 `Task { @MainActor in }`。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 与界面同一个口径（`MemoryStats.available`）：free + purgeable + speculative。
            let before = MemoryReclaimer.memoryPools().available
            var pointers: [UnsafeMutableRawPointer] = []
            var allocated: UInt64 = 0
            var stoppedEarly = false

            while allocated < cap {
                if MemoryReclaimer.memoryPools().free < MemoryReclaimer.floorBytes {
                    stoppedEarly = true
                    break
                }
                guard let pointer = MemoryReclaimer.allocateAndTouch(bytes: MemoryReclaimer.chunkBytes) else {
                    stoppedEarly = true
                    break
                }
                pointers.append(pointer)
                allocated &+= MemoryReclaimer.chunkBytes

                let progress = cap == 0 ? 1 : min(1, Double(allocated) / Double(cap))
                // 必须先把 `allocated` 拷成不可变的再送进 Task：直接捕获这个 `var`
                // 会被 Swift 6 判成 "sending 'allocated' risks causing data races"，
                // 因为外层循环还在改它。值类型拷贝是 Sendable，没问题。
                let soFar = allocated
                Task { @MainActor in
                    self?.phase = .running(progress: progress, allocated: soFar)
                }
            }

            // 让内核有时间真正做完回收 —— 换页、压缩、丢弃干净的文件缓存页。
            Thread.sleep(forTimeInterval: 0.5)
            for pointer in pointers {
                pointer.deallocate()
            }
            pointers.removeAll()

            // **立刻**读，不等系统把缓存填回去。
            //
            // 这里以前 sleep 0.25 秒再读，而那个等待正好把要看的东西等没了：刚释放的页
            // 立刻是 free，可 iOS 的磁盘缓存也会在几百毫秒内重新长回来，一觉醒来
            // 「可用」已经回到原样 —— 看起来就是「没有变化」。要看的是回收的**峰值**，
            // 那就得在释放的当口读。
            let after = MemoryReclaimer.memoryPools().available

            // 同上：两个 `var` 先落成 `let` 再跨隔离域。
            let totalAllocated = allocated
            let stoppedEarlyFlag = stoppedEarly

            Task { @MainActor in
                guard let self else { return }
                self.lastRun = .now
                if totalAllocated == 0 {
                    // 存英文键而不是已经翻好的中文：文案表按英文键索引，
                    // 在这里翻就等于把语言写死在后台线程上。
                    self.phase = .failed(reason: stoppedEarlyFlag
                                         ? "Available memory was too low, so nothing was allocated."
                                         : "Could not allocate memory.")
                } else {
                    self.phase = .finished(before: before, after: after)
                }
            }
        }
    }

    func reset() {
        guard !phase.isRunning else { return }
        phase = .idle
    }
}

// MARK: - 后台实际干活的部分

/// 故意放在文件作用域并标成 `nonisolated`：本模块默认把所有声明都推断成 MainActor
/// 隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），而下面这些代码跑在全局队列上、
/// 完全不碰 UI，必须显式脱离主 actor，否则后台闭包里调用它们会直接编译不过。
nonisolated private enum MemoryReclaimer {

    /// 分配上限：物理内存的 18%，且不超过 448 MB。
    ///
    /// 这个上限是保守取的。iPhone X 只有 3 GB 物理内存，真按「能占多少占多少」去压，
    /// 极容易被 jetsam 当成内存大户直接杀掉 —— 一个清理工具把自己清掉就太荒谬了。
    /// （448 MB 约是 3 GB 机型上前台 App jetsam 阈值的四成。）
    static let maxFraction = 0.18
    static let maxBytes: UInt64 = 448 * 1024 * 1024

    /// 低于这个**空闲页**数量就停止分配。这是真正兜底的一道闸。
    ///
    /// 判据是 `free`，而**不是**「可用」（free + inactive）—— 这里以前用的是后者、
    /// 阈值 250 MB，那个闸门定得太高：iOS 的 inactive 里绝大部分是可回收页，系统在
    /// free 只剩几十兆时照样活得好好的，于是循环往往刚跑一两轮就退出，实际只分配了
    /// 几十兆，内存压力根本没顶上去，「优化」自然看不出变化。
    ///
    /// 真正会触发 jetsam 的是 **free 池被耗尽**，所以闸门设在它上面。
    /// 而 free 被我们压下去时，内核会主动回收缓存把它顶回来 —— 这正好是我们要它做的事，
    /// 于是循环能一直跑到 `cap` 为止。
    static let floorBytes: UInt64 = 80 * 1024 * 1024

    static let chunkBytes: UInt64 = 8 * 1024 * 1024

    /// 申请一块内存并**逐页写入不可压缩的数据**。
    ///
    /// 只申请不写拿到的是惰性分配的虚拟地址，一个物理页都不会占，也就顶不出任何
    /// 内存压力 —— 这一步是整个机制能不能成立的关键，不是可有可无的初始化。
    ///
    /// 写的是 xorshift 序列，而不是同一个字节：以前用 `memset(…, 0xA5, …)`，那有个
    /// 反效果 —— iOS 的 VM 压缩器对「一整页都是 0xA5」的页几乎能压到零，于是这 8 MB
    /// 实际上只占了几十 KB 物理内存，压力根本没顶上去。每页都不重样的数据压不动，
    /// 分配才真的落在物理内存上。
    static func allocateAndTouch(bytes: UInt64) -> UnsafeMutableRawPointer? {
        let size = Int(bytes)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        let wordCount = size / MemoryLayout<UInt64>.size
        let words = pointer.bindMemory(to: UInt64.self, capacity: wordCount)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0 ..< wordCount {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            words[index] = state
        }
        return pointer
    }

    /// 一次读回两个数。
    ///
    /// - `available` = free + purgeable + speculative，**与界面上的「可用」同一个口径**
    ///   （`MemoryStats.available`）。两处不一致的话，优化前后报出来的差值就没法跟
    ///   面板上的数字对上。
    /// - `free` 只有空闲页，用来做停止判据。见 `floorBytes`。
    static func memoryPools() -> (available: UInt64, free: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let page = systemPageSize()
        let free = UInt64(stats.free_count) &* page
        let available = (UInt64(stats.free_count)
                         &+ UInt64(stats.purgeable_count)
                         &+ UInt64(stats.speculative_count)) &* page
        return (available, free)
    }
}
