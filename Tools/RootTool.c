//
//  RootTool.c
//  SysProbe
//
//  SysProbeRootTool —— 一个**裸可执行文件**，由主 App 用 posix_spawn 以 root 身份
//  拉起（见 `ChargeSpawn.c` 的 `sysprobe_spawn_root_tool`）。子命令：
//
//      check              自检：确认自己真的是以 root 跑起来的
//      reboot             重启设备
//      respring           注销（只重启界面层，不重启设备）
//      restart-commcenter 重启蜂窝网络服务
//      thermal-status     读「温控守护进程是否被禁用」的配置
//      thermal-disable    把 com.apple.thermalmonitord 写进 disabled.plist
//      thermal-enable     把那个键删掉
//      clean-scan         存储清理：扫描各目录与应用容器的缓存大小，写 JSON 报告
//      clean-run          存储清理：按范围清空对应目录的内容，写 JSON 报告
//
//  ── 为什么是独立二进制，而不是把这几行写进 App ──────────────────────────
//
//  这几个动作都要求 uid 0，而 App 自己是 mobile。SysProbe 已经有「以 root 拉起
//  包内二进制」的完整链路 —— 充电守护进程走的就是它（`ChargeSpawn.c` 里的
//  persona 99 / uid 0 / gid 0 那一套，已在真机上验证过）。这里不再造第二套。
//
//  「关温控」那一组还额外要求**脱离沙箱**：`/var/db/com.apple.xpc.launchd/` 是
//  launchd 自己的配置目录，普通 App 的沙箱里没有写它的权限，即使 uid 是 0。
//  本工具已经有 `com.apple.private.security.no-sandbox`（见
//  `Support/SysProbeRootTool.entitlements`），所以不需要再加权限。
//
//  ── 为什么源码放在 Tools/ 而不是 Sources/ ───────────────────────────────
//
//  它有**自己的 `main()`**。XcodeGen 会把 sources 下的 .c 全部编进 target，一旦它
//  被当成 App 的源文件，链接期就会出现重复的 `_main` 而直接失败。
//  放在 `Sources/` 之外是**结构性**保证；靠 `project.yml` 里一条 `excludes` 也能达到
//  同样效果，但那条配置将来被人删掉时不会有任何提示，而这里会。
//
//  ── 与 RebootTools 1.2.1 的关系 ────────────────────────────────────────
//
//  两个动作的做法参考了 RebootTools（作者 dongchenshuo，致谢肖博 vlog）的公开实现，
//  但代码是重写的：RebootTools 的 tipa 里**没有 LICENSE**，默认「保留所有权利」，
//  而本仓库是公开的 Apache-2.0，直接搬运它的二进制会有版权问题。
//
//  两个在真机上验证过的取值原样保留，**不要「顺手改正」**：
//
//    · `reboot()` 的实参是 `0`，不是 `<sys/reboot.h>` 里的 `RB_AUTOBOOT`（0x100）；
//    · 注销用的信号是 `SIGHUP`，不是 `SIGKILL` —— SpringBoard 收到 HUP 才会走
//      「重启界面层」那条路；KILL 会落进「崩溃恢复」，表现不一样。
//
//  它需要的 entitlements 见 `Support/SysProbeRootTool.entitlements`。
//

#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

// 关温控那一组要读/改 launchd 的 disabled.plist。
//
// 用 CoreFoundation 而不是手写 plist 解析：那份文件在真机上是**二进制 plist**
// （`bplist00`），而且里面除我们关心的那个键之外还有别的条目 —— 必须原样保留。
// CFPropertyList 是唯一能「按原格式读进来、改一个键、再按原格式写回去」的现成手段。
// 链接需要 `-framework CoreFoundation`，见 `scripts/build-ipa.sh`。
#include <CoreFoundation/CoreFoundation.h>
// `open` / `O_*`（备份用的逐字节复制）。
#include <fcntl.h>
// `mkdir` / `chmod`。
#include <sys/stat.h>

// `reboot(2)` 在公开 SDK 的 `<unistd.h>` 里有原型，但在 `_POSIX_C_SOURCE` 下会被
// 隐藏掉。自己补一行同型声明 —— 重复声明只要签名一致就是合法的 C，而少了它在某些
// 编译配置下会退化成 implicit declaration（C99 起是错误）。
extern int reboot(int howto);

/// `reboot(2)` 的实参。
///
/// RebootTools 1.2.1 在真机上跑通的就是 `0`。`<sys/reboot.h>` 里的 `RB_AUTOBOOT`
/// 是 `0x100`，看着更「正确」，但它不是这里验证过的取值 —— 别换。
#define SYSPROBE_REBOOT_HOWTO 0

/// SpringBoard 的进程名。注销靠给它发信号实现。
#define SYSPROBE_SPRINGBOARD "SpringBoard"

/// CommCenter 的进程名。「重启蜂窝网络服务」靠杀它实现。
#define SYSPROBE_COMMCENTER "CommCenter"

/// 注销用的信号。见文件头：`SIGHUP` 才是「重启界面层」。
#define SYSPROBE_RESPRING_SIGNAL SIGHUP

// ── 退出码 ─────────────────────────────────────────────────────────────────
//
// `check` 的退出码是**给 App 看的**（`sysprobe_spawn_root_tool_sync` 会把它带回去），
// 所以 `SYSPROBE_EXIT_NOT_ROOT` 不能和 0 混淆。
enum {
    SYSPROBE_EXIT_OK = 0,
    SYSPROBE_EXIT_USAGE = 2,
    /// 跑起来了，但不是 root —— 也就是 persona 那一步没生效。
    SYSPROBE_EXIT_NOT_ROOT = 3,
    /// 动作本身失败（`reboot` 返回了，或没找到 / 杀不掉 SpringBoard）。
    SYSPROBE_EXIT_FAILED = 4,
    /// `thermal-status` 专用：读到了，配置是**未禁用**（键不在，或不是 true）。
    ///
    /// 为什么不复用 0 / 4：这两个值在这条链路上已经有含义（0 = 已禁用、4 = 读失败），
    /// 「未禁用」是第三种正常状态，必须能和它们区分开 —— 否则界面分不清
    /// 「没开」和「读不出来」，而这两种情况下该显示的东西完全不同。
    SYSPROBE_EXIT_THERMAL_ENABLED = 5,
};

/// 自检：确认这个进程真的是 uid 0。
///
/// 存在的理由是**它是唯一能提前暴露静默失败的途径**。persona 那一步依赖
/// `com.apple.private.persona-mgmt`（见 `Support/SysProbe.entitlements`），
/// 少了它 `posix_spawn` **照样成功**，只是子进程变成 mobile 身份 —— 于是
/// `reboot(2)` 和 `kill(SpringBoard)` 都会失败，而界面那边收不到任何错误，
/// 用户看到的就是「点了没反应」。App 在设置页打开时跑一次这个子命令，
/// 就能把那种状态明确地显示出来。
static int do_check(void) {
    return (geteuid() == 0) ? SYSPROBE_EXIT_OK : SYSPROBE_EXIT_NOT_ROOT;
}

/// 重启设备。
///
/// 成功的话这个函数**不会返回** —— 内核直接重启。返回了就说明失败了。
static int do_reboot(void) {
    if (reboot(SYSPROBE_REBOOT_HOWTO) != 0) {
        perror("reboot");
        return SYSPROBE_EXIT_FAILED;
    }
    return SYSPROBE_EXIT_OK;
}

/// 按进程名找 pid。找不到返回 -1。
///
/// 走 `sysctl(KERN_PROC_ALL)` 自己遍历，而不是调用系统的 `killall` —— 后者在
/// iOS 上是私有 API，公开 SDK 里没有原型。遍历本身是公开接口。
static pid_t process_pid_by_name(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;

    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
        return -1;
    }

    // 留出余量：两次 `sysctl` 之间进程数只会变多，内核会用 ENOMEM 拒绝一个
    // 恰好装不下的缓冲区。多要 1/8 加 1 KB 足够覆盖这个窗口。
    size += size / 8 + 1024;

    struct kinfo_proc *procs = malloc(size);
    if (procs == NULL) {
        return -1;
    }
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs);
        return -1;
    }

    pid_t found = -1;
    size_t count = size / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < count; i++) {
        // `p_comm` 是 `char[MAXCOMLEN + 1]`（17 字节）。要查的两个名字
        // "SpringBoard"(11) 与 "CommCenter"(10) 都放得下，不会被截断。
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) {
            found = procs[i].kp_proc.p_pid;
            break;
        }
    }

    free(procs);
    return found;
}

/// 注销：重启界面层。
///
/// 只重启 SpringBoard，不动内核。表现是屏幕转圈后回到锁屏 / 主屏 ——
/// **前台 App（包括本 App 自己）会被一起收掉**，那是预期行为，不是崩溃。
static int do_respring(void) {
    pid_t pid = process_pid_by_name(SYSPROBE_SPRINGBOARD);
    if (pid <= 0) {
        fprintf(stderr, "respring: %s is not running\n", SYSPROBE_SPRINGBOARD);
        return SYSPROBE_EXIT_FAILED;
    }
    if (kill(pid, SYSPROBE_RESPRING_SIGNAL) != 0) {
        perror("kill");
        return SYSPROBE_EXIT_FAILED;
    }
    return SYSPROBE_EXIT_OK;
}

/// 重启蜂窝网络服务（CommCenter）。
///
/// 频段设置写错时的**逃生通道**：改完频段若出现「无服务」或网络异常，杀掉
/// CommCenter 会让它重新读一遍配置，多数情况下能回到可用状态。原版 CellularInfo
/// 的工具菜单里就有这一项（`restartCommCenter` → `killall -9 CommCenter`）。
///
/// 用 SIGKILL 而不是 SIGTERM：CommCenter 对 TERM 不一定有响应，而 launchd 在
/// 它退出后会立刻把它拉起来 —— 要的就是这个「硬重启」。
static int do_restart_commcenter(void) {
    pid_t pid = process_pid_by_name(SYSPROBE_COMMCENTER);
    if (pid <= 0) {
        fprintf(stderr, "restart-commcenter: %s is not running\n", SYSPROBE_COMMCENTER);
        return SYSPROBE_EXIT_FAILED;
    }
    if (kill(pid, SIGKILL) != 0) {
        perror("kill");
        return SYSPROBE_EXIT_FAILED;
    }
    return SYSPROBE_EXIT_OK;
}

// ── 关闭温控降频（thermalmonitord）─────────────────────────────────────────
//
//  `thermalmonitord` 是用户态的温控守护进程：它读温度传感器、发布「热压力」等级，
//  系统据此压低 CPU 频率上限、调暗屏幕、限制充电电流。把它的 launchd 启动项禁掉，
//  这些**由热引发的**降频就不会再发生。
//
//  ── 它做不到什么（界面上必须说清楚，这里也记一笔）────────────────────────
//
//  它**不是**「设置频率」。CLPC（A11 起的闭环性能控制器）仍在内核与固件里按功耗、
//  电流、负载自行调频 —— 这个开关只是**抽掉「热」这一个向下的输入**。
//  尤其是**电池老化引起的峰值性能限制**（iOS 的「性能管理」）走的是另一条路，
//  与温度无关，关掉温控对它没有任何作用。
//
//  ── 代价 ──────────────────────────────────────────────────────────────────
//
//  1. **电池健康度会读不出来**，电池在系统里可能显示为「未知部件」——
//     本 App 自己的电池页也在其中；
//  2. **失去过热保护**：持续重载时机身更烫、充电不再被热限制；
//  3. 改动的是系统文件，需要**重启**才生效。
//
//  ── 三条安全约束（改这个文件时不要去掉）──────────────────────────────────
//
//  1. **首次写入前先备份**原文件，且**只备份一次** —— 备份要留的是「用户改动之前」
//     的那一份，后续再开关不能把它覆盖掉；
//  2. **只动这一个键**：读进来 → 改一个键 → 原样写回。绝不能新建一个只含本键的
//     plist —— 那会把 launchd 里**其它已禁用的服务**全部重新打开；
//  3. **原子写**：先写临时文件再 `rename`。直接覆盖写时若中途掉电，会留下一个
//     半截的 plist，launchd 下次开机读不了 —— 那是「所有禁用设置一起失效」级别的后果。

/// launchd 的「已禁用服务」清单。这是 iOS 上禁用守护进程的标准位置。
#define SYSPROBE_DISABLED_PLIST "/var/db/com.apple.xpc.launchd/disabled.plist"

/// 要禁用的服务标签。拼写必须与 launchd 的 job label 完全一致，多一个字符就无效。
#define SYSPROBE_THERMAL_LABEL "com.apple.thermalmonitord"

/// 备份目录与备份文件名。
///
/// 放在 `/var/root/` 下而不是原目录旁边：原目录是 launchd 自己的地盘，
/// 往里放无关文件不合适；而 `/var/root` 已经是本 App 家族的既有落点
/// （充电守护进程的 `aldente.conf` 就在那儿）。
#define SYSPROBE_THERMAL_BACKUP_DIR "/var/root/SysProbe"
#define SYSPROBE_THERMAL_BACKUP SYSPROBE_THERMAL_BACKUP_DIR "/disabled.plist.orig"

/// `disabled.plist` 在不在。
static int thermal_file_exists(void) {
    return access(SYSPROBE_DISABLED_PLIST, F_OK) == 0;
}

/// 把 `disabled.plist` 读成一个**可变**字典。
///
/// 文件不存在时返回 `NULL` 并把 `*error` 置成 `"absent"` —— 调用方据此区分
/// 「文件本来就没有」（合法，等价于「什么都没禁用」）与「读坏了」（真错误）。
/// 成功后 `*formatOut` 是原文件的格式（二进制 / XML），写回时按它来。
///
/// 返回的字典由调用方 `CFRelease`。
static CFMutableDictionaryRef thermal_load(CFPropertyListFormat *formatOut, const char **error) {
    if (!thermal_file_exists()) {
        *error = "absent";
        return NULL;
    }

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)SYSPROBE_DISABLED_PLIST,
        (CFIndex)strlen(SYSPROBE_DISABLED_PLIST),
        false);
    if (url == NULL) {
        *error = "url";
        return NULL;
    }

    CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
    CFRelease(url);
    if (stream == NULL) {
        *error = "open";
        return NULL;
    }
    if (!CFReadStreamOpen(stream)) {
        CFRelease(stream);
        *error = "open";
        return NULL;
    }

    // 默认给二进制：文件存在但解析器没回填格式时（理论上不会），按二进制写回更接近原样。
    CFPropertyListFormat format = kCFPropertyListBinaryFormat_v1_0;
    CFPropertyListRef plist = CFPropertyListCreateWithStream(
        kCFAllocatorDefault,
        stream,
        0,
        // 只要容器可变。叶子节点（CFBoolean / CFString）本来就不可变，也不需要可变。
        kCFPropertyListMutableContainers,
        &format,
        NULL);

    CFReadStreamClose(stream);
    CFRelease(stream);

    if (plist == NULL) {
        *error = "parse";
        return NULL;
    }
    if (CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
        // 真机上它不是字典就说明这个路径上放着别的东西，此时**绝不能**覆盖写。
        CFRelease(plist);
        *error = "not-a-dictionary";
        return NULL;
    }

    if (formatOut != NULL) {
        *formatOut = format;
    }
    return (CFMutableDictionaryRef)plist;
}

/// 原子地把字典写回 `disabled.plist`。
///
/// 先写 `…/disabled.plist.sysprobe.tmp` 再 `rename` 过去。同目录内的 `rename` 是
/// 原子的，所以任何时刻磁盘上的 `disabled.plist` 要么是旧内容、要么是新内容，
/// 不会是半截。
static int thermal_store(CFMutableDictionaryRef dict, CFPropertyListFormat format, const char **error) {
    static const char *tmp = SYSPROBE_DISABLED_PLIST ".sysprobe.tmp";

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)tmp, (CFIndex)strlen(tmp), false);
    if (url == NULL) {
        *error = "url";
        return -1;
    }

    CFWriteStreamRef stream = CFWriteStreamCreateWithFile(kCFAllocatorDefault, url);
    CFRelease(url);
    if (stream == NULL) {
        *error = "open-tmp";
        return -1;
    }
    if (!CFWriteStreamOpen(stream)) {
        CFRelease(stream);
        *error = "open-tmp";
        return -1;
    }

    // 返回写入的字节数，0 表示失败。用 CFIndex 接住，别塞进 Boolean —— 那是窄化转换。
    CFIndex wrote = CFPropertyListWrite(dict, stream, format, 0, NULL);
    CFWriteStreamClose(stream);
    CFRelease(stream);

    if (wrote <= 0) {
        unlink(tmp);
        *error = "write";
        return -1;
    }

    // 临时文件是按 umask 建的，权限偏紧。`disabled.plist` 是系统文件（0644 root:wheel），
    // 权限不对的话 launchd 读不到 —— 而那不会报错，只会表现为「设置不生效」。
    if (chmod(tmp, 0644) != 0) {
        unlink(tmp);
        *error = "chmod";
        return -1;
    }

    // **先落盘，再 rename。**
    //
    // 上面那段注释说「任何时刻磁盘上的 disabled.plist 要么旧内容要么新内容」，
    // 但那只在**数据确实落到盘上**时成立。`CFPropertyListWrite` 写完只进了页缓存，
    // `rename` 又是元数据操作 —— 两者都不保证数据落盘。掉电时完全可能出现
    // 「文件名换过去了、内容是空的」，而这是 launchd 的配置：读不出来它会
    // **把所有已禁用的服务一起恢复**，正好是这个函数想避免的后果。
    //
    // `CFWriteStream` 关掉之后拿不到 fd，只能重新打开一次。用 `fsync` 而不是
    // `F_FULLFSYNC`：后者更彻底也更慢，而这里只在用户拨开关时写一次，
    // 慢一点无所谓，但没必要为它多等一次硬件刷盘。
    int syncFd = open(tmp, O_RDONLY);
    if (syncFd < 0) {
        unlink(tmp);
        *error = "open-sync";
        return -1;
    }
    if (fsync(syncFd) != 0) {
        close(syncFd);
        unlink(tmp);
        *error = "fsync";
        return -1;
    }
    close(syncFd);

    if (rename(tmp, SYSPROBE_DISABLED_PLIST) != 0) {
        unlink(tmp);
        *error = "rename";
        return -1;
    }
    return 0;
}

/// 首次改动前备份原文件。**已经备份过就不再覆盖。**
///
/// 刻意不用 CoreFoundation 写备份，而是逐字节复制：备份要的是「用户改动之前的
/// 原始字节」，经过一次 plist 解析 + 重写就不再是原样了。
static int thermal_backup_once(const char **error) {
    if (access(SYSPROBE_THERMAL_BACKUP, F_OK) == 0) {
        return 0; // 已经有备份了 —— 那才是改动前的状态，不要覆盖。
    }
    if (!thermal_file_exists()) {
        return 0; // 原文件都不存在，没有东西可备份。
    }

    // 已存在时返回 EEXIST，忽略即可。
    (void)mkdir(SYSPROBE_THERMAL_BACKUP_DIR, 0755);

    int source = open(SYSPROBE_DISABLED_PLIST, O_RDONLY);
    if (source < 0) {
        *error = "backup-open-src";
        return -1;
    }

    int destination = open(SYSPROBE_THERMAL_BACKUP, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (destination < 0) {
        close(source);
        *error = "backup-open-dst";
        return -1;
    }

    char buffer[8192];
    ssize_t got;
    while ((got = read(source, buffer, sizeof(buffer))) > 0) {
        ssize_t done = 0;
        while (done < got) {
            // `write` 可以少写，必须循环；把它当一次写完是经典的数据截断 bug。
            ssize_t put = write(destination, buffer + done, (size_t)(got - done));
            if (put <= 0) {
                close(source);
                close(destination);
                *error = "backup-write";
                return -1;
            }
            done += put;
        }
    }
    int readFailed = (got < 0);
    close(source);
    close(destination);

    if (readFailed) {
        *error = "backup-read";
        return -1;
    }
    return 0;
}

/// 读当前配置：`*disabledOut` = 「这个键存在且为真」。
///
/// 文件不存在算**成功**（等价于「什么都没禁用」），不是错误 —— 全新设备上
/// 这个文件可能压根不存在，把它当失败会让开关在干净系统上永远显示「不可用」。
static int thermal_read_disabled(int *disabledOut, const char **error) {
    *disabledOut = 0;

    CFPropertyListFormat format = kCFPropertyListBinaryFormat_v1_0;
    CFMutableDictionaryRef dict = thermal_load(&format, error);
    if (dict == NULL) {
        if (strcmp(*error, "absent") == 0) {
            return 0; // 没有这个文件 = 没有禁用任何服务。
        }
        return -1;
    }

    int disabled = 0;
    CFTypeRef value = CFDictionaryGetValue(dict, CFSTR(SYSPROBE_THERMAL_LABEL));
    if (value != NULL) {
        // 正常写法是 CFBoolean。也认 CFNumber —— 有些工具会写 0/1，
        // 把它误判成「未禁用」会让开关状态和实际不符。
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            disabled = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int number = 0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) {
                disabled = (number != 0);
            }
        }
    }

    CFRelease(dict);
    *disabledOut = disabled;
    return 0;
}

/// `thermal-status`：0 = 已禁用，5 = 未禁用，4 = 读失败。
static int do_thermal_status(void) {
    const char *error = NULL;
    int disabled = 0;
    if (thermal_read_disabled(&disabled, &error) != 0) {
        fprintf(stderr, "thermal-status: cannot read %s (%s)\n", SYSPROBE_DISABLED_PLIST, error);
        return SYSPROBE_EXIT_FAILED;
    }
    return disabled ? SYSPROBE_EXIT_OK : SYSPROBE_EXIT_THERMAL_ENABLED;
}

/// `thermal-disable` / `thermal-enable` 的共同实现。
///
/// 流程：备份（仅禁用方向）→ 读 → 改一个键 → 原子写回 → **回读确认**。
///
/// 回读这一步是必需的：这条链路上「写了但没生效」是完全可能的（权限、
/// 路径被换成别的东西、写到了别的文件），而它不会以任何方式报错。
static int do_thermal_set(int disabled) {
    const char *error = NULL;

    // 「恢复」方向在文件本来就不存在时是个**空操作**，必须提前返回。
    //
    // 不提前的话，下面那条「文件不存在就从空字典起步」的分支会把这个文件**创建**出来 ——
    // 一个空的 plist 功能上等价于不存在，但凭空在 launchd 的配置目录里建一个文件
    // 不是这个开关该做的事，而且会让「关掉」在干净系统上留下痕迹。
    if (!disabled && !thermal_file_exists()) {
        return SYSPROBE_EXIT_OK;
    }

    if (disabled) {
        if (thermal_backup_once(&error) != 0) {
            fprintf(stderr, "thermal-disable: backup failed (%s)\n", error);
            return SYSPROBE_EXIT_FAILED;
        }
    }

    CFPropertyListFormat format = kCFPropertyListBinaryFormat_v1_0;
    CFMutableDictionaryRef dict = thermal_load(&format, &error);
    if (dict == NULL) {
        if (strcmp(error, "absent") != 0) {
            fprintf(stderr, "thermal: cannot read %s (%s)\n", SYSPROBE_DISABLED_PLIST, error);
            return SYSPROBE_EXIT_FAILED;
        }
        // 文件不存在：从空字典起步。写下去就等于「只禁用这一个服务」，
        // 语义是对的 —— 原来确实什么都没禁用。
        dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                         &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
        if (dict == NULL) {
            fprintf(stderr, "thermal: cannot allocate\n");
            return SYSPROBE_EXIT_FAILED;
        }
        format = kCFPropertyListBinaryFormat_v1_0;
    }

    if (disabled) {
        CFDictionarySetValue(dict, CFSTR(SYSPROBE_THERMAL_LABEL), kCFBooleanTrue);
    } else {
        // **删键**而不是置 false：与社区教程的「删掉该键即恢复」一致，
        // 也让「从没开过」和「开过又关了」在文件层面长得一样。
        CFDictionaryRemoveValue(dict, CFSTR(SYSPROBE_THERMAL_LABEL));
    }

    int stored = thermal_store(dict, format, &error);
    CFRelease(dict);

    if (stored != 0) {
        fprintf(stderr, "thermal: cannot write %s (%s)\n", SYSPROBE_DISABLED_PLIST, error);
        return SYSPROBE_EXIT_FAILED;
    }

    int now = 0;
    if (thermal_read_disabled(&now, &error) != 0) {
        fprintf(stderr, "thermal: read-back failed (%s)\n", error);
        return SYSPROBE_EXIT_FAILED;
    }
    if (now != disabled) {
        fprintf(stderr, "thermal: read-back mismatch (wanted %d, got %d)\n", disabled, now);
        return SYSPROBE_EXIT_FAILED;
    }
    return SYSPROBE_EXIT_OK;
}

// ── 存储清理（clean-scan / clean-run）────────────────────────────────────────
//
//  ── 来源与边界 ────────────────────────────────────────────────────────────
//
//  做法参考了对 iOSCleanerPro 1.0（无 LICENSE 的第三方样本）的分析结果：
//  它的核心就是「递归统计 + 清空固定目录集合 + 按应用容器清 Library/Caches」，
//  没有任何私有 API。代码是这里重写的，与 RebootTools 那两条同样的理由 ——
//  样本无 LICENSE，且它列表里还有一段硬编码的假数据（Safari 150 MB 之类），
//  这里只显示实测值，查不到就是查不到。
//
//  目录集合是**刻意收窄**的，评估时定下的两条边界别顺手放开：
//
//    · **不碰照片缓存**（`/var/mobile/Media/PhotoData/*`）：清掉不是故障，
//      但照片 App 会全量重建缩略图，发热耗电数小时 —— 收益配不上代价；
//    · **不碰 `Media/Downloads`**：那里面可能有用户主动保存的文件。
//
//  ── 三条安全约束（改这段时不要去掉）─────────────────────────────────────
//
//  1. **只删内容，不删目录本身**。清空后目录还归原来的属主，守护进程往里写新
//     缓存不需要任何额外步骤；「删掉再 mkdir」会把属主变成 root，那才是真故障。
//     所以顶层入口走 `clean_empty_dir`，只有入口**之下**的子树才会整棵删掉；
//  2. **系统缓存的顶层有排除名单**（`clean_system_exclusions`）：那里有个别
//     「名字叫缓存、实际是状态」的 com.apple.* 目录，删了不是崩，是各种
//     系统建议、同步状态悄悄变差 —— 名单刻意保持小，每一条都得有理由；
//  3. **不跟随符号链接**：统计与删除都用 `lstat`。符号链接按链接本身处理，
//     绝不递归进目标 —— 那是「清个缓存把别处清掉」级别的事故路径。
//
//  ── 与 App 的通信 ─────────────────────────────────────────────────────────
//
//  扫描/清理的结果没法从退出码带回来，所以走**报告文件**：App 把自己 tmp 目录里
//  的一个路径作为参数传进来，这里写完 JSON、`chmod 0644`（报告的属主是 root，
//  不放开权限 App 读不到）再退出。App 读完自己删。报告里只写实测值，
//  没有任何占位数据。

/// 系统缓存目录。清理它的**内容**，顶层条目按下面的名单过滤。
#define CLEAN_SYSTEM_CACHE_DIR "/var/mobile/Library/Caches"
/// 日志目录。两个都清，都不存在是合法状态（0 字节）。
#define CLEAN_LOGS_DIR_1 "/var/mobile/Library/Logs"
#define CLEAN_LOGS_DIR_2 "/var/mobile/Library/Preferences/Logs"
/// 临时目录。样本还清了自己的 `NSTemporaryDirectory()`；这里不 —— 裸工具的
/// 临时目录落在 `/var/folders/zz`（系统的），碰它的收益是零，风险却说不清。
#define CLEAN_TEMP_DIR "/var/tmp"
/// 应用数据容器根。每个子目录是一个容器，容器根的 MCM 元数据里有真实 bundle id。
#define CLEAN_DATA_CONTAINERS "/var/mobile/Containers/Data/Application"
/// 应用安装容器根。显示名与图标路径从这里来（读各 .app 的 Info.plist）。
#define CLEAN_BUNDLE_CONTAINERS "/var/containers/Bundle/Application"

/// 容器根的元数据文件与键名。键名必须是字面量才能用 `CFSTR`。
#define CLEAN_MCM_PLIST ".com.apple.mobile_container_manager.metadata.plist"
#define CLEAN_MCM_KEY "MCMMetadataIdentifier"

/// 路径缓冲区。iOS 的 PATH_MAX 是 1024；缓存路径都在几百字节以内，
/// 超限的条目跳过并记错误，不去赌「刚好放得下」。
#define CLEAN_PATH_MAX 1024
/// 递归深度上限。不是防符号链接（那条由 `lstat` 管），是防真正的超深目录树
/// 把栈吃掉 —— 缓存目录不会嵌套这么深，超过了当异常跳过。
#define CLEAN_DEPTH_MAX 32
#define CLEAN_MAX_APPS 512
/// 同一个 bundle id 最多记录的容器数。超过的部分照样统计字节数，只是不再
/// 记路径 —— 清理时是按 bundle id 现场重新定位容器的，不依赖这份列表。
#define CLEAN_MAX_CONTAINERS_PER_APP 8
#define CLEAN_MAX_NAME_ENTRIES 1024
/// 错误条数上限。清理是「尽力而为」：个别文件正被占用删不掉是常态，
/// 记进报告即可，不能让一个 EPERM 把整次清理判成失败。
#define CLEAN_MAX_ERRORS 24

/// 系统缓存顶层的排除名单。**只挡名字完全相等的顶层条目**，不做前缀匹配 ——
/// 名单的价值在于每一条都明确知道为什么不能删，模糊匹配会让它悄悄变成黑洞。
///
/// 为什么是这五条（全是「缓存之名、状态之实」）：
///
///   · `com.apple.routined`                位置行为学习（常用地点、 Significant Locations）
///   · `com.apple.suggestions`             Siri 与搜索的建模数据
///   · `com.apple.assistant`               Siri 的语音与上下文
///   · `com.apple.cloudd`                  iCloud 同步引擎的缓存，删了触发全量重新同步
///   · `com.apple.dataaccess.dataaccessd`  邮件/日历/联系人的同步状态
static const char *const clean_system_exclusions[] = {
    "com.apple.routined",
    "com.apple.suggestions",
    "com.apple.assistant",
    "com.apple.cloudd",
    "com.apple.dataaccess.dataaccessd",
};

/// 一次清理的累计结果。栈上分配（错误条目是定长数组）。
typedef struct {
    /// 已释放的字节数。按删掉**之前**的文件大小累加。
    uint64_t freed;
    char errors[CLEAN_MAX_ERRORS][192];
    int errorCount;
    /// 这次要写的报告路径 —— 绝不能被「清临时文件」自己删掉。只是保险：
    /// 报告写在 App 的 tmp 里，不在这几个被清的目录底下。
    const char *reportPath;
} clean_context;

static void clean_record_error(clean_context *ctx, const char *what, const char *path) {
    if (ctx == NULL || ctx->errorCount >= CLEAN_MAX_ERRORS) {
        return;
    }
    snprintf(ctx->errors[ctx->errorCount], sizeof(ctx->errors[0]),
             "%s: %s: %s", what, path, strerror(errno));
    ctx->errorCount++;
}

static int clean_name_is_excluded(const char *name) {
    for (size_t i = 0; i < sizeof(clean_system_exclusions) / sizeof(clean_system_exclusions[0]); i++) {
        if (strcmp(name, clean_system_exclusions[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/// 递归统计 `path` 的字节数。`lstat` 不跟符号链接（见安全约束 3）；
/// 读不到的条目按 0 计 —— 扫描要的是「能清多少」的量级，不是审计。
static uint64_t clean_measure(const char *path, int depth) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        return 0;
    }
    if (S_ISDIR(st.st_mode)) {
        if (depth >= CLEAN_DEPTH_MAX) {
            return 0;
        }
        DIR *dir = opendir(path);
        if (dir == NULL) {
            return 0;
        }
        uint64_t total = 0;
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
                continue;
            }
            char child[CLEAN_PATH_MAX];
            int n = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
            if (n < 0 || n >= (int)sizeof(child)) {
                continue;
            }
            total += clean_measure(child, depth + 1);
        }
        closedir(dir);
        return total;
    }
    return (uint64_t)st.st_size;
}

/// 系统缓存的可清理量：顶层条目应用排除名单 —— 扫描显示的数字必须与
/// 「真去清理能释放的数字」是同一个口径，否则清理后界面会对不上账。
static uint64_t clean_measure_system(void) {
    DIR *dir = opendir(CLEAN_SYSTEM_CACHE_DIR);
    if (dir == NULL) {
        return 0;
    }
    uint64_t total = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (clean_name_is_excluded(entry->d_name)) {
            continue;
        }
        char child[CLEAN_PATH_MAX];
        int n = snprintf(child, sizeof(child), "%s/%s", CLEAN_SYSTEM_CACHE_DIR, entry->d_name);
        if (n < 0 || n >= (int)sizeof(child)) {
            continue;
        }
        total += clean_measure(child, 0);
    }
    closedir(dir);
    return total;
}

/// 递归删除 `path` 整棵子树，把字节数记进 `ctx->freed`。
/// 只被 `clean_empty_dir` 调在入口目录**之下** —— 顶层入口目录本身永远保留。
static void clean_remove_tree(const char *path, clean_context *ctx, int depth) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        clean_record_error(ctx, "lstat", path);
        return;
    }
    if (S_ISDIR(st.st_mode)) {
        if (depth >= CLEAN_DEPTH_MAX) {
            clean_record_error(ctx, "too-deep", path);
            return;
        }
        DIR *dir = opendir(path);
        if (dir == NULL) {
            clean_record_error(ctx, "opendir", path);
            return;
        }
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
                continue;
            }
            char child[CLEAN_PATH_MAX];
            int n = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
            if (n < 0 || n >= (int)sizeof(child)) {
                clean_record_error(ctx, "path-too-long", path);
                continue;
            }
            clean_remove_tree(child, ctx, depth + 1);
        }
        closedir(dir);
        // 子目录删完内容后把目录本身也摘掉 —— 重新生成缓存时守护进程会自己建。
        if (rmdir(path) != 0) {
            clean_record_error(ctx, "rmdir", path);
        }
        return;
    }
    // 文件与符号链接都走这里：链接按它自己删（st_size 是链接名的长度），
    // 绝不 `stat` 进目标。
    uint64_t size = (uint64_t)st.st_size;
    if (unlink(path) == 0) {
        ctx->freed += size;
    } else {
        clean_record_error(ctx, "unlink", path);
    }
}

/// 清空 `dir` 的**直接内容**，保留 `dir` 本身（安全约束 1）。
///
/// `applyExclusions` 只在该目录是系统缓存目录本身时为 1 —— 名单只挡**顶层**条目，
/// 子树内部不重复过滤（一个排除目录的子目录里出现同名条目是无害的巧合）。
static void clean_empty_dir(const char *dir, clean_context *ctx, int applyExclusions) {
    DIR *handle = opendir(dir);
    if (handle == NULL) {
        // ENOENT = 目录本来就不存在 = 没得清，不是错误。
        if (errno != ENOENT) {
            clean_record_error(ctx, "opendir", dir);
        }
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(handle)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (applyExclusions && clean_name_is_excluded(entry->d_name)) {
            continue;
        }
        char child[CLEAN_PATH_MAX];
        int n = snprintf(child, sizeof(child), "%s/%s", dir, entry->d_name);
        if (n < 0 || n >= (int)sizeof(child)) {
            clean_record_error(ctx, "path-too-long", dir);
            continue;
        }
        if (ctx->reportPath != NULL && strcmp(child, ctx->reportPath) == 0) {
            continue;
        }
        clean_remove_tree(child, ctx, 0);
    }
    closedir(handle);
}

/// 从 plist 文件里取一个字符串键的值。文件读不出 / 不是字典 / 键不是字符串
/// 都算失败 —— 调用方自行决定退路。
///
/// 键名是运行期参数，用 `CFStringCreateWithCString`；`CFSTR` 只收编译期字面量。
static int clean_plist_string(const char *path, const char *key, char *out, size_t outSize) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (url == NULL) {
        return 0;
    }
    CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
    CFRelease(url);
    if (stream == NULL) {
        return 0;
    }
    if (!CFReadStreamOpen(stream)) {
        CFRelease(stream);
        return 0;
    }
    CFPropertyListRef plist = CFPropertyListCreateWithStream(
        kCFAllocatorDefault, stream, 0, kCFPropertyListImmutable, NULL, NULL);
    CFReadStreamClose(stream);
    CFRelease(stream);
    if (plist == NULL) {
        return 0;
    }

    int ok = 0;
    if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFStringRef keyRef = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
        if (keyRef != NULL) {
            CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)plist, keyRef);
            CFRelease(keyRef);
            if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
                ok = CFStringGetCString((CFStringRef)value, out, (CFIndex)outSize, kCFStringEncodingUTF8);
            }
        }
    }
    CFRelease(plist);
    return ok;
}

/// 读容器根目录的 MCM 元数据，拿 `MCMMetadataIdentifier`（真实 bundle id）。
/// 读不出返回 0 —— 不是所有容器都是应用容器，跳过即可。
static int clean_read_mcm_identifier(const char *containerDir, char *out, size_t outSize) {
    char path[CLEAN_PATH_MAX];
    int n = snprintf(path, sizeof(path), "%s/%s", containerDir, CLEAN_MCM_PLIST);
    if (n < 0 || n >= (int)sizeof(path)) {
        return 0;
    }
    return clean_plist_string(path, CLEAN_MCM_KEY, out, outSize);
}

/// `clean-scan` 的逐项计数，随报告一起回传，用来定位「应用缓存恒为 0」这类问题。
///
/// 2026-10-03 加：真机上原版 iOSCleanerPro 扫到 1.28 GB 应用缓存，本工具扫到 0，
/// 而单看报告分不清是「容器目录打不开」「MCM 元数据读不出」还是「Caches 真是空的」
/// —— 三种情况的界面表现完全一样。所以把中间每一步的计数都带回来。
///
/// **定义必须排在 `clean_collect_names` / `clean_collect_apps` 之前**：C 的类型名
/// 要先声明后使用，放到它们后面会得到 `error: unknown type name`（第一版就是这么挂的）。
typedef struct {
    /// 数据容器根能否打开；打不开时 `dataErrno` 是 errno。
    int dataOpened;
    int dataErrno;
    /// `opendir` 失败时再 `stat` 一次，区分「路径不存在」与「权限不足」。
    int dataStatOk;
    /// 枚举到的条目数 / 其中确认是目录的。
    int dataEntries;
    int dataDirs;
    /// MCM 元数据读取成功 / 失败数。
    int mcmOk;
    int mcmFailed;
    /// 第一个读失败的容器及其原因（`access` 探测：文件不存在 / 存在但解析失败）。
    char firstMcmFail[320];
    /// `Library/Caches` 实测非零 / 为零（含不存在）的容器数。
    int cachesNonEmpty;
    int cachesEmpty;
    /// 安装容器根能否打开，以及收集到的 bundle 条目数。
    int bundleOpened;
    int bundleErrno;
    int nameEntries;
} clean_app_diagnostics;

/// bundle id → 显示名 / 安装路径 的映射节点。链表足够 —— 最多几百条，
/// 查找是 O(n) 的 `strcmp`，总量可以忽略。
typedef struct clean_name_entry {
    char bundle[192];
    char name[128];
    /// .app 的安装路径。报告里带给 App，App 用它找图标；取不到显示名时
    /// App 侧退回显示 bundle id —— 绝不编数据。
    char bundlePath[512];
    struct clean_name_entry *next;
} clean_name_entry;

static clean_name_entry *clean_find_name(clean_name_entry *head, const char *bundle) {
    for (clean_name_entry *node = head; node != NULL; node = node->next) {
        if (strcmp(node->bundle, bundle) == 0) {
            return node;
        }
    }
    return NULL;
}

/// 遍历安装容器，收集 bundle id → 显示名 / .app 路径。
/// 系统应用（/Applications 下的）不在安装容器里，它们退回显示 bundle id。
static clean_name_entry *clean_collect_names(int *countOut, clean_app_diagnostics *diag) {
    clean_name_entry *head = NULL;
    int count = 0;

    DIR *dir = opendir(CLEAN_BUNDLE_CONTAINERS);
    if (dir == NULL) {
        if (diag != NULL) {
            diag->bundleOpened = 0;
            diag->bundleErrno = errno;
        }
        *countOut = 0;
        return NULL;
    }
    if (diag != NULL) {
        diag->bundleOpened = 1;
        diag->bundleErrno = 0;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && count < CLEAN_MAX_NAME_ENTRIES) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char container[CLEAN_PATH_MAX];
        int n = snprintf(container, sizeof(container), "%s/%s", CLEAN_BUNDLE_CONTAINERS, entry->d_name);
        if (n < 0 || n >= (int)sizeof(container)) {
            continue;
        }
        struct stat st;
        if (lstat(container, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        char bundle[192];
        if (!clean_read_mcm_identifier(container, bundle, sizeof(bundle))) {
            continue;
        }
        // 同一个 bundle id 出现两个安装容器不该发生，发生了取第一个，别炸。
        if (clean_find_name(head, bundle) != NULL) {
            continue;
        }

        // 容器里的 .app 目录（正常恰好一个）。
        DIR *inner = opendir(container);
        if (inner == NULL) {
            continue;
        }
        char appName[256];
        appName[0] = '\0';
        struct dirent *sub;
        while ((sub = readdir(inner)) != NULL) {
            size_t len = strlen(sub->d_name);
            if (len > 4 && strcmp(sub->d_name + len - 4, ".app") == 0) {
                snprintf(appName, sizeof(appName), "%s", sub->d_name);
                break;
            }
        }
        closedir(inner);
        if (appName[0] == '\0') {
            continue;
        }

        clean_name_entry *node = malloc(sizeof(*node));
        if (node == NULL) {
            break;
        }
        snprintf(node->bundle, sizeof(node->bundle), "%s", bundle);
        node->bundlePath[0] = '\0';
        node->name[0] = '\0';

        char bundlePath[sizeof(node->bundlePath)];
        int m = snprintf(bundlePath, sizeof(bundlePath), "%s/%s", container, appName);
        if (m > 0 && m < (int)sizeof(bundlePath)) {
            snprintf(node->bundlePath, sizeof(node->bundlePath), "%s", bundlePath);

            // 显示名：CFBundleDisplayName，退回 CFBundleName。都取不到就留空，
            // 报告里由写报告的那一步退回 bundle id。
            char infoPath[sizeof(bundlePath) + 16];
            if (snprintf(infoPath, sizeof(infoPath), "%s/Info.plist", bundlePath) < (int)sizeof(infoPath)) {
                if (!clean_plist_string(infoPath, "CFBundleDisplayName", node->name, sizeof(node->name))) {
                    (void)clean_plist_string(infoPath, "CFBundleName", node->name, sizeof(node->name));
                }
            }
        }

        node->next = head;
        head = node;
        count++;
    }
    closedir(dir);

    if (diag != NULL) {
        diag->nameEntries = count;
    }
    *countOut = count;
    return head;
}

static void clean_free_names(clean_name_entry *head) {
    while (head != NULL) {
        clean_name_entry *next = head->next;
        free(head);
        head = next;
    }
}

/// 按 bundle id 聚合后的应用缓存条目。
typedef struct {
    char bundle[192];
    char name[128];
    char bundlePath[512];
    uint64_t bytes;
    /// 数据容器路径（容器根，不带 `Library/Caches`）。记录下来只为调试方便，
    /// 清理时不依赖它（见 `clean_run_apps`）。
    char containers[CLEAN_MAX_CONTAINERS_PER_APP][192];
    int containerCount;
} clean_app_entry;

static int clean_app_compare(const void *lhs, const void *rhs) {
    const clean_app_entry *a = (const clean_app_entry *)lhs;
    const clean_app_entry *b = (const clean_app_entry *)rhs;
    // 大的在前 —— 列表要按「谁占得多」排。
    if (a->bytes > b->bytes) return -1;
    if (a->bytes < b->bytes) return 1;
    return 0;
}

/// 遍历数据容器，按 bundle id 聚合每个应用的 `Library/Caches` 大小。
/// 缓存为 0 的应用不进列表：列表只包含实测出东西的条目。
static int clean_collect_apps(clean_name_entry *names, clean_app_entry *apps, int maxApps,
                              clean_app_diagnostics *diag) {
    int count = 0;

    DIR *dir = opendir(CLEAN_DATA_CONTAINERS);
    if (dir == NULL) {
        if (diag != NULL) {
            diag->dataOpened = 0;
            diag->dataErrno = errno;
            // 再 stat 一次：区分「路径不存在」与「存在但没权限列目录」。
            struct stat dst;
            diag->dataStatOk = (stat(CLEAN_DATA_CONTAINERS, &dst) == 0) ? 1 : 0;
        }
        return 0;
    }
    if (diag != NULL) {
        diag->dataOpened = 1;
        diag->dataErrno = 0;
        diag->dataStatOk = 1;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && count < maxApps) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (diag != NULL) {
            diag->dataEntries++;
        }
        char container[CLEAN_PATH_MAX];
        int n = snprintf(container, sizeof(container), "%s/%s", CLEAN_DATA_CONTAINERS, entry->d_name);
        if (n < 0 || n >= (int)sizeof(container)) {
            continue;
        }
        struct stat st;
        if (lstat(container, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        if (diag != NULL) {
            diag->dataDirs++;
        }
        char bundle[192];
        if (!clean_read_mcm_identifier(container, bundle, sizeof(bundle))) {
            if (diag != NULL) {
                diag->mcmFailed++;
                // 第一个失败样本单独留下，并探测原因 —— 这决定了下一步该往哪儿查。
                if (diag->firstMcmFail[0] == '\0') {
                    char meta[CLEAN_PATH_MAX];
                    int k = snprintf(meta, sizeof(meta), "%s/%s", container, CLEAN_MCM_PLIST);
                    const char *why = "path too long";
                    if (k > 0 && k < (int)sizeof(meta)) {
                        why = (access(meta, F_OK) == 0) ? "metadata exists but not readable/parseable"
                                                        : "metadata file missing";
                    }
                    snprintf(diag->firstMcmFail, sizeof(diag->firstMcmFail), "%s (%s)", container, why);
                }
            }
            continue;
        }
        if (diag != NULL) {
            diag->mcmOk++;
        }
        char caches[CLEAN_PATH_MAX];
        int m = snprintf(caches, sizeof(caches), "%s/Library/Caches", container);
        if (m < 0 || m >= (int)sizeof(caches)) {
            continue;
        }
        uint64_t bytes = clean_measure(caches, 0);
        if (bytes == 0) {
            if (diag != NULL) {
                diag->cachesEmpty++;
            }
            continue;
        }
        if (diag != NULL) {
            diag->cachesNonEmpty++;
        }

        // 按 bundle id 聚合：同一应用的多个数据容器并成一条，容器路径记到上限为止。
        clean_app_entry *existing = NULL;
        for (int i = 0; i < count; i++) {
            if (strcmp(apps[i].bundle, bundle) == 0) {
                existing = &apps[i];
                break;
            }
        }
        if (existing != NULL) {
            existing->bytes += bytes;
            if (existing->containerCount < CLEAN_MAX_CONTAINERS_PER_APP) {
                snprintf(existing->containers[existing->containerCount],
                         sizeof(existing->containers[0]), "%s", container);
                existing->containerCount++;
            }
            continue;
        }

        clean_app_entry *slot = &apps[count];
        memset(slot, 0, sizeof(*slot));
        snprintf(slot->bundle, sizeof(slot->bundle), "%s", bundle);
        slot->bytes = bytes;
        snprintf(slot->containers[0], sizeof(slot->containers[0]), "%s", container);
        slot->containerCount = 1;

        clean_name_entry *name = clean_find_name(names, bundle);
        if (name != NULL) {
            snprintf(slot->name, sizeof(slot->name), "%s", name->name);
            snprintf(slot->bundlePath, sizeof(slot->bundlePath), "%s", name->bundlePath);
        }
        count++;
    }
    closedir(dir);

    return count;
}

// ── JSON 报告 ────────────────────────────────────────────────────────────────
//
// 手写而不上库：报告结构是固定的，要处理的只有「字符串转义」。显示名是任意
// UTF-8（中文应用名），UTF-8 字节在 JSON 字符串里原样合法，只需转义引号、
// 反斜杠与控制字符。

static void clean_json_string(FILE *f, const char *s) {
    fputc('"', f);
    for (const unsigned char *p = (const unsigned char *)s; *p != '\0'; p++) {
        unsigned char c = *p;
        switch (c) {
            case '"':  fputs("\\\"", f); break;
            case '\\': fputs("\\\\", f); break;
            case '\b': fputs("\\b", f); break;
            case '\f': fputs("\\f", f); break;
            case '\n': fputs("\\n", f); break;
            case '\r': fputs("\\r", f); break;
            case '\t': fputs("\\t", f); break;
            default:
                if (c < 0x20) {
                    fprintf(f, "\\u%04x", c);
                } else {
                    fputc(c, f);
                }
        }
    }
    fputc('"', f);
}

static void clean_json_category(FILE *f, const char *name, uint64_t bytes) {
    fprintf(f, "\"%s\":{\"bytes\":%llu}", name, (unsigned long long)bytes);
}

/// 报告写完必须 `chmod 0644`：文件是 root 建的，默认权限下 App（mobile）读不到，
/// 而那不会报错 —— App 只是拿到一份解析失败的报告，看起来像「扫描坏了」。
/// 往诊断数组里追加一行（自动处理逗号）。
static void clean_json_diag(FILE *f, int *first, const char *line) {
    if (!*first) {
        fputc(',', f);
    }
    *first = 0;
    clean_json_string(f, line);
}

static int clean_write_scan_report(const char *path,
                                   uint64_t system, uint64_t logs, uint64_t temp,
                                   const clean_app_entry *apps, int appCount,
                                   const clean_app_diagnostics *diag) {
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        return -1;
    }

    fputs("{\"categories\":{", f);
    clean_json_category(f, "system", system);
    fputc(',', f);
    clean_json_category(f, "logs", logs);
    fputc(',', f);
    clean_json_category(f, "temp", temp);
    fputs("},\"apps\":[", f);
    for (int i = 0; i < appCount; i++) {
        if (i > 0) {
            fputc(',', f);
        }
        fputc('{', f);
        fputs("\"bundle\":", f);
        clean_json_string(f, apps[i].bundle);
        fputs(",\"name\":", f);
        // 取不到显示名就退回 bundle id —— 报告里永远没有占位数据。
        clean_json_string(f, apps[i].name[0] != '\0' ? apps[i].name : apps[i].bundle);
        fputs(",\"bundlePath\":", f);
        clean_json_string(f, apps[i].bundlePath);
        fprintf(f, ",\"bytes\":%llu}", (unsigned long long)apps[i].bytes);
    }
    fputs("],\"diagnostics\":[", f);

    // 诊断是**给人看的**：App 侧原样显示、不解析。每一行都回答「卡在哪一步」——
    // 2026-10-03 加，起因是应用缓存恒为 0，而三种失败原因在界面上长得一模一样。
    if (diag != NULL) {
        int first = 1;
        char line[640];

        if (diag->dataOpened) {
            snprintf(line, sizeof(line), "data containers: opendir OK - %d entries, %d dirs",
                     diag->dataEntries, diag->dataDirs);
        } else {
            snprintf(line, sizeof(line),
                     "data containers: opendir FAILED errno=%d (%s), stat=%s",
                     diag->dataErrno, strerror(diag->dataErrno),
                     diag->dataStatOk ? "OK - exists but not listable" : "also failed");
        }
        clean_json_diag(f, &first, line);

        snprintf(line, sizeof(line), "MCM identifier: %d ok, %d failed",
                 diag->mcmOk, diag->mcmFailed);
        clean_json_diag(f, &first, line);

        if (diag->firstMcmFail[0] != '\0') {
            snprintf(line, sizeof(line), "first MCM failure: %s", diag->firstMcmFail);
            clean_json_diag(f, &first, line);
        }

        snprintf(line, sizeof(line), "Library/Caches: %d non-empty, %d empty or missing",
                 diag->cachesNonEmpty, diag->cachesEmpty);
        clean_json_diag(f, &first, line);

        if (diag->bundleOpened) {
            snprintf(line, sizeof(line), "bundle containers: opendir OK - %d names",
                     diag->nameEntries);
        } else {
            snprintf(line, sizeof(line), "bundle containers: opendir FAILED errno=%d (%s)",
                     diag->bundleErrno, strerror(diag->bundleErrno));
        }
        clean_json_diag(f, &first, line);
    }
    fputs("]}", f);

    fclose(f);
    chmod(path, 0644);
    return 0;
}

static int clean_write_run_report(const char *path, const char *scope, const char *bundle,
                                  const clean_context *ctx) {
    FILE *f = fopen(path, "w");
    if (f == NULL) {
        return -1;
    }

    fputs("{\"scope\":", f);
    clean_json_string(f, scope);
    fputs(",\"bundle\":", f);
    clean_json_string(f, bundle != NULL ? bundle : "");
    fprintf(f, ",\"freedBytes\":%llu", (unsigned long long)ctx->freed);
    fputs(",\"errors\":[", f);
    for (int i = 0; i < ctx->errorCount; i++) {
        if (i > 0) {
            fputc(',', f);
        }
        clean_json_string(f, ctx->errors[i]);
    }
    fputs("]}", f);

    fclose(f);
    chmod(path, 0644);
    return 0;
}

/// `clean-scan <report.json>`。
static int do_clean_scan(const char *reportPath) {
    if (geteuid() != 0) {
        return SYSPROBE_EXIT_NOT_ROOT;
    }

    uint64_t system = clean_measure_system();
    uint64_t logs = clean_measure(CLEAN_LOGS_DIR_1, 0) + clean_measure(CLEAN_LOGS_DIR_2, 0);
    uint64_t temp = clean_measure(CLEAN_TEMP_DIR, 0);

    // 诊断计数。栈上分配（约 350 字节），随报告一起回传。
    clean_app_diagnostics diag;
    memset(&diag, 0, sizeof(diag));

    int nameCount = 0;
    clean_name_entry *names = clean_collect_names(&nameCount, &diag);

    // 一块连续的表（最多 512 × 约 2.4 KB）一次性 malloc；进程马上就退出，
    // 失败路径里唯一要紧的是别把报告写出来。
    clean_app_entry *apps = malloc(sizeof(*apps) * CLEAN_MAX_APPS);
    if (apps == NULL) {
        clean_free_names(names);
        return SYSPROBE_EXIT_FAILED;
    }
    int appCount = clean_collect_apps(names, apps, CLEAN_MAX_APPS, &diag);
    qsort(apps, (size_t)appCount, sizeof(apps[0]), clean_app_compare);

    int status = clean_write_scan_report(reportPath, system, logs, temp, apps, appCount, &diag) == 0
                     ? SYSPROBE_EXIT_OK
                     : SYSPROBE_EXIT_FAILED;

    free(apps);
    clean_free_names(names);
    return status;
}

/// 清理应用容器。`bundleId` 为 NULL 时清**所有**容器的 `Library/Caches`；
/// 否则只清 bundle id 匹配的容器（一个应用可能有不止一个数据容器）。
///
/// 容器按 MCM 元数据现场重新定位，而不是用扫描报告里记下的路径 ——
/// 两次运行之间容器可能被系统挪走又建过，现查的才是真的。
static void clean_run_apps(const char *bundleId, clean_context *ctx) {
    DIR *dir = opendir(CLEAN_DATA_CONTAINERS);
    if (dir == NULL) {
        if (errno != ENOENT) {
            clean_record_error(ctx, "opendir", CLEAN_DATA_CONTAINERS);
        }
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char container[CLEAN_PATH_MAX];
        int n = snprintf(container, sizeof(container), "%s/%s", CLEAN_DATA_CONTAINERS, entry->d_name);
        if (n < 0 || n >= (int)sizeof(container)) {
            continue;
        }
        struct stat st;
        if (lstat(container, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        if (bundleId != NULL) {
            char bundle[192];
            // 全量清理时连 MCM 都不用读 —— 少几百次 plist 解析；按应用清才需要匹配。
            if (!clean_read_mcm_identifier(container, bundle, sizeof(bundle))) {
                continue;
            }
            if (strcmp(bundle, bundleId) != 0) {
                continue;
            }
        }
        char caches[CLEAN_PATH_MAX];
        int m = snprintf(caches, sizeof(caches), "%s/Library/Caches", container);
        if (m < 0 || m >= (int)sizeof(caches)) {
            continue;
        }
        struct stat cst;
        if (lstat(caches, &cst) != 0 || !S_ISDIR(cst.st_mode)) {
            continue; // 没有缓存目录的应用容器：没得清，跳过。
        }
        clean_empty_dir(caches, ctx, 0);
    }
    closedir(dir);
}

/// `clean-run <scope> <report.json> [bundleId]`。
///
/// scope：`system` / `logs` / `temp` / `apps` / `app` / `all`。
/// `app` 必须带 bundleId，只清那一个应用；`apps` 清全部应用。
///
/// 清理是**尽力而为**：个别文件正被占用删不掉记进报告的 errors，不影响退出码 ——
/// 「删掉了绝大部分」对用户是一次成功的清理，报成失败反而会诱导反复重试。
/// 只有「连报告都写不出来」才算失败。
static int do_clean_run(const char *scope, const char *reportPath, const char *bundleId) {
    if (geteuid() != 0) {
        return SYSPROBE_EXIT_NOT_ROOT;
    }

    const int isAll = strcmp(scope, "all") == 0;
    const int isSingleApp = strcmp(scope, "app") == 0;
    const int doSystem = isAll || strcmp(scope, "system") == 0;
    const int doLogs = isAll || strcmp(scope, "logs") == 0;
    const int doTemp = isAll || strcmp(scope, "temp") == 0;
    const int doApps = isAll || strcmp(scope, "apps") == 0;
    if (!doSystem && !doLogs && !doTemp && !doApps && !isSingleApp) {
        return SYSPROBE_EXIT_USAGE;
    }
    if (isSingleApp && (bundleId == NULL || bundleId[0] == '\0')) {
        return SYSPROBE_EXIT_USAGE;
    }

    clean_context ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.reportPath = reportPath;

    if (doSystem) {
        clean_empty_dir(CLEAN_SYSTEM_CACHE_DIR, &ctx, 1);
    }
    if (doLogs) {
        clean_empty_dir(CLEAN_LOGS_DIR_1, &ctx, 0);
        clean_empty_dir(CLEAN_LOGS_DIR_2, &ctx, 0);
    }
    if (doTemp) {
        clean_empty_dir(CLEAN_TEMP_DIR, &ctx, 0);
    }
    if (doApps || isSingleApp) {
        clean_run_apps(isSingleApp ? bundleId : NULL, &ctx);
    }

    if (clean_write_run_report(reportPath, scope, isSingleApp ? bundleId : NULL, &ctx) != 0) {
        return SYSPROBE_EXIT_FAILED;
    }
    return SYSPROBE_EXIT_OK;
}

int main(int argc, char *argv[]) {
    // clean-* 系列带自己的参数，放在「argc == 2」的检查**之前**分派。
    if (argc >= 2 && strcmp(argv[1], "clean-scan") == 0) {
        if (argc != 3) {
            fprintf(stderr, "usage: %s clean-scan <report.json>\n", argv[0]);
            return SYSPROBE_EXIT_USAGE;
        }
        return do_clean_scan(argv[2]);
    }
    if (argc >= 2 && strcmp(argv[1], "clean-run") == 0) {
        if (argc != 4 && argc != 5) {
            fprintf(stderr,
                    "usage: %s clean-run <system|logs|temp|apps|app|all> <report.json> [bundleId]\n",
                    argv[0]);
            return SYSPROBE_EXIT_USAGE;
        }
        return do_clean_run(argv[2], argv[3], argc == 5 ? argv[4] : NULL);
    }

    if (argc != 2) {
        fprintf(stderr,
                "usage: %s check|reboot|respring|restart-commcenter"
                "|thermal-status|thermal-disable|thermal-enable"
                "|clean-scan <report>|clean-run <scope> <report> [bundleId]\n",
                argv[0]);
        return SYSPROBE_EXIT_USAGE;
    }

    if (strcmp(argv[1], "check") == 0) {
        return do_check();
    }
    if (strcmp(argv[1], "reboot") == 0) {
        return do_reboot();
    }
    if (strcmp(argv[1], "respring") == 0) {
        return do_respring();
    }
    if (strcmp(argv[1], "restart-commcenter") == 0) {
        return do_restart_commcenter();
    }
    if (strcmp(argv[1], "thermal-status") == 0) {
        return do_thermal_status();
    }
    if (strcmp(argv[1], "thermal-disable") == 0) {
        return do_thermal_set(1);
    }
    if (strcmp(argv[1], "thermal-enable") == 0) {
        return do_thermal_set(0);
    }

    fprintf(stderr, "%s: unknown command %s\n", argv[0], argv[1]);
    return SYSPROBE_EXIT_USAGE;
}
