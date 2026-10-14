//
//  CommCenterBridge.h
//  SysProbe
//
//  「频段设置」的取数与写入。实现与取舍见 CommCenterBridge.m。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 频段读写的可用性。
typedef NS_ENUM(NSInteger, SysProbeBandStatus) {
    /// 还没试过。
    SysProbeBandStatusUnknown = 0,
    /// 上一次调用成功。
    SysProbeBandStatusOK,
    /// 类或方法找不到，或者 CommCenter 拒绝了连接 —— 后者多半是没有 CommCenter 权限。
    SysProbeBandStatusUnavailable,
};

/// 读某个卡槽的频段。
///
/// 成功返回 `@{@"active": @{制式: @[频段号, …]}, @"supported": @{…}}`；
/// 失败返回 nil，原因记在 `sysprobe_band_status()` 里。
///
/// 内部会把读回来的 `CTBandInfo` 对象按卡槽留一份 —— 写回时要用它。
/// **所以写之前必须先读**（见 `sysprobe_write_active_bands`）。
NSDictionary * _Nullable sysprobe_read_bands(int slot);

/// 把 `activeBands` 写回某个卡槽。只改 active，supported 原样带回去。
///
/// 必须先对**同一个 slot** 调用过 `sysprobe_read_bands`，否则返回 NO。
BOOL sysprobe_write_active_bands(int slot, NSDictionary *activeBands);

/// 恢复默认：把 active 整个换成 supported。
BOOL sysprobe_restore_default_bands(int slot);

/// 卡槽的只读状态，给频段页顶部那一段信息用。
///
/// **一次把能拿的都拿了。** 它本来就是「进页面刷一次」的语义，拆成七个函数只会让
/// 调用方写七次判空。拿不到的键**直接不出现**在字典里 —— 界面按「有没有这个键」
/// 决定那一行显不显示，而不是显示一个「(null)」。
///
/// 键（值都是 `NSString` 或 `NSNumber`）：
///
///   `carrierName`  运营商名称（取自运营商配置文件）
///   `networkName`  网络名称
///   `bars` / `maxBars`  信号格
///   `rat`          当前网络制式
///   `band`         服务小区的频段号
///   `pci`          物理小区 ID（`kCTCellMonitorPID`）
///   `tac`          跟踪区码（`kCTCellMonitorTAC`）
///   `lac`          位置区码。LTE/NR 下与 `tac` 同值（上游 CellularInfo 就是这么显示的），
///                  独立成一个键是为了让界面那一行的语义明确，不跟着制式改标题。
///   `cellId`       基站 ID（`kCTCellMonitorCellId`）
///   `rsrp` / `snr` 参考信号接收功率 / 信噪比
///
/// **会阻塞**：内部用信号量等 `copyCellInfo:` 那个异步回调，最长 1 秒。调用方要放到
/// 后台队列上（`BandService` 就是这么做的）。
NSDictionary * _Nullable sysprobe_slot_info(int slot);

/// 一次只取信号强度，不取小区信息。
///
/// **刻意不碰 `copyCellInfo`**：那个回调最坏要等 1 秒（见 `sysprobe_slot_info` 的说明），
/// 而这个函数是给**定时器轮询**用的 —— 2 秒一次地等一秒，会把调用方那条队列周期性压死。
/// 所以它只走挂在 `CTServiceDescriptor` 上的 `getSignalStrengthMeasurements:error:`，
/// 实测是毫秒级。
///
/// 返回 `@{@"rsrp": NSNumber, @"snr": NSNumber}`；读不到就返回**空字典**（不是 nil），
/// 调用方按「有没有这个键」判断，不用区分「读失败」和「没有这一项」。
///
/// `rsrp` 沿用 `sysprobe_slot_info` 的哨兵判据：**小于 0 才算有效**，0 是「没读到」。
NSDictionary * sysprobe_signal_sync(int slot);

/// 刷新蜂窝网络信号：让 modem 重载并重新注册。
///
/// 上游 CellularInfo 的「刷新蜂窝网络信号」就是这一句
///（`CoreTelephonyController.swift` 的 `refreshCellularConnection()`）：
///
///     _CTServerConnectionResetModem(connection, @"UserTriggeredReload")
///
/// 它**不是**杀掉 CommCenter（那是 `RootTool` 的 `restart-commcenter`，会连服务层一起重建）。
/// 这里只让基带重新加载，CommCenter 进程不动，恢复更快；代价同样是**掉网数秒**。
///
/// 两个符号都是 CoreTelephony 的私有 C 函数，本工程没有链接 CoreTelephony，所以走
/// `dlsym`（与文件里其它取数同一个套路）。无权限时 CommCenter 会**静默丢弃**请求 ——
/// 不报错、不抛异常 —— 所以本函数返回 YES 只代表「调用发出去了」，不代表真的刷了。
BOOL sysprobe_refresh_modem(void);

/// 这个卡槽插着卡吗。
///
/// 判据是「读到了运营商名或网络名」，**比「频段读得回来」严格**：频段配置是设备级的，
/// 没插卡也可能读得到；而运营商名只有真的有卡才有。
///
/// 刻意做得比 `sysprobe_slot_info` 轻：它不碰 `copyCellInfo` 那个要等最多 1 秒的回调。
/// 用途是决定「界面上要不要给出这个卡槽」—— 单卡设备上它必然失败一次，为了这件事让
/// 进页面多等一秒不划算。
BOOL sysprobe_slot_has_sim(int slot);

/// 当前「首选数据卡」的卡槽号；读不到返回 -1。
///
/// 用来决定频段页**一进来选哪张卡**。上游 CellularInfo 的规则是：
/// 卡 1 未启用而卡 2 启用就选卡 2，两张都启用就选首选数据卡。这里只提供后者的取值，
/// 判断在 `BandService` 里 —— 那边才知道「哪些卡槽确实插着卡」。
///
/// 走的是 `-getPreferredDataSubscriptionContextSync`（上游同款，返回的是**完整版**
/// context）。失败（无权限、无卡、iPad 无基带）返回 -1，调用方退回第一个可用卡槽。
int sysprobe_preferred_data_slot(void);

/// 上一次读写的状态。
SysProbeBandStatus sysprobe_band_status(void);

/// 现在是不是连着一个能用的 Wi-Fi 网络。
///
/// 判据是 `getifaddrs` 里 **`en0`（iOS 上唯一的 Wi-Fi 接口）拿到了一个可用地址**：
///
///   · IPv4，且不是 `169.254.0.0/16`（APIPA —— 「连上了 AP 但没拿到 DHCP 租约」）；
///   · 或 IPv6，且不是链路本地（`fe80::/10`）也不是回环。
///
/// 后一条不能少：Wi-Fi 开着但没连上任何 AP 时，`en0` 上正好只有一条链路本地地址。
///
/// 刻意**不用** `CNCopyCurrentNetworkInfo`（要定位权限）与 `SCNetworkReachability`
/// （要链 SystemConfiguration）—— 这里只需要「有没有连上」，两个都不划算。
///
/// **为什么放在这个文件里**：它是唯一同时被主 App 与 `BandRefreshDaemon` 编进去的
/// 实现文件（见 `scripts/build-ipa.sh` 里那条 clang 命令），而这条判据两边都要用、
/// 且两边必须逐条一致 —— 抄两份迟早走偏（与 `matches` 同一条理由）。
///
/// 用途：自动刷新信号的「连着 Wi-Fi 时暂停」前置开关。连着 Wi-Fi 时蜂窝不是唯一
/// 出路，这时重载 modem 只会白掉几秒网，还可能打断正在进行的 VoLTE 通话。
BOOL sysprobe_wifi_connected(void);

NS_ASSUME_NONNULL_END
