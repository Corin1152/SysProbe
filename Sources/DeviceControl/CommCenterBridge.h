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

/// 上一次读写的状态。
SysProbeBandStatus sysprobe_band_status(void);

NS_ASSUME_NONNULL_END
