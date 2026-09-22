//
//  CPUFrequencyProbe.c
//  SysProbe
//
//  用一段**周期数已知**的循环实测 CPU 当前主频。
//
//  ## 为什么非得实测
//
//  iOS 不给沙箱 App 读主频的接口：
//
//  - `hw.cpufrequency` / `hw.cpufrequency_max` 是 macOS（Intel）专有的 sysctl，
//    真机上恒失败（本工程最早就是踩在这里 —— 界面一直显示「—」）；
//  - `IOReport`（`powermetrics` 走的那条路）要 `com.apple.private.ioreport` 特权；
//  - 设备树里的 `voltage-states` 能给出频率档位表，但那是**档位**，不是当前值。
//
//  能静态拿到的是「这台机器装的是哪颗芯片、标称跑多少」。而 CPU-X 之所以能显示
//  「当前主频」（它的界面文案就是 `CPU Current Speed` = 当前主频，与
//  `CPU Design Speed` = 设计主频并列），靠的正是这种忙循环实测 ——
//  它的 `cpufreq.c` 里同样是起线程、抬 QoS 那一套。
//
//  ## 原理
//
//  在 Apple 的 ARM64 核上，一条**依赖**的 `add` 延迟正好是 1 个周期。
//  于是「32 条首尾相接的 add」一轮就是 32 个周期，而循环自身的 `subs` / `b.ne`
//  不在这条依赖链上，乱序核有足够余量把它们完全重叠掉。
//
//  跑固定轮数、量墙钟时间，频率 = 周期数 / 秒。
//
//  这条链是**延迟受限**而不是吞吐受限的，所以结果与核的发射宽度无关 ——
//  A 系列任何一颗芯片上「1 周期 1 条 add」都成立，不需要按微架构查表。
//  （反过来，如果写成互相独立的 add，测出来的是 IPC 上限，不是频率。）
//
//  ## 为什么要单独起一条线程
//
//  调频是**按核**的。测之前得先把目标核的频率顶上去：
//  把这条线程的 QoS 抬到 user-interactive，调度器会把它放到性能核上并拉高频率。
//  直接在调用者的线程上改 QoS 是失礼的（那可能是协作线程池里的线程），
//  所以这里起一条自己的 pthread，测完就退出。
//
//  另外，Apple 的调频响应在几十毫秒量级，所以先跑一段**热身**再计测 ——
//  否则读到的是还没升上去的中间值。
//

#include "CPUFrequencyProbe.h"

#if defined(__arm64__)

#include <pthread.h>
#include <pthread/qos.h>
#include <sys/qos.h>
#include <time.h>

/// 一轮里的依赖 add 条数。改这个值必须同步改下面的汇编。
#define PROBE_UNROLL 32

/// 热身轮数：只为把频率顶上去，结果丢弃。约 5 ms。
#define PROBE_WARMUP_ROUNDS 400000

/// 计测轮数。约 4 ms，跑三轮取最高值。
#define PROBE_MEASURE_ROUNDS 300000
#define PROBE_MEASURE_ROUND_COUNT 3

/// 跑 `iterations` 轮，返回耗时纳秒。
///
/// `__volatile__` 是必须的：没有它编译器会把整段循环当成无用计算删掉。
/// `"cc"` 声明它会改标志位（`subs`）。
static uint64_t probe_run(uint64_t iterations) {
    uint64_t counter = iterations;
    uint64_t chain = 1;

    struct timespec start;
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    __asm__ __volatile__(
        "1:\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "subs %1, %1, #1\n"
        "b.ne 1b\n"
        : "+r"(chain), "+r"(counter)
        :
        : "cc");

    clock_gettime(CLOCK_MONOTONIC, &end);

    // 把链的终值用掉，免得编译器认为它没用。测频率不关心它是什么。
    __asm__ __volatile__("" : : "r"(chain) : "memory");

    uint64_t seconds = (uint64_t)(end.tv_sec - start.tv_sec);
    uint64_t nanos = (uint64_t)(end.tv_nsec - start.tv_nsec);
    // tv_nsec 可能借位（例如 1.9s → 2.1s 时差是 +0.2s 但两个字段都变了）。
    return seconds * 1000000000ull + nanos;
}

/// 线程入口。抬 QoS 再测。
static void *probe_thread_main(void *context) {
    // 抬到 user-interactive：调度器会把这条线程放到性能核上，并让频率升到上限。
    // 返回值忽略 —— 抬不上去也照测，只是读数可能偏低。
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    (void)probe_run(PROBE_WARMUP_ROUNDS);

    uint64_t best = 0;
    for (int round = 0; round < PROBE_MEASURE_ROUND_COUNT; round++) {
        uint64_t nanos = probe_run(PROBE_MEASURE_ROUNDS);
        if (nanos == 0) {
            continue;
        }
        // 周期数 / 纳秒 == GHz；×1000 得 MHz。
        uint64_t cycles = (uint64_t)PROBE_MEASURE_ROUNDS * PROBE_UNROLL;
        uint64_t megahertz = cycles * 1000ull / nanos;
        if (megahertz > best) {
            best = megahertz;
        }
    }

    *(uint64_t *)context = best;
    return NULL;
}

uint64_t sysprobe_measure_cpu_frequency_mhz(void) {
    uint64_t megahertz = 0;
    pthread_t thread;
    if (pthread_create(&thread, NULL, probe_thread_main, &megahertz) != 0) {
        return 0;
    }
    pthread_join(thread, NULL);
    return megahertz;
}

#else  /* !__arm64__ */

// 模拟器 / x86 上这套汇编没有意义（那台机器的主频也不是被测设备的主频）。
// 调用方拿到 0 会回落到机型表里的标称值。
uint64_t sysprobe_measure_cpu_frequency_mhz(void) {
    return 0;
}

#endif /* __arm64__ */
