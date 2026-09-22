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

/// 127.0.0.1:`port` 上是否已经有人在监听。1 = 有，0 = 没有。
///
/// 用「真去 connect 一次」而不是查进程表：守护进程可能是上一次运行留下的
/// （它忽略 SIGHUP/SIGTERM，App 被划掉也活着），那时 App 里根本没有它的 pid。
/// 端口开着就是它活着，这是唯一可靠的判据。
int sysprobe_local_port_open(int port);

#endif /* SYSPROBE_CHARGE_SPAWN_H */
