import Foundation
import Darwin

// MARK: - Mach / BSD 小工具
//
// 这里的东西一律 `nonisolated`：本模块默认把所有声明推断成 MainActor 隔离
// （`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），而内存优化那部分跑在全局队列上，
// 调不到主 actor 的东西。

/// 系统页大小。
///
/// 不能直接读 `vm_kernel_page_size`：那是个 C 全局变量，Swift 6 在并发上下文里引用
/// 它会直接报错 —— "reference to var 'vm_kernel_page_size' is not concurrency-safe
/// because it involves shared mutable state"。`host_page_size()` 返回同一个值
/// （arm64 上是 16384），而且是普通函数调用，没有这个问题。
nonisolated func systemPageSize() -> UInt64 {
    var size: vm_size_t = 0
    guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else {
        // 读不到就退回 arm64 的页大小 —— 总比拿 0 去乘、让所有内存读数变成 0 好。
        return 16384
    }
    return UInt64(size)
}

/// 把 C 字符串缓冲区转成 `String`。
///
/// `String(cString:)` 在 Swift 6 里已废弃，理由正是它要求调用方自己先截断到第一个
/// NUL —— 而 `sysctlbyname` / `getnameinfo` 填回来的缓冲区恰好就是这种形态。
nonisolated func nullTerminatedString(_ chars: [CChar]) -> String {
    String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// 同上，但输入是 C 指针 —— `getifaddrs` 的 `ifa_name` 就是这种形态。
/// 单独一个参数标签，免得和数组那个重载在调用点上产生歧义。
nonisolated func nullTerminatedString(at pointer: UnsafePointer<CChar>) -> String {
    String(decoding: UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)), as: UTF8.self)
}
