//
//  SysProbe-Bridging-Header.h
//  SysProbe
//
//  主 App 的桥接头。两件事，都是「必须用 C 写」才放进来的：
//
//  1. 实测 CPU 频率的探针 —— Swift 没有内联汇编，而测频率靠的就是一段
//     「周期数已知」的汇编循环（见 CPUFrequencyProbe.c）。用纯 Swift 写循环，
//     优化器会把它改写掉，周期数就不确定了。
//  2. 启动充电守护进程、探测它的端口 —— `posix_spawn` 在 Swift 里的签名是五层嵌套
//     指针，而真正决定成败的 `posix_spawnattr_set_persona_np` 是 Apple 的 SPI，
//     公开 SDK 里没有声明（见 ChargeSpawn.c）。
//  3. 内存优化的两个系统接口（见文件末尾）—— 它们不在 Darwin 模块里，只引 Swift
//     找不到符号。
//
//  **扩展 target 用同一份头文件。** 它的 sources 里既没有 Shared/Hardware 也没有
//  ChargeControl，这两个头文件对它来说只有声明、没有实现 —— 而声明没人调用就不会
//  产生符号引用，链接不受影响。共用一份省掉「两个头文件必须同步改」这个坑。
//

#import "CPUFrequencyProbe.h"
// 相对路径而不是加一条 HEADER_SEARCH_PATHS：扩展那边没有 ChargeControl 这一层，
// 为它多配一条搜索路径反而会让人以为扩展也用得到这个探针。
#import "../Sources/ChargeControl/ChargeSpawn.h"
// 同上：扩展的 sources 里没有 DeviceControl，「频段设置」只有主 App 用得到。
#import "../Sources/DeviceControl/CommCenterBridge.h"

// 内存优化要用的两个系统接口。它们**不在** Darwin 模块里，光 `import Darwin` 找不到：
//
// - `os_proc_available_memory()`（声明在 `os/proc.h`）：返回本进程在触发 jetsam 之前
//   还能分配多少字节。内存优化拿它当「安全上限」，取代原先那个用错指标的 free 闸门。
// - `malloc_zone_pressure_relief()`（声明在 `malloc/malloc.h`）：让 libmalloc 把各 zone
//   里空闲的页交还内核，是苹果自己响应内存压力时走的同一条路。
//
// 扩展 target 共用这一份头文件，两个接口对 appex 同样存在 —— 只是 appex 从不调用
// `MemoryOptimizer.run()`，声明在那里不会有任何副作用。
#include <os/proc.h>
#include <malloc/malloc.h>
