//
//  ChargeSpawn.c
//  SysProbe
//
//  见 ChargeSpawn.h 里的说明。实现与 ChargeLimiter 1.7 的 `utils.mm` 等价 ——
//  那套代码已经在 iPhone X / iOS 16.5.1 / TrollStore 上验证过能真正停充，
//  这里刻意不做「优化」，只做减法（去掉日志、去掉 stdout/stderr 管道、
//  去掉 pid 回传，我们不需要）。
//

#include "ChargeSpawn.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <spawn.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
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

int sysprobe_spawn_root_daemon(const char *path) {
    if (path == NULL || path[0] != '/') {
        return EINVAL;
    }

    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0) {
        return err;
    }

    // 三个 persona 调用**没有返回值检查**，这是有意的：它们在没有
    // `com.apple.private.persona-mgmt` 时会失败，但失败之后 `posix_spawn` 仍然会成功 ——
    // 只是子进程变成 mobile 身份（症状见文件头）。这里若提前 return，反倒会退化成
    // 「守护进程压根没起来」，比「起来了但停不了充」更难排查。让 spawn 照常进行，
    // 由界面上的状态行去暴露「服务在跑但没生效」。
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

    // 守护进程靠 `argc == 1` 判定自己该常驻。多传一个参数它就会去走
    // 「悬浮窗」那条分支 —— 那条分支要求包里还有一个 `SysProbe` 可执行文件，
    // 而那是 App 自己，会当场再拉起一个 App。所以这里必须一个参数都不给。
    char *const argv[] = { (char *const)path, NULL };

    pid_t pid = -1;
    err = posix_spawn(&pid, path, NULL, &attr, (char *const *)argv, environ);
    posix_spawnattr_destroy(&attr);
    return err;
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
