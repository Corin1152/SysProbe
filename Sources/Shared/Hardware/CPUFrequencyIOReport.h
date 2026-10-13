//
//  CPUFrequencyIOReport.h
//  SysProbe
//
//  从 IOReport 读 CPU 的真实运行频率（CLPC 的 per-state residency 加权平均）。
//  实现、失败语义与「为什么以前用不了」见 CPUFrequencyIOReport.c。
//

#ifndef SYSPROBE_CPU_FREQUENCY_IOREPORT_H
#define SYSPROBE_CPU_FREQUENCY_IOREPORT_H

#include <stdint.h>

/// 从 IOReport 读性能簇（P 核）的加权平均频率，单位 MHz。
///
/// **阻塞约 100 ms**（两次采样之间的差分窗口），必须在主线程之外调用。
///
/// 任一步失败都返回 0（非 root、符号缺失、订阅被拒、找不到档位表、采样窗口全 IDLE），
/// 调用方据此回落到 `sysprobe_measure_cpu_frequency_mhz()` 的忙循环探针。
///
/// 与忙循环探针的关键区别：IOReport 只是读内核里的计数器，**不会抢性能核**，
/// 所以两个进程同时读没有副作用。
uint64_t sysprobe_real_cpu_frequency_mhz(void);

#endif /* SYSPROBE_CPU_FREQUENCY_IOREPORT_H */
