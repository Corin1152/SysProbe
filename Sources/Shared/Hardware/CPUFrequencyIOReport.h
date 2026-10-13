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

/// 最近一次 `sysprobe_real_cpu_frequency_mhz()` 的结果说明（**静态字符串，不需要释放**）。
///
/// IOReport 的失败是静默的 —— 订阅返回 NULL、调用方只看到 0、界面显示「—」，
/// 没有任何地方报错。排查「某个进程读不出频率」时，这个字符串就是唯一的线索。
///
/// 取值：`ok` · `no-symbols` · `no-subscription` · `no-freq-tables` ·
/// `sample1-null` · `sample2-null` · `delta-null` · `no-channels` · `all-idle` ·
/// `not-called` · `unsupported-arch`。
const char *sysprobe_ioreport_last_status(void);

#endif /* SYSPROBE_CPU_FREQUENCY_IOREPORT_H */
