//
//  CPUFrequencyIOReport.c
//  SysProbe
//
//  从 IOReport 读 CPU 的**真实运行频率** —— 也就是 `powermetrics` 用的那条路。
//
//  ## 为什么要有这一层
//
//  `CPUFrequencyProbe.c` 的忙循环量的是「核被顶到最高时能跑多快」，是**峰值**，
//  与当前负载关系不大；而且它是 2 × 62 ms 的 user-interactive 忙循环，会抢前台。
//  IOReport 给的是另一回事：CLPC 每个频率档位的**驻留时间直方图**，按档位频率加权
//  就是这段窗口里的**实际平均频率** —— 这才是「当前主频」。
//
//  ## 为什么以前用不了（2026-10-13 定位）
//
//  不是 entitlement 的问题，是 **IOKit user client 的沙箱例外**：
//
//    · iOS 上 `platform-application` 会让「每一个 IOKit user client 都要显式例外」
//      （TrollStore README 原文），而 IOReport 走的正是 `IOReportUserClient`；
//    · 它一直不在 `com.apple.security.iokit-user-client-class` 里，所以
//      `IOReportCreateSubscription` 对每个 group 都返回 NULL（REFUSED）；
//    · 此前挂的 `com.apple.private.ioreport.allow` 是**臆测的名字** ——
//      Apple 的 entitlement 库里不存在它（真实存在的是
//      `com.apple.private.ioreporting.access`），所以那条一直是空操作。
//
//  补上 `IOReportUserClient` 之后，iPhone X / iOS 16.5.1 实测所有 CPU group 均
//  subscribe=ok，`CPU Stats / CPU Complex Performance States` 的 4 个通道
//  （ECPU / ECPM / PCPU / PCPM，State 格式）可用。
//
//  ## 与 Helium（Statusbar）那边的关系
//
//  两个 App 各自持有同一份实现（Helium 的是 `CPUFrequencyReal.mm`）。这是刻意的：
//  IOReport 只是读内核里的计数器，**不像忙循环探针那样会互抢性能核**，所以两个
//  进程同时读没有副作用。SysProbe 平时仍然优先用 Helium 发布的共享文件（两边显示
//  同一个数），只有在文件读不到时才落到这里 —— 见 `HardwareMonitor.sample`。
//
//  ## 失败即返回 0
//
//  每一步（符号、订阅、频率表、采样）失败都返回 0，调用方据此回落到忙循环探针。
//  绝不抛异常、绝不崩：这条路径可能在扩展里被调到。
//

#include "CPUFrequencyIOReport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach.h>          // mach_port_t
#include <objc/objc.h>          // BOOL / YES / NO
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if defined(__arm64__) || defined(__x86_64__)

// ---------------------------------------------------------------------------
// IOReport 私有符号（运行时解析）
// ---------------------------------------------------------------------------

typedef void *IORepSubRef;

typedef CFMutableDictionaryRef (*fn_CopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CFMutableDictionaryRef (*fn_CopyAllChannels)(uint64_t, uint64_t);
typedef IORepSubRef (*fn_CreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*fn_CreateSamples)(IORepSubRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*fn_CreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*fn_ChannelGetChannelName)(CFDictionaryRef);
typedef CFStringRef (*fn_ChannelGetGroup)(CFDictionaryRef);
typedef CFStringRef (*fn_ChannelGetSubGroup)(CFDictionaryRef);
typedef int (*fn_StateGetCount)(CFDictionaryRef);
typedef int64_t (*fn_StateGetResidency)(CFDictionaryRef, int);

// IOKit（也是私有，运行时解析）
typedef unsigned int io_object_t;
typedef unsigned int io_iterator_t;
typedef unsigned int io_registry_entry_t;

typedef CFMutableDictionaryRef (*fn_IOServiceMatching)(const char *);
typedef int (*fn_IOServiceGetMatchingServices)(mach_port_t, CFDictionaryRef, io_iterator_t *);
typedef int (*fn_IORegistryCreateIterator)(mach_port_t, const char *, uint32_t, io_iterator_t *);
typedef io_object_t (*fn_IOIteratorNext)(io_iterator_t);
typedef int (*fn_IOObjectRelease)(io_object_t);
typedef CFTypeRef (*fn_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
typedef int (*fn_IORegistryEntryCreateCFProperties)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);

static BOOL gSymbolsTried = NO;
static BOOL gSymbolsOK = NO;

static fn_CopyChannelsInGroup pCopyChannelsInGroup = NULL;
static fn_CreateSubscription pCreateSubscription = NULL;
static fn_CreateSamples pCreateSamples = NULL;
static fn_CreateSamplesDelta pCreateSamplesDelta = NULL;
static fn_ChannelGetChannelName pChannelGetChannelName = NULL;
static fn_StateGetCount pStateGetCount = NULL;
static fn_StateGetResidency pStateGetResidency = NULL;

static fn_IOServiceMatching pIOServiceMatching = NULL;
static fn_IOServiceGetMatchingServices pIOServiceGetMatchingServices = NULL;
static fn_IORegistryCreateIterator pIORegistryCreateIterator = NULL;
static fn_IOIteratorNext pIOIteratorNext = NULL;
static fn_IOObjectRelease pIOObjectRelease = NULL;
static fn_IORegistryEntryCreateCFProperty pIORegistryEntryCreateCFProperty = NULL;
static fn_IORegistryEntryCreateCFProperties pIORegistryEntryCreateCFProperties = NULL;

static void *gIOKitHandle = NULL;

/// IOKit.framework 已经链进来了，符号通常在默认命名空间；找不到再 dlopen 一次。
static void *resolve_symbol(const char *name)
{
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    if (!gIOKitHandle) {
        gIOKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!gIOKitHandle) {
            gIOKitHandle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        }
    }
    return gIOKitHandle ? dlsym(gIOKitHandle, name) : NULL;
}

static BOOL ensure_symbols(void)
{
    if (gSymbolsTried) return gSymbolsOK;
    gSymbolsTried = YES;

    pCopyChannelsInGroup = (fn_CopyChannelsInGroup)resolve_symbol("IOReportCopyChannelsInGroup");
    pCreateSubscription  = (fn_CreateSubscription)resolve_symbol("IOReportCreateSubscription");
    pCreateSamples       = (fn_CreateSamples)resolve_symbol("IOReportCreateSamples");
    pCreateSamplesDelta  = (fn_CreateSamplesDelta)resolve_symbol("IOReportCreateSamplesDelta");
    pChannelGetChannelName = (fn_ChannelGetChannelName)resolve_symbol("IOReportChannelGetChannelName");
    pStateGetCount       = (fn_StateGetCount)resolve_symbol("IOReportStateGetCount");
    pStateGetResidency   = (fn_StateGetResidency)resolve_symbol("IOReportStateGetResidency");

    pIOServiceMatching   = (fn_IOServiceMatching)resolve_symbol("IOServiceMatching");
    pIOServiceGetMatchingServices = (fn_IOServiceGetMatchingServices)resolve_symbol("IOServiceGetMatchingServices");
    pIORegistryCreateIterator = (fn_IORegistryCreateIterator)resolve_symbol("IORegistryCreateIterator");
    pIOIteratorNext      = (fn_IOIteratorNext)resolve_symbol("IOIteratorNext");
    pIOObjectRelease     = (fn_IOObjectRelease)resolve_symbol("IOObjectRelease");
    pIORegistryEntryCreateCFProperty = (fn_IORegistryEntryCreateCFProperty)resolve_symbol("IORegistryEntryCreateCFProperty");
    pIORegistryEntryCreateCFProperties = (fn_IORegistryEntryCreateCFProperties)resolve_symbol("IORegistryEntryCreateCFProperties");

    gSymbolsOK = (pCopyChannelsInGroup && pCreateSubscription && pCreateSamples &&
                  pCreateSamplesDelta && pChannelGetChannelName && pStateGetCount &&
                  pStateGetResidency);
    return gSymbolsOK;
}

// ---------------------------------------------------------------------------
// 通道集辅助
// ---------------------------------------------------------------------------

static CFArrayRef channel_array_of(CFDictionaryRef channelSet)
{
    if (!channelSet) return NULL;
    CFTypeRef arr = CFDictionaryGetValue(channelSet, CFSTR("IOReportChannels"));
    if (!arr || CFGetTypeID(arr) != CFArrayGetTypeID()) return NULL;
    return (CFArrayRef)arr;
}

static CFIndex channel_count_of(CFDictionaryRef channelSet)
{
    CFArrayRef arr = channel_array_of(channelSet);
    return arr ? CFArrayGetCount(arr) : 0;
}

// ---------------------------------------------------------------------------
// DVFS 频率表
// ---------------------------------------------------------------------------

/// voltage-states blob 是 (freqHz, voltage) 的 UInt32 对；取出 MHz 列表。
static CFArrayRef parse_voltage_states(CFTypeRef blob)
{
    if (!blob || CFGetTypeID(blob) != CFDataGetTypeID()) return NULL;

    CFDataRef data = (CFDataRef)blob;
    CFIndex bytes = CFDataGetLength(data);
    if (bytes < 8) return NULL;

    const uint8_t *raw = CFDataGetBytePtr(data);
    CFIndex pairs = bytes / 8;
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, pairs, &kCFTypeArrayCallBacks);
    if (!out) return NULL;

    for (CFIndex i = 0; i < pairs; i++) {
        uint32_t freqHz = 0;
        memcpy(&freqHz, raw + i * 8, sizeof(freqHz));
        if (freqHz == 0) continue;                     // 0 是填充
        int mhz = (int)(freqHz / 1000000u);
        CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &mhz);
        if (n) {
            CFArrayAppendValue(out, n);
            CFRelease(n);
        }
    }
    return out;
}

/// 在设备树里找第一个含 "voltage-states" 的属性。iOS 上这个表不在
/// AppleARMIODevice 下（macOS 才在），只能整棵树扫。
static CFArrayRef search_device_tree_for_voltage_states(void)
{
    if (!pIORegistryCreateIterator || !pIOIteratorNext || !pIOObjectRelease ||
        !pIORegistryEntryCreateCFProperties) {
        return NULL;
    }

    io_iterator_t iter = 0;
    if (pIORegistryCreateIterator(0, "IODeviceTree", 1, &iter) != 0 || !iter) {
        return NULL;
    }

    CFArrayRef result = NULL;
    io_object_t entry = 0;
    int visited = 0;

    while ((entry = pIOIteratorNext(iter))) {
        visited++;
        if (visited > 4000) { pIOObjectRelease(entry); break; }

        CFMutableDictionaryRef props = NULL;
        if (pIORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == 0 && props) {
            CFIndex n = CFDictionaryGetCount(props);
            if (n > 0) {
                const void **keys = (const void **)malloc(sizeof(void *) * (size_t)n);
                const void **vals = (const void **)malloc(sizeof(void *) * (size_t)n);
                if (keys && vals) {
                    CFDictionaryGetKeysAndValues(props, keys, vals);
                    for (CFIndex i = 0; i < n; i++) {
                        CFTypeRef k = keys[i];
                        if (!k || CFGetTypeID(k) != CFStringGetTypeID()) continue;
                        if (CFStringFind((CFStringRef)k, CFSTR("voltage-states"), 0).location == kCFNotFound) continue;

                        CFArrayRef parsed = parse_voltage_states(vals[i]);
                        if (parsed && !result) {
                            result = parsed;   // 接管所有权
                        } else if (parsed) {
                            CFRelease(parsed);
                        }
                    }
                }
                if (keys) free(keys);
                if (vals) free(vals);
            }
            CFRelease(props);
        }
        pIOObjectRelease(entry);
        if (result) break;
    }
    pIOObjectRelease(iter);
    return result;
}

/// 先试 AppleARMIODevice 上的标准键（macOS 形状），再扫设备树。
static CFArrayRef copy_frequencies_for_keys(CFArrayRef keys)
{
    if (pIOServiceMatching && pIOServiceGetMatchingServices && pIOIteratorNext &&
        pIOObjectRelease && pIORegistryEntryCreateCFProperty) {
        CFIndex kn = CFArrayGetCount(keys);
        for (CFIndex i = 0; i < kn; i++) {
            CFStringRef key = (CFStringRef)CFArrayGetValueAtIndex(keys, i);
            CFMutableDictionaryRef match = pIOServiceMatching("AppleARMIODevice");
            if (!match) break;
            io_iterator_t iter = 0;
            if (pIOServiceGetMatchingServices(0, match, &iter) != 0 || !iter) continue;

            io_object_t entry = pIOIteratorNext(iter);
            pIOObjectRelease(iter);
            if (!entry) continue;

            CFTypeRef blob = pIORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
            pIOObjectRelease(entry);
            CFArrayRef freqs = parse_voltage_states(blob);
            if (blob) CFRelease(blob);
            if (freqs) return freqs;
        }
    }
    return search_device_tree_for_voltage_states();
}

static BOOL gFreqTablesTried = NO;
static CFArrayRef gPFreqs = NULL;
static CFArrayRef gEFreqs = NULL;

static void ensure_freq_tables(void)
{
    if (gFreqTablesTried) return;
    gFreqTablesTried = YES;

    // macOS 实测：1-sram = E 簇，5-sram = P 簇。iOS 的键名未逐一验证，
    // 所以整族都试一遍，最后再靠设备树扫描兜底。
    const void *pKeys[] = { CFSTR("voltage-states5-sram"), CFSTR("voltage-states5"),
                            CFSTR("voltage-states2-sram"), CFSTR("voltage-states1-sram") };
    CFArrayRef pArr = CFArrayCreate(kCFAllocatorDefault, pKeys, 4, &kCFTypeArrayCallBacks);
    if (pArr) {
        gPFreqs = copy_frequencies_for_keys(pArr);
        CFRelease(pArr);
    }

    const void *eKeys[] = { CFSTR("voltage-states1-sram"), CFSTR("voltage-states1"),
                            CFSTR("voltage-states0-sram") };
    CFArrayRef eArr = CFArrayCreate(kCFAllocatorDefault, eKeys, 3, &kCFTypeArrayCallBacks);
    if (eArr) {
        gEFreqs = copy_frequencies_for_keys(eArr);
        CFRelease(eArr);
    }
}

// ---------------------------------------------------------------------------
// 订阅
// ---------------------------------------------------------------------------

static BOOL gSubscriptionTried = NO;
static BOOL gSubscriptionOK = NO;
static IORepSubRef gSubscription = NULL;
static CFMutableDictionaryRef gSubscribedChannels = NULL;

static BOOL try_subscribe(CFStringRef group, CFStringRef subgroup,
                          IORepSubRef *subOut, CFMutableDictionaryRef *channelsOut)
{
    if (!pCopyChannelsInGroup || !pCreateSubscription) return NO;

    CFMutableDictionaryRef channels = pCopyChannelsInGroup(group, subgroup, 0, 0, 0);
    if (!channels) return NO;
    if (channel_count_of(channels) == 0) {   // group 不存在时也返回字典，但通道为空
        CFRelease(channels);
        return NO;
    }

    CFMutableDictionaryRef subbed = NULL;
    IORepSubRef sub = pCreateSubscription(NULL, channels, &subbed, 0, NULL);
    if (!sub) {
        CFRelease(channels);
        if (subbed) CFRelease(subbed);
        return NO;
    }

    CFMutableDictionaryRef target = subbed ? subbed : channels;
    if (target != channels) CFRelease(channels);

    *subOut = sub;
    *channelsOut = target;
    return YES;
}

static BOOL ensure_subscription(void)
{
    if (gSubscriptionTried) return gSubscriptionOK;
    gSubscriptionTried = YES;

    CFStringRef group = CFSTR("CPU Stats");
    CFStringRef candidates[] = {
        CFSTR("CPU Complex Performance States"),
        CFSTR("CPU Core Performance States"),
        NULL,
    };
    for (int i = 0; candidates[i] != NULL; i++) {
        IORepSubRef sub = NULL;
        CFMutableDictionaryRef channels = NULL;
        if (try_subscribe(group, candidates[i], &sub, &channels)) {
            gSubscription = sub;
            gSubscribedChannels = channels;
            gSubscriptionOK = YES;
            return YES;
        }
    }
    // 整个 group（不筛 subgroup）再试一次。
    IORepSubRef sub = NULL;
    CFMutableDictionaryRef channels = NULL;
    if (try_subscribe(group, NULL, &sub, &channels)) {
        gSubscription = sub;
        gSubscribedChannels = channels;
        gSubscriptionOK = YES;
        return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// 采样
// ---------------------------------------------------------------------------

/// 一个通道的加权平均 MHz。全 IDLE 或无可用驻留时返回 0。
static double weighted_mhz_for_channel(CFDictionaryRef metric, CFArrayRef dvfs)
{
    if (!dvfs || CFArrayGetCount(dvfs) == 0) return 0;

    int states = pStateGetCount(metric);
    if (states <= 1) return 0;

    CFIndex freqCount = CFArrayGetCount(dvfs);
    double weighted = 0.0;
    double total = 0.0;

    for (int i = 1; i < states; i++) {          // state 0 是 IDLE
        int64_t residency = pStateGetResidency(metric, i);
        if (residency <= 0) continue;

        CFIndex freqIndex = (CFIndex)(i - 1);
        if (freqIndex >= freqCount) freqIndex = freqCount - 1;
        int mhz = 0;
        CFNumberGetValue((CFNumberRef)CFArrayGetValueAtIndex(dvfs, freqIndex),
                         kCFNumberIntType, &mhz);

        weighted += (double)residency * (double)mhz;
        total += (double)residency;
    }
    return total > 0 ? weighted / total : 0;
}

/// 通道名里含 "PCPU"（或以 P 开头）= 性能簇；含 "ECPU"（或以 E 开头）= 能效簇。
static BOOL name_is_performance(CFStringRef name)
{
    if (!name) return NO;
    if (CFStringFind(name, CFSTR("PCPU"), 0).location != kCFNotFound) return YES;
    return CFStringGetLength(name) > 0 &&
           CFStringGetCharacterAtIndex(name, 0) == 'P';
}

static BOOL name_is_efficiency(CFStringRef name)
{
    if (!name) return NO;
    if (CFStringFind(name, CFSTR("ECPU"), 0).location != kCFNotFound) return YES;
    return CFStringGetLength(name) > 0 &&
           CFStringGetCharacterAtIndex(name, 0) == 'E';
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

uint64_t sysprobe_real_cpu_frequency_mhz(void)
{
    uint64_t result = 0;

    // **刻意不检查 getuid。** IOReport 的访问门槛是沙箱的 IOKit user client 例外
    // （`IOReportUserClient`，见 entitlements），**不是 uid** —— SysProbe 的主 App 与
    // 负一屏都以 mobile 身份运行，一样能订阅。
    //
    // 0.0.34 第一版在这里写了 `if (getuid() != 0) return 0;`（从「powermetrics 要 root」
    // 想当然抄来的），结果主 App 与负一屏永远拿到 0、频率那一格只显示「—」——
    // 而占用率是 host_processor_info 采的、不受影响，症状正好是「只有占用没有频率」。
    if (!ensure_symbols()) return 0;
    if (!ensure_subscription()) return 0;

    ensure_freq_tables();
    if (!gPFreqs && !gEFreqs) return 0;       // 没有档位表，驻留没有意义

    CFDictionaryRef s1 = pCreateSamples(gSubscription, gSubscribedChannels, NULL);
    if (!s1) return 0;

    // 两次采样隔 100 ms —— 有这段时间，DVFS 驻留计数器才有东西可差分。
    struct timespec ts = { 0, 100 * 1000 * 1000 };
    nanosleep(&ts, NULL);

    CFDictionaryRef s2 = pCreateSamples(gSubscription, gSubscribedChannels, NULL);
    if (!s2) { CFRelease(s1); return 0; }

    CFDictionaryRef delta = pCreateSamplesDelta(s1, s2, NULL);
    if (delta) {
        CFArrayRef channels = channel_array_of(delta);
        double pMHz = 0.0;
        double eMHz = 0.0;

        if (channels) {
            CFIndex n = CFArrayGetCount(channels);
            for (CFIndex i = 0; i < n; i++) {
                CFDictionaryRef metric = (CFDictionaryRef)CFArrayGetValueAtIndex(channels, i);
                if (!metric || CFGetTypeID(metric) != CFDictionaryGetTypeID()) continue;

                CFStringRef name = pChannelGetChannelName(metric);
                if (name_is_performance(name)) {
                    double m = weighted_mhz_for_channel(metric, gPFreqs);
                    if (m > pMHz) pMHz = m;
                } else if (name_is_efficiency(name)) {
                    double m = weighted_mhz_for_channel(metric, gEFreqs);
                    if (m > eMHz) eMHz = m;
                }
            }
        }

        // 优先性能簇；P 簇全空闲时用 E 簇兜底。
        double chosen = pMHz > 0 ? pMHz : eMHz;
        if (chosen > 0) result = (uint64_t)(chosen + 0.5);
        CFRelease(delta);
    }
    CFRelease(s2);
    CFRelease(s1);

    return result;
}

#else  /* 模拟器 / 非 arm64：IOReport 这条链没有意义 */

uint64_t sysprobe_real_cpu_frequency_mhz(void)
{
    return 0;
}

#endif
