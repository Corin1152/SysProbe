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
/// 另外还做两件确实有效的事：清掉本 App 自己的缓存（`URLCache` 等），以及把本进程
/// malloc 里空闲的页交还内核（`malloc_zone_pressure_relief`）。
///
/// 诚实地说一句：这一步的效果**天生有限**。「可用」= free + purgeable + speculative，
/// 而我们交还的那几百兆进了 free —— 面板上读得到的就是这一轮真正**逼出去的缓存**。
/// 它的意义是让系统当下多一块连续空闲页，不是「把别人的内存收回来」——
/// 那件事沙箱里做不到。
///
/// ## 停止判据：为什么不再看 `free`
///
/// 旧版拿 `vm_statistics64.free_count` 当闸门，低于 80 MB 就**在分配之前**退出。
/// 这个判据错得很稳定：iOS 的设计就是**把空闲内存全拿去当磁盘缓存**，所以
/// `free_count` 长期只有几十兆（旧注释自己记的本机实测是 87 MB）。于是循环几乎每次
/// 都在第一轮就退出，`allocated` 停在 0，界面报「可用内存过低，未执行分配」——
/// 可这根本不是「内存低」：free 低恰恰是 iOS 正常且健康的状态，此时内核完全能靠回收
/// purgeable / inactive / 压缩页满足分配，而这正是我们要它做的事。
///
/// 现在改用苹果为这件事提供的接口：`os_proc_available_memory()`（iOS 13+，声明在
/// `os/proc.h`，经桥接头引入）。它返回**本进程在触发 jetsam 之前还能分配多少字节**
/// —— 这正是「安全上限」的定义，比自算的比例准得多。分配过程中每轮读一次，低于安全垫
/// 就停；读不到（返回 0，或大于物理内存这种明显溢出的值）时，退回按物理内存比例取上限。
///
/// ## 分配改用 C 的 `malloc`
///
/// `UnsafeMutableRawPointer.allocate` 在分配失败时**直接 trap（崩溃）**，所以旧代码里
/// 那句 `guard let … else` 其实是死代码，永远走不到 —— 一个清理工具把用户 App 搞崩
/// 就太荒谬了。C 的 `malloc` 失败返回 NULL，可以体面地停下并如实报告。
final class MemoryOptimizer: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running(progress: Double, allocated: UInt64)
        /// `allocated` 是这一轮**实际**分配出去的字节数。它和 `after - before` 不是
        /// 一回事：分配量是「顶了多大的压力」，前后差值是「真的逼出来多少」——
        /// 两者都摆出来，才不会把「我尽力了但系统没吐」读成「什么都没干」。
        case finished(before: UInt64, after: UInt64, allocated: UInt64)
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

        // 分配与逐页写入要占住 CPU，不能放在主 actor 上 —— 否则界面会僵住一秒多。
        // 这个闭包是 `@Sendable` 的，所以它只能碰 `MemoryReclaimer`（非隔离）里的
        // 东西；回主线程更新状态走 `Task { @MainActor in }`。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 与界面同一个口径（`MemoryStats.available`）：free + purgeable + speculative。
            let before = MemoryReclaimer.availableBytes()
            let target = MemoryReclaimer.targetBytes()
            var pointers: [UnsafeMutableRawPointer] = []
            var allocated: UInt64 = 0
            // target 为 0 说明连一次都分配不了，同样算「提前停下」。
            var stoppedEarly = target == 0

            while allocated < target {
                // 安全闸门：进程在触发 jetsam 前还能分配多少。低于安全垫就停。
                //
                // 这里**不再**看 `free` —— 见类型头的说明：free 低是 iOS 的常态，
                // 拿它当闸门会让循环第一轮就退出。要看的是「内核还允许我们占多少」。
                if let headroom = MemoryReclaimer.processHeadroom(),
                   headroom < MemoryReclaimer.safetyMargin {
                    stoppedEarly = true
                    break
                }
                // 尾块可能不足一个 chunk，按剩余量收窄，免得最后一次分配越界。
                let chunk = min(MemoryReclaimer.chunkBytes, target - allocated)
                guard let pointer = MemoryReclaimer.allocateAndTouch(bytes: chunk) else {
                    stoppedEarly = true
                    break
                }
                pointers.append(pointer)
                allocated &+= chunk

                let progress = target == 0 ? 1 : min(1, Double(allocated) / Double(target))
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
                MemoryReclaimer.release(pointer)
            }
            pointers.removeAll()

            // 把本进程 malloc 里空闲的页真正交还内核。刚释放的那几块大分配走 large zone
            // （mmap / munmap，本来就还给内核），这一句是给中小分配与其它 zone 兜底的 ——
            // 否则它们会留在 malloc 的空闲池里，面板上的「可用」就涨不回去。
            MemoryReclaimer.relieveMallocPressure()

            // **立刻**读，不等系统把缓存填回去。
            //
            // 这里以前 sleep 0.25 秒再读，而那个等待正好把要看的东西等没了：刚释放的页
            // 立刻是 free，可 iOS 的磁盘缓存也会在几百毫秒内重新长回来，一觉醒来
            // 「可用」已经回到原样 —— 看起来就是「没有变化」。要看的是回收的**峰值**，
            // 那就得在释放的当口读。
            let after = MemoryReclaimer.availableBytes()

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
                    self.phase = .finished(before: before, after: after, allocated: totalAllocated)
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

    /// 目标分配量 = 物理内存的 28%，且不超过 512 MB；若进程额度可读，再夹到
    /// 「额度 − 安全垫」。三层取最小。
    ///
    /// 这个上限是保守取的。iPhone X 只有 3 GB 物理内存，真按「能占多少占多少」去压，
    /// 极容易被 jetsam 当成内存大户直接杀掉 —— 一个清理工具把自己清掉就太荒谬了。
    /// 有了下面的额度闸门，这个比例只是**上限**：实际能分配多少由系统说了算。
    static let maxFraction = 0.28
    static let maxBytes: UInt64 = 512 * 1024 * 1024

    /// 安全垫：进程剩余额度低于它就不再分配。留出余量给系统的其它开销，
    /// 免得把自己顶到 jetsam 的刀刃上。
    static let safetyMargin: UInt64 = 192 * 1024 * 1024

    static let chunkBytes: UInt64 = 8 * 1024 * 1024

    /// 这一轮打算分配多少字节。
    static func targetBytes() -> UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        var cap = min(UInt64(Double(physical) * maxFraction), maxBytes)
        if let headroom = processHeadroom() {
            // 额度本身就低于安全垫时（比如跑在内存预算极小的扩展里），退化为额度的一半：
            // 仍然给系统一点压力，但不冒险。
            let safe = headroom > safetyMargin ? headroom - safetyMargin : headroom / 2
            cap = min(cap, safe)
        }
        return cap
    }

    /// 本进程在触发 jetsam 之前还能分配的字节数（`os_proc_available_memory`）。
    ///
    /// 返回 `nil` 表示这个读数不可用，调用方应退回按物理内存比例估算：
    /// - 返回值 ≤ 0：非 App 进程，或该进程没有内存限额；
    /// - 返回值 > 物理内存：社区有报告称个别系统版本会返回溢出后的超大值，不采信。
    static func processHeadroom() -> UInt64? {
        let raw = os_proc_available_memory()
        guard raw > 0 else { return nil }
        guard UInt64(raw) <= ProcessInfo.processInfo.physicalMemory else { return nil }
        return UInt64(raw)
    }

    /// 申请一块内存并**逐页写入不可压缩的数据**。
    ///
    /// 用 C 的 `malloc`（失败返回 NULL）而不是 `UnsafeMutableRawPointer.allocate`
    /// —— 后者失败时直接 trap，等于把「分配不到」变成「崩溃」，没法优雅降级。
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
        guard size > 0, let pointer = malloc(size) else { return nil }
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

    /// 释放 `allocateAndTouch` 拿到的块。与 `malloc` 配对。
    static func release(_ pointer: UnsafeMutableRawPointer) {
        free(pointer)
    }

    /// 让 libmalloc 把各 zone 里空闲的页交还内核。
    ///
    /// 第一个参数传 NULL 表示遍历所有已注册的 zone，第二个是「目标释放量」，
    /// 传 0 表示能放多少放多少。苹果自己响应内核内存压力事件时走的就是这条路。
    static func relieveMallocPressure() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// 当前「可用」内存：free + purgeable + speculative。
    ///
    /// **与界面上的「可用」同一个口径**（`MemoryStats.available`）。两处不一致的话，
    /// 优化前后报出来的差值就没法跟面板上的数字对上。
    ///
    /// 刻意**不含 `inactive`**：inactive 里的页多数确实可回收，但内核回收它们的
    /// 同时就把 free 顶上去了 —— 两者之和在「逼出缓存」前后几乎不变（我们交还的
    /// 那几百兆进了 free，而被顶掉的缓存本来就落在 inactive 里），把它算进来，
    /// 优化前后读出来就是同一个数。
    ///
    /// 旧版这里还一并返回 `free_count` 用来做停止判据，这一版不需要了 ——
    /// 判据换成了 `processHeadroom()`，理由见 `MemoryOptimizer` 类型头。
    static func availableBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = systemPageSize()
        return (UInt64(stats.free_count)
                &+ UInt64(stats.purgeable_count)
                &+ UInt64(stats.speculative_count)) &* page
    }
}
