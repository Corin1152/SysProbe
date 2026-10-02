//
//  ChargeSpawn.h
//  SysProbe
//
//  充电守护进程的启动与存活探测。
//
//  为什么这两件事落在 C 而不是 Swift：
//
//  · `posix_spawn` 在 Swift 里的签名是五层嵌套指针
//    （`UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>`），搭 `argv` / `environ`
//    要一路 `strdup` 加 `withUnsafe...`，写出来比这里长三倍，还容易漏掉 `nil` 结尾；
//  · 真正决定成败的 `posix_spawnattr_set_persona_np` 是 Apple 的 **SPI**，
//    公开 SDK 里没有声明。C 里自己补一行原型就能用，Swift 里得靠 `@_silgen_name`
//    去骗链接器 —— 同样能用，但没人看得懂。
//
//  调用点在 `ChargeControlService`。
//

#ifndef SYSPROBE_CHARGE_SPAWN_H
#define SYSPROBE_CHARGE_SPAWN_H

#include <sys/types.h>

/// 以 root（system persona，uid/gid 0）身份启动守护进程。
///
/// 成功返回 0；失败返回 `posix_spawn` 的 errno（正数），或者 attr 初始化失败的 errno。
/// 注意「返回 0」只代表**进程起来了**，不代表它已经把 1230 端口监听上了 ——
/// 端口要另外用 `sysprobe_local_port_open` 确认。
///
/// `path` 必须是绝对路径。守护进程用 `argc == 1` 判定自己该走「常驻服务」那条分支，
/// 所以这里刻意**不传任何参数**。
int sysprobe_spawn_root_daemon(const char *path);

/// 以 root 身份启动包内的维护工具（`SysProbeRootTool`），并给它一个子命令。
///
/// 与上面那个的唯一区别就是**多传一个 `argv[1]`**：守护进程靠 `argc == 1` 判定自己该
/// 常驻，所以那边一个参数都不能给；而这个工具靠 `argv[1]` 分派子命令，所以必须给。
/// 其余（persona 99 / uid 0 / gid 0 / `POSIX_SPAWN_CLOEXEC_DEFAULT`）完全一致。
///
/// 返回值同 `sysprobe_spawn_root_daemon`：0 = 进程起来了。**发了就不管** ——
/// `reboot` 永远不返回、`respring` 会让调用方自己被系统收掉，两者都回读不到结果。
/// 需要结果的地方用下面那个同步变体。
int sysprobe_spawn_root_tool(const char *toolPath, const char *command);

/// 同 `sysprobe_spawn_root_tool`，但**等子进程结束**并把它的退出码带回来。
///
/// 只给 `check` 这种短命（毫秒级）子命令用 —— 它是设置页用来确认「子进程真的拿到了
/// root」的唯一手段。**不要拿它跑 `reboot` / `respring`**：前者永不返回，后者会让
/// 本进程被系统收掉，等待没有意义。
///
/// 返回 0 表示子进程正常收尸，此时 `*exitStatus` 是它的退出码（被信号杀掉时为 -1）；
/// 非 0 表示连 `posix_spawn` 都没成功，此时 `*exitStatus` 不被写。
/// 等不到也会返回一个错误（`ETIMEDOUT`），不会无限期挂着。
int sysprobe_spawn_root_tool_sync(const char *toolPath, const char *command, int *exitStatus);

/// 同 `sysprobe_spawn_root_tool_sync`，但**可以给子命令带最多三个附加参数**，并允许
/// 指定等待预算。
///
/// 为「存储清理」新增的变体。两个既有入口满足不了它：
///
///   · **参数**：`clean-scan` 要报告文件的落盘路径、`clean-run` 还要清理范围与
///     （可选的）目标 bundle id —— 老入口只能传一个子命令；
///   · **时间**：老入口固定等约 1 秒（对 `check` 这种毫秒级自检刚好），而一次
///     扫描要遍历几百个应用容器、一次「全部清理」要递归删几十万个文件，
///     秒级预算会把正在干活的子进程误判成超时。
///
/// `arg1`/`arg2`/`arg3` 可以为 `NULL`，为 `NULL` 的参数不进 `argv`；
/// `arg2` / `arg3` 非空时 `arg1` 也必须非空。`timeoutMs` 是等待子进程退出的总预算
/// （毫秒），超时返回 `ETIMEDOUT` 且**不杀**子进程 —— 它可能正在干活，
/// 而清理本来就没有「取消」的语义。
///
/// 其余（persona 序列、`CLOEXEC_DEFAULT`、轮询收尸的写法）与两个老入口逐行同构；
/// 那段代码已在真机上验证过，这里刻意**不共用**一个可变参数的公共实现，
/// 免得为这一个功能去碰已验证的代码路径。
int sysprobe_spawn_root_tool_sync_args(const char *toolPath,
                                       const char *command,
                                       const char *arg1,
                                       const char *arg2,
                                       const char *arg3,
                                       int timeoutMs,
                                       int *exitStatus);

/// 127.0.0.1:`port` 上是否已经有人在监听。1 = 有，0 = 没有。
///
/// 用「真去 connect 一次」而不是查进程表：守护进程可能是上一次运行留下的
/// （它忽略 SIGHUP/SIGTERM，App 被划掉也活着），那时 App 里根本没有它的 pid。
/// 端口开着就是它活着，这是唯一可靠的判据。
int sysprobe_local_port_open(int port);

#endif /* SYSPROBE_CHARGE_SPAWN_H */
