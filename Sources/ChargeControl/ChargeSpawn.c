//
//  ChargeSpawn.c
//  SysProbe
//
//  见 ChargeSpawn.h 里的说明。实现与 ChargeLimiter 1.7 的 `utils.mm` 等价 ——
//  那套代码已经在 iPhone X / iOS 16.5.1 / TrollStore 上验证过能真正停充，
//  这里刻意不做「优化」，只做减法（去掉日志、去掉 stdout/stderr 管道）。
//
//  文件里有两个入口，共用同一段属性设置（`sysprobe_spawn_root`）：
//
//    · `sysprobe_spawn_root_daemon` —— 充电守护进程，**不传参数**；
//    · `sysprobe_spawn_root_tool` / `_sync` —— 设置页的维护工具（重启设备 / 注销），
//      **传一个子命令**。
//
//  两者的 persona 序列逐行相同，改这段时两边一起看。
//

#include "ChargeSpawn.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <spawn.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// ── Apple 的 SPI ─────────────────────────────────────────────────────────────
//
// 公开 SDK 里没有这几个原型，但符号从 iOS 10 起一直在 libsystem 里。
// 自己补声明比引入 `spawn_private.h`（不在 SDK 里）可靠。
//
// 三行合起来的效果：让子进程以 **system persona 的 uid 0** 运行，也就是 root。
// 守护进程需要 root 才能做两件缺一不可的事：
//
//   1. 读写 `/var/root/aldente.conf` —— 充电阈值这些配置就存在那儿
//      （沿用 AlDente 的路径，所以本 App 与 ChargeLimiter、AlDente 共用同一份设置）；
//   2. 对 IOPMPS 服务调 `IORegistryEntrySetCFProperties` —— 这才是**真正停充**的那一步。
//
// 少了这一步，它只能以 mobile 身份跑，第 2 步会返回 kIOReturnNotPrivileged：
// 界面上一切正常、配置也能存，但充电**一点都不会停**，而且没有任何报错。
//
// 代价是 App 侧必须有 `com.apple.private.persona-mgmt`，见 Support/SysProbe.entitlements。
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attr, uid_t persona, uint32_t flags);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attr, uid_t uid);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attr, gid_t gid);

/// `POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE`，同样来自 `spawn_private.h`。
/// 意思是「就用我说的这个 persona，别去校验调用者本来属于哪个」。
#define SYSPROBE_PERSONA_FLAGS_OVERRIDE 1

/// persona 99 = system。配合上面的 uid/gid 0 就是 root。
#define SYSPROBE_SYSTEM_PERSONA 99

/// 公共实现：建属性 → 设 persona → spawn。
///
/// `argv` 由调用方给，因为「传不传参数」正是两个入口唯一的区别（见下面两个包装）。
/// 这段序列与 ChargeLimiter 1.7 的 `utils.mm` 等价，已经在真机上验证过 ——
/// **不要在这里做「优化」**。
static int sysprobe_spawn_root(const char *path, char *const *argv, pid_t *pidOut) {
    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0) {
        return err;
    }

    // 三个 persona 调用**没有返回值检查**，这是有意的：它们在没有
    // `com.apple.private.persona-mgmt` 时会失败，但失败之后 `posix_spawn` 仍然会成功 ——
    // 只是子进程变成 mobile 身份。这里若提前 return，反倒会退化成「子进程压根没起来」，
    // 比「起来了但没权限」更难排查。
    //
    // 代价是两个调用方各自的失败都**发生在子进程里、传不回来**：
    //   · 充电守护进程 → 界面正常、配置能存，但充电一点都不会停；
    //   · 维护工具     → 按钮点下去什么都不发生。
    // 所以两边都必须有独立的「怎么知道它真的生效了」的判据：守护进程靠 1230 端口
    // （`sysprobe_local_port_open`），维护工具靠它自己的 `check` 子命令
    // （`sysprobe_spawn_root_tool_sync`）。
    posix_spawnattr_set_persona_np(&attr, SYSPROBE_SYSTEM_PERSONA, SYSPROBE_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    // `POSIX_SPAWN_CLOEXEC_DEFAULT`：子进程里除 file actions 显式安排的之外，
    // 所有 fd 一律关闭。App 这边开着 IOKit 的 notification port、HID 的
    // event system client，还有一堆 socket —— 不关的话它们全被子进程继承，
    // 守护进程每被重启一次就多留一份引用，最后 App 自己反而关不掉那些服务。
    //
    // 注意这是**覆盖**而不是追加：persona 那三个调用走的是另一组属性，不受影响。
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);

    pid_t pid = -1;
    err = posix_spawn(&pid, path, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);

    if (pidOut != NULL) {
        *pidOut = pid;
    }
    return err;
}

int sysprobe_spawn_root_daemon(const char *path) {
    if (path == NULL || path[0] != '/') {
        return EINVAL;
    }

    // 守护进程靠 `argc == 1` 判定自己该常驻。多传一个参数它就会去走
    // 「悬浮窗」那条分支 —— 那条分支要求包里还有一个 `SysProbe` 可执行文件，
    // 而那是 App 自己，会当场再拉起一个 App。所以这里必须一个参数都不给。
    char *const argv[] = { (char *const)path, NULL };

    return sysprobe_spawn_root(path, argv, NULL);
}

int sysprobe_spawn_root_tool(const char *toolPath, const char *command) {
    if (toolPath == NULL || toolPath[0] != '/') {
        return EINVAL;
    }
    if (command == NULL || command[0] == '\0') {
        return EINVAL;
    }

    // `argv` 是栈上的，而 `posix_spawn` 是同步的（返回时内核已经拷走了参数），
    // 所以不需要把这块内存活到子进程结束。
    char *const argv[] = {
        (char *const)toolPath,
        (char *const)command,
        NULL,
    };

    return sysprobe_spawn_root(toolPath, argv, NULL);
}

int sysprobe_spawn_root_tool_sync(const char *toolPath, const char *command, int *exitStatus) {
    if (toolPath == NULL || toolPath[0] != '/') {
        return EINVAL;
    }
    if (command == NULL || command[0] == '\0') {
        return EINVAL;
    }

    char *const argv[] = {
        (char *const)toolPath,
        (char *const)command,
        NULL,
    };

    pid_t pid = -1;
    int err = sysprobe_spawn_root(toolPath, argv, &pid);
    if (err != 0) {
        return err;
    }

    // 轮询而不是 `waitpid(..., 0)`：调用点在设置页的呈现路径上，万一子进程卡住，
    // 阻塞式等待会把主线程一起拖死 —— 那比报一个超时难查得多。这里最多等约 1 秒。
    //
    // 超时**不杀**子进程：它可能正在干活，而且这两个动作本来就没有「取消」的语义。
    int status = 0;
    for (int attempt = 0; attempt < 100; attempt++) {
        pid_t reaped = waitpid(pid, &status, WNOHANG);
        if (reaped == pid) {
            if (exitStatus != NULL) {
                *exitStatus = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            }
            return 0;
        }
        if (reaped < 0) {
            // EINTR 只是这一轮被打断了，不是子进程出了问题 —— 继续等，
            // 否则一次无关的信号就会让自检误报「工具不可用」。
            if (errno != EINTR) {
                return errno;
            }
        }
        usleep(10 * 1000);
    }

    return ETIMEDOUT;
}

int sysprobe_local_port_open(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        return 0;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    // `sin_len` 是 `uint8_t`，直接赋 `sizeof` 会撞上 -Wshorten-64-to-32。
    addr.sin_len = (uint8_t)sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    // 非阻塞 connect：本机上没人监听时是立刻 ECONNREFUSED，有人监听则进 EINPROGRESS，
    // 用 select 等它把三次握手走完。不设非阻塞的话，对一台还没起来的服务会阻塞到
    // 内核的 SYN 超时，那是秒级的卡顿，而调用点在主线程的定时器里。
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags != -1) {
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    }

    int open = 0;
    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        open = 1;
    } else if (errno == EINPROGRESS) {
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(sock, &writable);
        struct timeval timeout;
        timeout.tv_sec = 1;
        timeout.tv_usec = 0;
        if (select(sock + 1, NULL, &writable, NULL, &timeout) == 1) {
            int so_error = -1;
            socklen_t length = sizeof(so_error);
            if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &length) == 0) {
                open = (so_error == 0);
            }
        }
    }

    close(sock);
    return open;
}
