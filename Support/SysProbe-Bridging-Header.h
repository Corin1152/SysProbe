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
//
//  **扩展 target 用同一份头文件。** 它的 sources 里既没有 Shared/Hardware 也没有
//  ChargeControl，这两个头文件对它来说只有声明、没有实现 —— 而声明没人调用就不会
//  产生符号引用，链接不受影响。共用一份省掉「两个头文件必须同步改」这个坑。
//

#import "CPUFrequencyProbe.h"
// 相对路径而不是加一条 HEADER_SEARCH_PATHS：扩展那边没有 ChargeControl 这一层，
// 为它多配一条搜索路径反而会让人以为扩展也用得到这个探针。
#import "../Sources/ChargeControl/ChargeSpawn.h"
