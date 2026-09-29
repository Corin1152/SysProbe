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
///   `rsrp` / `snr` 参考信号接收功率 / 信噪比
///
/// **会阻塞**：内部用信号量等 `copyCellInfo:` 那个异步回调，最长 1 秒。调用方要放到
/// 后台队列上（`BandService` 就是这么做的）。
NSDictionary * _Nullable sysprobe_slot_info(int slot);

/// 这个卡槽插着卡吗。
///
/// 判据是「读到了运营商名或网络名」，**比「频段读得回来」严格**：频段配置是设备级的，
/// 没插卡也可能读得到；而运营商名只有真的有卡才有。
///
/// 刻意做得比 `sysprobe_slot_info` 轻：它不碰 `copyCellInfo` 那个要等最多 1 秒的回调。
/// 用途是决定「界面上要不要给出这个卡槽」—— 单卡设备上它必然失败一次，为了这件事让
/// 进页面多等一秒不划算。
BOOL sysprobe_slot_has_sim(int slot);

/// 上一次读写的状态。
SysProbeBandStatus sysprobe_band_status(void);

NS_ASSUME_NONNULL_END
