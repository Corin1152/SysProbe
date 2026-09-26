//
//  RootTool.c
//  SysProbe
//
//  SysProbeRootTool —— 一个**裸可执行文件**，由主 App 用 posix_spawn 以 root 身份
//  拉起（见 `ChargeSpawn.c` 的 `sysprobe_spawn_root_tool`）。子命令：
//
//      check       自检：确认自己真的是以 root 跑起来的
//      reboot      重启设备
//      respring    注销（只重启界面层，不重启设备）
//
//  ── 为什么是独立二进制，而不是把这几行写进 App ──────────────────────────
//
//  这两个动作都要求 uid 0，而 App 自己是 mobile。SysProbe 已经有「以 root 拉起
//  包内二进制」的完整链路 —— 充电守护进程走的就是它（`ChargeSpawn.c` 里的
//  persona 99 / uid 0 / gid 0 那一套，已在真机上验证过）。这里不再造第二套。
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

/// 找到 SpringBoard 的 pid。找不到返回 -1。
///
/// 走 `sysctl(KERN_PROC_ALL)` 自己遍历，而不是调用系统的 `killall` —— 后者在
/// iOS 上是私有 API，公开 SDK 里没有原型。遍历本身是公开接口。
static pid_t springboard_pid(void) {
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
        // `p_comm` 是 `char[MAXCOMLEN + 1]`（17 字节），"SpringBoard" 11 字节，
        // 不会被截断。
        if (strcmp(procs[i].kp_proc.p_comm, SYSPROBE_SPRINGBOARD) == 0) {
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
    pid_t pid = springboard_pid();
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

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s check|reboot|respring\n", argv[0]);
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

    fprintf(stderr, "%s: unknown command %s\n", argv[0], argv[1]);
    return SYSPROBE_EXIT_USAGE;
}
