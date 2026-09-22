//
//  CPUFrequencyProbe.h
//  SysProbe
//
//  实测 CPU 当前主频。实现与理由见 CPUFrequencyProbe.c。
//
//  只被主 App 使用（appex 的 sources 里没有 Shared/Hardware 这一层），
//  所以不需要给扩展配桥接头。
//

#ifndef SYSPROBE_CPU_FREQUENCY_PROBE_H
#define SYSPROBE_CPU_FREQUENCY_PROBE_H

#include <stdint.h>

/// 在一条独立的高 QoS 线程上实测当前 CPU 主频，单位 MHz。
///
/// 阻塞调用，一次约 15–20 ms。取多轮里的**最高值** —— 也就是这次测量期间核心
/// 真正达到过的频率，单核满载时会顶到性能核的上限。
///
/// 测不出来（非 arm64、线程起不来、计时器异常）返回 0。
uint64_t sysprobe_measure_cpu_frequency_mhz(void);

#endif /* SYSPROBE_CPU_FREQUENCY_PROBE_H */
