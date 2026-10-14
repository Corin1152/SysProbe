//
//  BandRefreshDaemon.m
//  SysProbe
//
//  「信号弱到某个程度就自动刷新蜂窝信号」的**后台**执行体。
//
//  ══════════════════════════════════════════════════════════════════════════
//  为什么要有它
//  ══════════════════════════════════════════════════════════════════════════
//
//  `BandAutoRefreshController`（App 内那条路）靠 Swift 定时器轮询，而 App 的
//  `Info.plist` **没有 `UIBackgroundModes`** —— 退后台即被挂起，定时器随之停摆。
//  用户要的是「切到后台也继续」，那只能是一个**独立进程**。
//
//  它与 `ChargeLimiterDaemon` 同一个套路：由 App 用 `sysprobe_spawn_root_daemon`
//  以 root（persona 99 / uid 0）spawn 出来，自己带一个 `main()` 与无限循环。
//  App 被划掉之后它照跑 —— 它不依赖父进程活着。
//
//  ══════════════════════════════════════════════════════════════════════════
//  为什么放在 Tools/ 而不是 Sources/
//  ══════════════════════════════════════════════════════════════════════════
//
//  它有 `main()`。被 project.yml 的 sources 收进去就会和 App 的 `main` 撞符号、
//  链接直接失败 —— 与 `Tools/RootTool.c` 完全同一个理由。放在 Sources/ 之外是
//  **结构性**保证，不靠一条随时可能被删掉的 `excludes`。
//
//  它不在 Xcode 里编译：由 `scripts/build-ipa.sh` 用一条 clang 命令直编出来
//  （见脚本里 BandRefreshDaemon 那一段），并被 `ldid -S` 签上
//  `Support/SysProbe.entitlements` —— **必须是主 App 那一份**，而不是
//  `SysProbeRootTool.entitlements`：前者才有 `com.apple.CommCenter.fine-grained`，
//  而读 RSRP 与刷 modem 走的就是 CommCenter 的 XPC / C API。
//
//  ══════════════════════════════════════════════════════════════════════════
//  与 App 之间怎么通信
//  ══════════════════════════════════════════════════════════════════════════
//
//  两个 plist，方向固定，理由在下面：
//
//    配置  /var/mobile/Library/Preferences/com.corin.sysprobe.bandrefresh.plist
//          App 写、本进程读。
//    状态  /var/mobile/Library/Caches/sysprobe-bandrefresh-state.plist
//          本进程写、App 读。
//
//  单向是刻意的。两边都是 uid 0 / uid 501 的两个进程，谁创建的文件对方不一定能改
//  （root 建的 0644 文件 mobile 写不了），双向写迟早撞上「配置写不进去」这种
//  极难排查的静默失败。切成单向之后这个问题不存在。
//
//  改参数不用重启进程：每轮开头重新读一次配置文件 —— 与 App 内那条路
//  （`BandAutoRefreshConfig.load()` 每拍重读）同一个取向。
//
//  ══════════════════════════════════════════════════════════════════════════
//  怎么停
//  ══════════════════════════════════════════════════════════════════════════
//
//  忽略 SIGHUP / SIGTERM（与 ChargeLimiterDaemon 一致），所以**不能靠信号停**。
//  停的办法只有一种：App 把配置里的 `enabled` 写成 NO，本进程下一轮读到就退出。
//  这样也不需要一个「kill 守护进程」的 root 子命令 —— 少一条能改坏系统的路径。
//
//  ══════════════════════════════════════════════════════════════════════════
//  判定逻辑
//  ══════════════════════════════════════════════════════════════════════════
//
//  与 `BandAutoRefreshController.tick()` **逐条对齐**：方向、阈值、持续、冷却、
//  干跑，以及「rsrp < 0 才算有效读数」那条哨兵判据。改一边就要改另一边，否则
//  前后台表现不一致，而那正是最难对出来的现象。
//

#import <Foundation/Foundation.h>
#import <errno.h>
#import <signal.h>
#import <stdio.h>
#import <unistd.h>
// `dispatch_once` 建时间格式器时要用到。Foundation 会间接带进来，但这一路
//  clang 编译不加 `-framework Foundation` 之外的任何东西，显式写清楚更稳。
#import <dispatch/dispatch.h>

#import "CommCenterBridge.h"

// ── 路径 ────────────────────────────────────────────────────────────────────

/// 配置。App 写、本进程读。
static NSString *const kConfigPath =
    @"/var/mobile/Library/Preferences/com.corin.sysprobe.bandrefresh.plist";

/// 状态与日志。本进程写、App 读。
static NSString *const kStatePath =
    @"/var/mobile/Library/Caches/sysprobe-bandrefresh-state.plist";

/// 日志最多留多少条。与 App 内那条路的 30 条一致。
static const NSUInteger kMaxLogLines = 30;

/// 心跳的有效期：超过这个秒数没更新，App 侧就认为本进程已经不在了。
///
/// 取「采样间隔 × 4 + 10」而非常数：间隔被用户调大之后，常数会误判成「守护进程死了」，
/// 于是每 10 秒 spawn 一个，而它们又会因为下面那条单实例检查立刻退出 —— 表现是
/// 「界面一直显示启动中」但什么都不发生。
static NSTimeInterval heartbeatValidity(NSTimeInterval interval) {
    return interval * 4.0 + 10.0;
}

// ── 配置 ────────────────────────────────────────────────────────────────────

/// 一轮的配置。字段与 `BandAutoRefreshConfig` 一一对应。
typedef struct {
    BOOL enabled;
    BOOL dryRun;
    int thresholdDbm;
    int slot;
    NSTimeInterval dwellSec;
    NSTimeInterval cooldownSec;
    NSTimeInterval sampleIntervalSec;
    /// 连着 Wi-Fi 时暂停。**默认 YES** —— 与 App 侧同一个默认值，
    /// 见 `BandAutoRefreshConfig.pauseOnWiFi` 的说明。
    BOOL pauseOnWiFi;
} BandRefreshConfig;

/// 读配置文件。**读不到或任何一项缺失就返回 enabled = NO** ——
///
/// 「配置文件不存在」和「用户关掉了」对守护进程来说是同一件事：都不该动手。
/// 逐项取默认值而不是整份拒绝，是为了让「App 写了一部分键」这种情况也能跑起来，
/// 用不上那部分的默认值兜住。
static BandRefreshConfig readConfig(void) {
    BandRefreshConfig c;
    c.enabled = NO;
    c.dryRun = YES;
    c.thresholdDbm = -100;
    c.slot = 1;
    c.dwellSec = 20;
    c.cooldownSec = 300;
    c.sampleIntervalSec = 2;
    c.pauseOnWiFi = YES;

    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (![raw isKindOfClass:[NSDictionary class]]) {
        return c;
    }

    id v;
    if ((v = raw[@"enabled"])) c.enabled = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
    if ((v = raw[@"dryRun"])) c.dryRun = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;
    if ((v = raw[@"thresholdDbm"])) c.thresholdDbm = [v respondsToSelector:@selector(intValue)] ? [v intValue] : -100;
    if ((v = raw[@"slot"])) {
        int s = [v respondsToSelector:@selector(intValue)] ? [v intValue] : 1;
        // slot 与 App 侧同一个取值域：1 是第一张卡，读不到时 `preferredSlot()` 也返回 1。
        if (s >= 1 && s <= 3) { c.slot = s; }
    }
    if ((v = raw[@"dwellSec"])) c.dwellSec = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 20;
    if ((v = raw[@"cooldownSec"])) c.cooldownSec = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 300;
    if ((v = raw[@"sampleIntervalSec"])) c.sampleIntervalSec = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 2;
    if ((v = raw[@"pauseOnWiFi"])) c.pauseOnWiFi = [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;

    // 采样间隔是本循环的周期，不能太小（忙等）也不能是 0。上下界与 App 侧一致。
    if (c.sampleIntervalSec < 0.5) { c.sampleIntervalSec = 0.5; }
    if (c.sampleIntervalSec > 60) { c.sampleIntervalSec = 60; }
    if (c.dwellSec < 0) { c.dwellSec = 0; }
    if (c.cooldownSec < 0) { c.cooldownSec = 0; }

    return c;
}

/// 当前值是否满足条件：RSRP **低于**阈值（严格小于，等于不算）。
///
/// **RSRP 必须 < 0 才参与判断**：0 是「没读到」的哨兵（见 `CommCenterBridge.m`），
/// 少了这一句它会变成「信号极好」，判定整个反过来 —— 而这个进程没有界面，
/// 反了也看不出来。
///
/// 与 App 侧 `BandAutoRefreshConfig.matches(_:)` 是同一份逻辑（2026-10-14 起
/// 只剩「低于」一个方向），改这里时改那边。
static BOOL matches(int rsrp, BandRefreshConfig c) {
    if (rsrp >= 0) { return NO; }
    return rsrp < c.thresholdDbm;
}

// ── 状态 ────────────────────────────────────────────────────────────────────

/// 最近一次读到的 RSRP。读不到是 nil —— 不写成 0，那会与哨兵冲突。
static NSNumber *gLastRsrp = nil;
/// 已持续满足条件的起点时间戳（Unix）。0 = 没有在计时。
static NSTimeInterval gArmedSince = 0;
/// 冷却到什么时候（Unix）。0 = 没在冷却。
static NSTimeInterval gCooldownUntil = 0;
static NSDate *gLastRefreshAt = nil;
static NSMutableArray<NSString *> *gLog = nil;
/// 最近一轮里 Wi-Fi 是不是连着。写进状态文件供 App 显示。
static BOOL gWifiConnected = NO;
/// 上一轮是不是处于「连 Wi-Fi 暂停」—— 只为了在**切换**那一刻写一条日志。
static BOOL gPausedForWiFi = NO;

static NSDateFormatter *timeFormatter(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"HH:mm:ss";
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return f;
}

static void appendLog(NSString *line) {
    if (gLog == nil) {
        gLog = [NSMutableArray array];
    }
    NSString *stamp = [timeFormatter() stringFromDate:[NSDate date]];
    [gLog insertObject:[NSString stringWithFormat:@"%@ %@", stamp, line] atIndex:0];
    if (gLog.count > kMaxLogLines) {
        [gLog removeObjectsInRange:NSMakeRange(kMaxLogLines, gLog.count - kMaxLogLines)];
    }
}

/// 把这一轮的状态落盘。App 靠这个文件显示「守护进程活着吗 / 现在什么状态 / 做了什么」。
///
/// `heartbeat` 是给 App 侧看门狗用的唯一判据：它不查进程表（拿不到 pid 时无从下手），
/// 只看这个时间戳新不新鲜 —— 与 `sysprobe_local_port_open` 对充电守护进程的作用
/// 是同一件事，只是这里没有端口可探。
static void writeState(NSString *phase,
                       NSTimeInterval remaining,
                       NSTimeInterval interval) {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"pid"] = @(getpid());
    s[@"heartbeat"] = @([[NSDate date] timeIntervalSince1970]);
    s[@"heartbeatValidity"] = @(heartbeatValidity(interval));
    s[@"phase"] = phase ?: @"idle";
    s[@"remaining"] = @(remaining);
    // Wi-Fi 状态由本进程判定（与 App 侧同一个 `sysprobe_wifi_connected()`）。
    // 回传给 App 是为了「后台模式」下界面也能显示真实状态 —— 那时 App 内那条
    // 定时器是停着的，它自己不会去查。
    s[@"wifi"] = @(gWifiConnected);
    if (gLastRsrp != nil) { s[@"lastRsrp"] = gLastRsrp; }
    if (gLastRefreshAt != nil) {
        s[@"lastRefreshAt"] = @([gLastRefreshAt timeIntervalSince1970]);
    }
    if (gLog.count > 0) { s[@"log"] = gLog; }

    // 原子写：先写临时文件再 rename。App 侧可能正好在读，写一半的 plist 会让它
    // 读到 nil —— 那会被解释成「守护进程不在了」，于是又 spawn 一个。
    NSString *tmp = [kStatePath stringByAppendingString:@".tmp"];
    if ([s writeToFile:tmp atomically:YES]) {
        rename(tmp.fileSystemRepresentation, kStatePath.fileSystemRepresentation);
    }
}

/// 单实例检查。
///
/// 看门狗每 10 秒可能再拉一个（比如它误判本进程已死），而本进程**忽略 SIGTERM**，
/// 谁都杀不掉谁 —— 两个实例同时判定就会刷两次。所以启动前先看一眼：上一份状态的
/// 心跳还新鲜、且那个 pid 还活着，就说明已经有一个在跑了，自己立刻退出。
///
/// 进程存活用 `kill(pid, 0)`：本进程是 root，对任何进程发 0 信号都只是查询。
static BOOL anotherInstanceAlive(NSTimeInterval *outInterval) {
    NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if (![s isKindOfClass:[NSDictionary class]]) { return NO; }

    id pidObj = s[@"pid"];
    id beatObj = s[@"heartbeat"];
    if (![pidObj respondsToSelector:@selector(intValue)] ||
        ![beatObj respondsToSelector:@selector(doubleValue)]) {
        return NO;
    }

    pid_t pid = (pid_t)[pidObj intValue];
    if (pid <= 0 || pid == getpid()) { return NO; }
    if (kill(pid, 0) != 0) { return NO; }   // 进程已经不在了 —— 陈旧的状态文件

    NSTimeInterval beat = [beatObj doubleValue];
    id validityObj = s[@"heartbeatValidity"];
    NSTimeInterval validity = [validityObj respondsToSelector:@selector(doubleValue)]
        ? [validityObj doubleValue]
        : 90.0;
    if (outInterval != NULL) { *outInterval = validity; }

    return ([[NSDate date] timeIntervalSince1970] - beat) < validity;
}

// ── 主循环 ──────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;

        // 与 ChargeLimiterDaemon 同一个取舍：父进程（App）被划掉时不该把自己带走。
        // 代价是**没有信号能停它** —— 停它只能靠配置文件里的 enabled = NO。
        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        signal(SIGPIPE, SIG_IGN);

        NSTimeInterval knownInterval = 2;
        if (anotherInstanceAlive(&knownInterval)) {
            // 已经有一个在跑了。什么都不做、也不改它的状态文件 ——
            // 改了会把它的心跳覆盖成自己的，反而让 App 看错。
            return 0;
        }

        NSTimeInterval interval = 2;

        for (;;) {
            @autoreleasepool {
                BandRefreshConfig c = readConfig();
                interval = c.sampleIntervalSec;

                // ── 唯一的停止条件 ──
                if (!c.enabled) {
                    writeState(@"stopped", 0, interval);
                    return 0;
                }

                NSDictionary *sig = sysprobe_signal_sync(c.slot);
                id rsrpObj = [sig isKindOfClass:[NSDictionary class]] ? sig[@"rsrp"] : nil;
                int rsrp = [rsrpObj respondsToSelector:@selector(intValue)] ? [rsrpObj intValue] : 0;
                gLastRsrp = (rsrp < 0) ? @(rsrp) : nil;

                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

                // ── 前置开关：连着 Wi-Fi 就暂停 ──
                //
                // 与 App 内那条路（`BandAutoRefreshController.tick`）逐条对齐：
                // 位置在读数之后、冷却与阈值之前（暂停时状态要显示成 paused，
                // 而不是一条更早的冷却倒计时），暂停时把已计的时长清零
                // （否则 Wi-Fi 一断就会拿一段与蜂窝无关的时间去凑 dwell）。
                //
                // 暂停的是「计时与动手」，不是读数：RSRP 照采，状态照写 ——
                // 心跳是 App 判活的唯一依据，少写一轮 App 会以为进程死了。
                gWifiConnected = sysprobe_wifi_connected();
                BOOL pausedForWiFi = (c.pauseOnWiFi && gWifiConnected);
                if (pausedForWiFi != gPausedForWiFi) {
                    gPausedForWiFi = pausedForWiFi;
                    appendLog(pausedForWiFi
                              ? @"paused · Wi-Fi connected"
                              : @"resumed · Wi-Fi disconnected");
                }
                if (pausedForWiFi) {
                    gArmedSince = 0;
                    writeState(@"paused", 0, interval);
                    sleep((unsigned int)interval);
                    continue;
                }

                // 读不到就跳过这一拍，但**状态照写** —— 心跳是 App 判活的唯一依据，
                // 少了它 App 会以为进程死了并再拉一个。
                if (rsrp >= 0) {
                    writeState(@"idle", 0, interval);
                    sleep((unsigned int)interval);
                    continue;
                }

                if (gCooldownUntil > 0 && now < gCooldownUntil) {
                    writeState(@"cooling", gCooldownUntil - now, interval);
                    sleep((unsigned int)interval);
                    continue;
                }
                gCooldownUntil = 0;

                if (!matches(rsrp, c)) {
                    gArmedSince = 0;
                    writeState(@"idle", 0, interval);
                    sleep((unsigned int)interval);
                    continue;
                }

                if (gArmedSince <= 0) { gArmedSince = now; }
                NSTimeInterval elapsed = now - gArmedSince;

                if (elapsed < c.dwellSec) {
                    writeState(@"armed", c.dwellSec - elapsed, interval);
                    sleep((unsigned int)interval);
                    continue;
                }

                // ── 到点，动手 ──
                gArmedSince = 0;
                gCooldownUntil = now + c.cooldownSec;
                gLastRefreshAt = [NSDate date];

                if (c.dryRun) {
                    appendLog([NSString stringWithFormat:@"dry-run %d dBm → would refresh", rsrp]);
                } else {
                    BOOL ok = sysprobe_refresh_modem();
                    // `sysprobe_refresh_modem` 返回 YES 只代表「调用发出去了」：
                    // 无权限时 CommCenter 静默丢弃请求，不报错也不抛异常。
                    appendLog(ok
                              ? [NSString stringWithFormat:@"refreshed at %d dBm", rsrp]
                              : [NSString stringWithFormat:@"refresh failed at %d dBm", rsrp]);
                }
                writeState(@"cooling", c.cooldownSec, interval);
            }

            sleep((unsigned int)interval);
        }
    }
}
