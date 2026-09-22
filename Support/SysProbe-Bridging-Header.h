//
//  SysProbe-Bridging-Header.h
//  SysProbe
//
//  主 App 的桥接头。目前只有一个用途：让 Swift 能调到实测 CPU 频率的 C 探针。
//
//  为什么探针必须是 C：Swift 没有内联汇编，而测频率靠的就是一段「周期数已知」的
//  汇编循环（见 CPUFrequencyProbe.c）。用纯 Swift 写循环，优化器会把它改写掉，
//  周期数就不确定了。
//
//  扩展 target 不需要这个文件：它的 sources 里没有 Shared/Hardware 这一层。
//

#import "CPUFrequencyProbe.h"
