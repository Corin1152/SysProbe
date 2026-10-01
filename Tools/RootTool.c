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

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr,
                "usage: %s check|reboot|respring|restart-commcenter"
                "|thermal-status|thermal-disable|thermal-enable\n",
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
