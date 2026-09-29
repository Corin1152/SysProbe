//
//  CommCenterBridge.m
//  SysProbe
//
//  「频段设置」的取数与写入。
//
//  ══════════════════════════════════════════════════════════════════════════
//  为什么是运行时解析
//  ══════════════════════════════════════════════════════════════════════════
//
//  频段读写走 CoreTelephony 的私有 XPC 客户端 `CoreTelephonyClient`：
//
//      -[CoreTelephonyClient getBandInfo:error:]              -> CTBandInfo   (iOS 14+)
//      -[CoreTelephonyClient setActiveBandInfo:bands:error:]                  (iOS 14+)
//
//  这些在公开 SDK 里没有声明，而 SysProbe 也没有链接 CoreTelephony，所以框架得先
//  dlopen。全部按名字解析的好处是：类改名或方法消失时降级成「读不到」，而不是
//  链接失败或崩溃。同一个模式在本工程里已经有两处：`ChargeSpawn.c` 里的 persona
//  SPI，以及移植过来的 IOReport 那段。
//
//  ══════════════════════════════════════════════════════════════════════════
//  权限，以及它失败时是静默的
//  ══════════════════════════════════════════════════════════════════════════
//
//  调用被 `com.apple.CommCenter.fine-grained` 门住（见 Support/SysProbe.entitlements）。
//  没有它时 CommCenter 拒绝连接，方法返回 nil 加一个 error —— **不抛异常、不打日志**。
//  所以这里把状态记下来，由界面显示「不可用」并说清原因，而不是让用户对着一个
//  空列表发呆、反复点「刷新」。
//
//  ══════════════════════════════════════════════════════════════════════════
//  写回时只替换 active
//  ══════════════════════════════════════════════════════════════════════════
//
//  `CTBandInfo` 有两个字典：
//
//      fActiveBands      网络广播允许使用的频段   ← 可写
//      fSupportedBands   设备支持的频段           ← 只读，不碰
//
//  写回时从**读回来的那个对象**出发，只替换 `fActiveBands`。这样界面上不认识的
//  制式、以及 supported 里没有的项不会被意外删掉。所以每个卡槽读回来的对象要留着，
//  这也是「写之前必须先读」的原因。
//
//  参考：DevelopCubeLab/CellularInfo（GPL-3.0）的
//  `Controller/CoreTelephonyController.swift` —— 取数形状与它一致。署名见 NOTICE。
//

#import "CommCenterBridge.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static SysProbeBandStatus gStatus = SysProbeBandStatusUnknown;

static void *gCoreTelephonyHandle = NULL;
static BOOL gResolved = NO;
static id gClient = nil;

/// 每个卡槽最近一次读回来的 `CTBandInfo`。写回时用它，只替换 `fActiveBands`。
static NSMutableDictionary<NSNumber *, id> *gBandInfoBySlot = nil;

static id commCenterClient(void)
{
    if (gResolved) {
        return gClient;
    }
    gResolved = YES;

    // SysProbe 没链接 CoreTelephony，所以类在别的组件把它拉进来之前是不存在的。
    // dlopen 一次；失败就退回默认命名空间（也许已经被谁加载过了）。
    gCoreTelephonyHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
                                  RTLD_LAZY);
    if (gCoreTelephonyHandle == NULL) {
        gCoreTelephonyHandle = RTLD_DEFAULT;
    }

    Class clientClass = NSClassFromString(@"CoreTelephonyClient");
    if (clientClass != Nil) {
        @try {
            gClient = [[clientClass alloc] init];
        } @catch (NSException *e) {
            gClient = nil;
        }
    }
    return gClient;
}

/// `CTXPCServiceSubscriptionContext`，用 `-initWithSlot:` 造。
///
/// 注意这个类虽然叫 Context，但频段读写要的就是它 —— 上游也是直接
/// `CTXPCServiceSubscriptionContext(slot:)`。
static id subscriptionContext(int slot)
{
    Class contextClass = NSClassFromString(@"CTXPCServiceSubscriptionContext");
    if (contextClass == Nil) {
        return nil;
    }

    @try {
        id allocated = [contextClass alloc];
        SEL sel = NSSelectorFromString(@"initWithSlot:");
        if (![allocated respondsToSelector:sel]) {
            return nil;
        }
        // -(instancetype)initWithSlot:(int)slot;
        id (*send)(id, SEL, int) = (id (*)(id, SEL, int))objc_msgSend;
        return send(allocated, sel, slot);
    } @catch (NSException *e) {
        return nil;
    }
}

/// 读一次，成功返回 `CTBandInfo`，失败返回 nil 并把状态置为 unavailable。
static id bandInfoForSlot(int slot)
{
    id client = commCenterClient();
    if (client == nil) {
        gStatus = SysProbeBandStatusUnavailable;
        return nil;
    }

    id context = subscriptionContext(slot);
    if (context == nil) {
        gStatus = SysProbeBandStatusUnavailable;
        return nil;
    }

    SEL sel = NSSelectorFromString(@"getBandInfo:error:");
    if (![client respondsToSelector:sel]) {
        gStatus = SysProbeBandStatusUnavailable;
        return nil;
    }

    // -(CTBandInfo *)getBandInfo:(CTXPCServiceSubscriptionContext *)context error:(NSError **)error;
    id (*send)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
    NSError *error = nil;
    id bandInfo = nil;
    @try {
        bandInfo = send(client, sel, context, &error);
    } @catch (NSException *e) {
        bandInfo = nil;
    }

    if (bandInfo == nil || error != nil) {
        // 静默失败的那一种：没权限、无卡、或者基带服务正在重启。状态就是全部信息。
        gStatus = SysProbeBandStatusUnavailable;
        return nil;
    }

    gStatus = SysProbeBandStatusOK;
    return bandInfo;
}

/// 把 KVC 取出来的字典整理成 `@{制式: @[NSNumber 频段号, …]}`。
///
/// 上游是 `(bandInfo.fActiveBands as? [String: Any])`，然后按 `[NSNumber]` 解。
/// 这里做同样的收敛：不是数组的值直接丢掉，免得一个意外类型把整页带崩。
static NSDictionary *normalizeBands(id raw)
{
    if (![raw isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id key in (NSDictionary *)raw) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        id value = [(NSDictionary *)raw objectForKey:key];
        if (![value isKindOfClass:[NSArray class]]) {
            continue;
        }
        NSMutableArray *bands = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            if ([item isKindOfClass:[NSNumber class]]) {
                [bands addObject:item];
            }
        }
        out[key] = bands;
    }
    return out;
}

NSDictionary * _Nullable sysprobe_read_bands(int slot)
{
    @autoreleasepool {
        id bandInfo = bandInfoForSlot(slot);
        if (bandInfo == nil) {
            return nil;
        }

        NSDictionary *active = nil;
        NSDictionary *supported = nil;
        @try {
            active = normalizeBands([bandInfo valueForKey:@"fActiveBands"]);
            supported = normalizeBands([bandInfo valueForKey:@"fSupportedBands"]);
        } @catch (NSException *e) {
            gStatus = SysProbeBandStatusUnavailable;
            return nil;
        }

        if (gBandInfoBySlot == nil) {
            gBandInfoBySlot = [NSMutableDictionary dictionary];
        }
        gBandInfoBySlot[@(slot)] = bandInfo;

        return @{ @"active": active, @"supported": supported };
    }
}

/// 把 `activeBands` 灌进留着的那个 `CTBandInfo` 并写回。
///
/// `useSupported` 为真时走「恢复默认」那条路：active 整个换成 supported。
static BOOL writeBands(int slot, NSDictionary *activeBands, BOOL useSupported)
{
    @autoreleasepool {
        id bandInfo = gBandInfoBySlot[@(slot)];
        if (bandInfo == nil) {
            // 没读过就没有可写的对象 —— 上游也是从读回来的对象出发改的。
            gStatus = SysProbeBandStatusUnavailable;
            return NO;
        }

        id client = commCenterClient();
        id context = subscriptionContext(slot);
        SEL sel = NSSelectorFromString(@"setActiveBandInfo:bands:error:");
        if (client == nil || context == nil || ![client respondsToSelector:sel]) {
            gStatus = SysProbeBandStatusUnavailable;
            return NO;
        }

        @try {
            if (useSupported) {
                id supported = [bandInfo valueForKey:@"fSupportedBands"];
                if (supported == nil) {
                    gStatus = SysProbeBandStatusUnavailable;
                    return NO;
                }
                // 深拷一份：直接把手里的对象塞回去，等于把 active 和 supported 变成同一个引用。
                [bandInfo setValue:[supported mutableCopy] forKey:@"fActiveBands"];
            } else {
                NSMutableDictionary *updated = [NSMutableDictionary dictionary];
                for (id key in activeBands) {
                    id value = activeBands[key];
                    if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSArray class]]) {
                        updated[key] = [value mutableCopy];
                    }
                }
                [bandInfo setValue:updated forKey:@"fActiveBands"];
            }
        } @catch (NSException *e) {
            gStatus = SysProbeBandStatusUnavailable;
            return NO;
        }

        // -(void)setActiveBandInfo:(CTXPCServiceSubscriptionContext *)context
        //                    bands:(CTBandInfo *)bands
        //                    error:(NSError **)error;
        //
        // 注意返回 void、错误只从 error 出 —— 不接住就等于把失败静默吞掉，
        // 用户会以为改了、其实没改。
        void (*send)(id, SEL, id, id, NSError **) = (void (*)(id, SEL, id, id, NSError **))objc_msgSend;
        NSError *error = nil;
        @try {
            send(client, sel, context, bandInfo, &error);
        } @catch (NSException *e) {
            gStatus = SysProbeBandStatusUnavailable;
            return NO;
        }

        if (error != nil) {
            gStatus = SysProbeBandStatusUnavailable;
            return NO;
        }

        gStatus = SysProbeBandStatusOK;
        return YES;
    }
}

BOOL sysprobe_write_active_bands(int slot, NSDictionary *activeBands)
{
    return writeBands(slot, activeBands, NO);
}

BOOL sysprobe_restore_default_bands(int slot)
{
    return writeBands(slot, @{}, YES);
}

// MARK: - 只读状态（频段页顶部那一段）

/// `CTServiceDescriptor`。
///
/// `getCurrentRat:` 与 `getSignalStrengthMeasurements:` 要的都是它，不是 context ——
/// 两个类名字很像，传错的那个不会报错，只会静默返回 nil。
static id serviceDescriptor(int slot)
{
    Class descriptorClass = NSClassFromString(@"CTServiceDescriptor");
    if (descriptorClass == Nil) {
        return nil;
    }
    @try {
        id allocated = [descriptorClass alloc];
        SEL sel = NSSelectorFromString(@"initWithDomain:instance:");
        if (![allocated respondsToSelector:sel]) {
            return nil;
        }
        // -(id)initWithDomain:(long long)domain instance:(NSNumber *)instance;
        id (*send)(id, SEL, long long, id) = (id (*)(id, SEL, long long, id))objc_msgSend;
        return send(allocated, sel, 1LL, @(slot));
    } @catch (NSException *e) {
        return nil;
    }
}

/// 服务小区的频段号。
///
/// `copyCellInfo:completion:` **只有异步版本**，所以这里用信号量把它等成同步的。
/// 调用方在后台队列上（`BandService`），等的是那条队列，不是主线程。
///
/// 超时（1 秒）就当没有：基带服务正在重启时这个回调可能一直不来，而这一行只是
/// 「参考信息」，不值得让整页卡住。
static NSNumber *servingBand(id client, id context)
{
    SEL sel = NSSelectorFromString(@"copyCellInfo:completion:");
    if (![client respondsToSelector:sel]) {
        return nil;
    }

    __block id cellInfo = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    void (^completion)(id, id) = ^(id info, id error) {
        cellInfo = info;
        dispatch_semaphore_signal(semaphore);
    };

    void (*send)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
    @try {
        send(client, sel, context, completion);
    } @catch (NSException *e) {
        return nil;
    }

    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC)) != 0) {
        return nil;
    }

    NSArray *cells = [cellInfo valueForKey:@"legacyInfo"];
    if (![cells isKindOfClass:[NSArray class]] || cells.count == 0) {
        return nil;
    }

    // 优先服务小区；没有标记就退回第一条。
    NSDictionary *serving = nil;
    for (id cell in cells) {
        if (![cell isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        if ([[cell objectForKey:@"kCTCellMonitorCellType"] isEqual:@"kCTCellMonitorCellTypeServing"]) {
            serving = cell;
            break;
        }
    }
    if (serving == nil) {
        serving = [cells firstObject];
    }

    id band = [serving objectForKey:@"kCTCellMonitorBandInfo"];
    return [band isKindOfClass:[NSNumber class]] ? band : nil;
}

/// 运营商配置文件里的 `CarrierName`。读不到返回 nil。
static NSString *carrierName(id client, id context)
{
    SEL sel = NSSelectorFromString(@"context:getCarrierBundleValue:error:");
    if (![client respondsToSelector:sel]) {
        return nil;
    }
    id (*send)(id, SEL, id, id, NSError **) = (id (*)(id, SEL, id, id, NSError **))objc_msgSend;
    NSError *error = nil;
    id value = nil;
    @try {
        value = send(client, sel, context, @[@"CarrierName"], &error);
    } @catch (NSException *e) {
        value = nil;
    }
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return value;
    }
    return nil;
}

/// 网络名称。读不到返回 nil。
static NSString *networkName(id client, id context)
{
    SEL sel = NSSelectorFromString(@"getLocalizedOperatorName:error:");
    if (![client respondsToSelector:sel]) {
        return nil;
    }
    id (*send)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
    NSError *error = nil;
    id value = nil;
    @try {
        value = send(client, sel, context, &error);
    } @catch (NSException *e) {
        value = nil;
    }
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return value;
    }
    return nil;
}

BOOL sysprobe_slot_has_sim(int slot)
{
    @autoreleasepool {
        id client = commCenterClient();
        id context = subscriptionContext(slot);
        if (client == nil || context == nil) {
            return NO;
        }
        // **刻意只查这两个字符串，不碰 `copyCellInfo`。**
        //
        // 这个函数的作用是回答「要不要在界面上给出这个卡槽」—— 在单卡设备上它必然
        // 会失败一次，而 `sysprobe_slot_info` 里那步 `copyCellInfo` 失败要等满 1 秒。
        // 为了判断一个卡槽存不存在而让进页面多等一秒，不划算。
        //
        // 判据也刻意比「频段读得回来」严格：频段配置是设备级的，没插卡也可能读得到，
        // 而运营商名只有真的有卡才有。
        return carrierName(client, context) != nil || networkName(client, context) != nil;
    }
}

NSDictionary * _Nullable sysprobe_slot_info(int slot)
{
    @autoreleasepool {
        // 空字典而不是 nil：调用方按「有没有这个键」决定那一行显不显示，
        // 一个 nil 会让它去区分「读失败」和「没有这一项」两件事，而这里没这个区别。
        NSMutableDictionary *info = [NSMutableDictionary dictionary];

        id client = commCenterClient();
        id context = subscriptionContext(slot);
        if (client == nil || context == nil) {
            return info;
        }

        NSString *carrier = carrierName(client, context);
        if (carrier != nil) {
            info[@"carrierName"] = carrier;
        }
        NSString *network = networkName(client, context);
        if (network != nil) {
            info[@"networkName"] = network;
        }

        // 信号格。
        SEL barsSel = NSSelectorFromString(@"getSignalStrengthInfo:error:");
        if ([client respondsToSelector:barsSel]) {
            id (*send)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
            NSError *error = nil;
            id strength = nil;
            @try {
                strength = send(client, barsSel, context, &error);
            } @catch (NSException *e) {
                strength = nil;
            }
            if (strength != nil) {
                NSNumber *bars = [strength valueForKey:@"displayBars"];
                NSNumber *maxBars = [strength valueForKey:@"maxDisplayBars"];
                if ([bars isKindOfClass:[NSNumber class]]) {
                    info[@"bars"] = bars;
                }
                if ([maxBars isKindOfClass:[NSNumber class]]) {
                    info[@"maxBars"] = maxBars;
                }
            }
        }

        // 制式与 RSRP/SNR 都挂在 descriptor 上（不是 context）。
        id descriptor = serviceDescriptor(slot);
        if (descriptor != nil) {
            SEL ratSel = NSSelectorFromString(@"getCurrentRat:error:");
            if ([client respondsToSelector:ratSel]) {
                id (*send)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
                NSError *error = nil;
                id value = nil;
                @try {
                    value = send(client, ratSel, descriptor, &error);
                } @catch (NSException *e) {
                    value = nil;
                }
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                    info[@"rat"] = value;
                }
            }

            SEL measurementsSel = NSSelectorFromString(@"getSignalStrengthMeasurements:error:");
            if ([client respondsToSelector:measurementsSel]) {
                id (*send)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
                NSError *error = nil;
                id measurements = nil;
                @try {
                    measurements = send(client, measurementsSel, descriptor, &error);
                } @catch (NSException *e) {
                    measurements = nil;
                }
                if (measurements != nil) {
                    NSNumber *rsrp = [measurements valueForKey:@"rsrp"];
                    NSNumber *snr = [measurements valueForKey:@"snr"];
                    // RSRP 恒为负；0 是「没读到」的哨兵值。
                    if ([rsrp isKindOfClass:[NSNumber class]] && rsrp.integerValue < 0) {
                        info[@"rsrp"] = rsrp;
                    }
                    if ([snr isKindOfClass:[NSNumber class]]) {
                        info[@"snr"] = snr;
                    }
                }
            }
        }

        // 服务小区频段。放最后：它是唯一一个可能等满 1 秒的调用。
        NSNumber *band = servingBand(client, context);
        if (band != nil && band.integerValue > 0) {
            info[@"band"] = band;
        }

        return info;
    }
}

SysProbeBandStatus sysprobe_band_status(void)
{
    return gStatus;
}
