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

#import <CoreFoundation/CoreFoundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/socket.h>

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

/// `CTXPCServiceSubscriptionContext`。
///
/// **优先用「完整版」context**：`-getSubscriptionInfoWithError:` 回来的订阅列表里
/// 按 `slotID` 匹配一个；拿不到才退回 `-initWithSlot:` 造的简化 context。
///
/// 上游 CellularInfo 的取法是 `fullyContext ?? context`，并在注释里写明
/// `initWithSlot:` 造出来的「内部信息不全」。第一版这里只用了简化版，真机表现是
/// **能读、但保存不生效** —— 读走的是 slot 就够用的那条路，写要精确定位订阅，
/// 简化 context 缺 uuid 等字段就定位不到。改这段时别把完整版那条去掉。
static id subscriptionContext(int slot)
{
    Class contextClass = NSClassFromString(@"CTXPCServiceSubscriptionContext");
    if (contextClass == Nil) {
        return nil;
    }

    // 完整版。方法名是 `getSubscriptionInfoWithError:`（Swift 侧写作
    // `try getSubscriptionInfo()`，`WithError:` 后缀被 importer 吃掉了）。
    id client = commCenterClient();
    if (client != nil) {
        SEL infoSel = NSSelectorFromString(@"getSubscriptionInfoWithError:");
        if ([client respondsToSelector:infoSel]) {
            @try {
                id (*send)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
                NSError *error = nil;
                id info = send(client, infoSel, &error);
                id subs = [info valueForKey:@"subscriptions"];
                if ([subs isKindOfClass:[NSArray class]]) {
                    for (id sub in (NSArray *)subs) {
                        // slotID 在头文件里是 long long，KVC 取出来是 NSNumber。
                        NSNumber *slotID = [sub valueForKey:@"slotID"];
                        if ([slotID isKindOfClass:[NSNumber class]] && slotID.intValue == slot) {
                            return sub;
                        }
                    }
                }
            } @catch (NSException *e) {
                // 落到下面的兜底。
            }
        }
    }

    // 兜底：只有 slot 字段的简化 context。读还能用，写大概率不行。
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
                // **从原对象的 `fActiveBands` 起手再覆盖，不是新建一个空字典。**
                //
                // 传进来的 `activeBands` 只含 `supported` 里出现过的制式（见
                // `BandSet.payload`）。直接拿它替换整个 `fActiveBands`，会把原集合里
                // 那些「界面上不认识、或不在 supported 里」的键**整个删掉** ——
                // 上游 CellularInfo 特意用 `mutableCopy` 起手就是为了避开这一点
                // （它的注释：这样 UI 不认识的 RAT 或 SupportedBands 中不存在的内容
                // 才不会被意外删除）。这里第一版写反了，真机表现是**保存不生效**。
                NSMutableDictionary *updated = nil;
                @try {
                    id existing = [bandInfo valueForKey:@"fActiveBands"];
                    updated = [existing isKindOfClass:[NSDictionary class]]
                        ? [(NSDictionary *)existing mutableCopy]
                        : [NSMutableDictionary dictionary];
                } @catch (NSException *e) {
                    updated = [NSMutableDictionary dictionary];
                }
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

/// 服务小区的那几个标识：频段号、PCI、TAC、基站 ID。
///
/// `copyCellInfo:completion:` **只有异步版本**，所以这里用信号量把它等成同步的。
/// 调用方在后台队列上（`BandService`），等的是那条队列，不是主线程。
///
/// 超时（1 秒）就当没有：基带服务正在重启时这个回调可能一直不来，而这一行只是
/// 「参考信息」，不值得让整页卡住。
///
/// 返回字典，缺哪一项就不放那一个键。调用方按「有没有键」决定那一行显不显示。
///
/// 键名取自上游 CellularInfo（`Controller/CoreTelephonyController.swift` 里那一串
/// `kCTCellMonitor*` 注释）：
///
///   kCTCellMonitorBandInfo   频段号
///   kCTCellMonitorPID        物理小区 ID（PCI）
///   kCTCellMonitorTAC        跟踪区码（LTE/NR；2G/3G 那一栏它叫 LAC）
///   kCTCellMonitorCellId     基站 ID
static NSDictionary *servingCellFields(id client, id context)
{
    SEL sel = NSSelectorFromString(@"copyCellInfo:completion:");
    if (![client respondsToSelector:sel]) {
        return @{};
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
        return @{};
    }

    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC)) != 0) {
        return @{};
    }

    NSArray *cells = [cellInfo valueForKey:@"legacyInfo"];
    if (![cells isKindOfClass:[NSArray class]] || cells.count == 0) {
        return @{};
    }

    // 优先服务小区；没有标记就退回第一条。
    //
    // ── 2026-10-17：在多个「服务小区」里**优先挑 PCI 有效的那个** ─────────────
    //
    // 5G NSA 下 `legacyInfo` 里会同时出现 LTE 锚点小区与 NR 小区，两条都带
    // `kCTCellMonitorCellTypeServing`。原来只取**第一条**标记为 serving 的 —— 如果
    // 那条是 NR，而这一版 iOS 的 CommCenter 没给 NR 填 PID（填 0），整组字段就都
    // 来自那个「半空」的小区，界面上的物理小区 ID 于是显示 0。
    //
    // 现在按「PID > 0」挑：有有效 PCI 的那条 serving 优先。挑不到就退回第一条
    // serving（PCI 那一项由下面的 `put` 判掉，不显示 0）。
    //
    // **一组字段必须来自同一条小区**：混着取会让「频段来自 LTE、PCI 来自 NR」这种
    // 组合出现，比缺一项更误导人。所以这里只决定「用哪一条」，四项一起从它取。
    NSDictionary *serving = nil;
    NSDictionary *firstServing = nil;
    for (id cell in cells) {
        if (![cell isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        if (![[cell objectForKey:@"kCTCellMonitorCellType"] isEqual:@"kCTCellMonitorCellTypeServing"]) {
            continue;
        }
        if (firstServing == nil) {
            firstServing = cell;
        }
        NSNumber *pid = [(NSDictionary *)cell objectForKey:@"kCTCellMonitorPID"];
        if ([pid isKindOfClass:[NSNumber class]] && pid.integerValue > 0) {
            serving = cell;
            break;
        }
    }
    if (serving == nil) {
        serving = firstServing ?: [cells firstObject];
    }
    if (![serving isKindOfClass:[NSDictionary class]]) {
        return @{};
    }

    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    // 值一律取 `NSNumber`。上游对这些键的取值也都是 `as? NSNumber` —— 字典里放的是
    // 数字而不是字符串，所以按 NSNumber 收；其它类型一律当没读到，不猜。
    void (^put)(NSString *, NSString *) = ^(NSString *outKey, NSString *cellKey) {
        id value = [serving objectForKey:cellKey];
        if ([value isKindOfClass:[NSNumber class]]) {
            fields[outKey] = value;
        }
    };
    put(@"band", @"kCTCellMonitorBandInfo");
    put(@"pci", @"kCTCellMonitorPID");
    put(@"tac", @"kCTCellMonitorTAC");
    put(@"cellId", @"kCTCellMonitorCellId");

    // ── 2026-10-17：PCI 为 0 一律当「没读到」──────────────────────────────────
    //
    // 真机上这一格会**不定时**蹦出 0：小区切换 / 测量间隙的窗口里基带把 PID 填成
    // 0，NSA 下的 NR 小区也可能一直是 0。PCI 的定义虽允许 0，但一个真实服务小区
    // 恰好是 0 的概率极低；而这个页面只要显示出一个数字，就会被当成真数据。
    //
    // 所以丢掉它 —— 界面那一行随之整行不显示（与 TAC / Cell ID 缺值时同一套规则），
    // 一个轮询周期后读到真值再出现。
    NSNumber *pci = fields[@"pci"];
    if ([pci isKindOfClass:[NSNumber class]] && pci.integerValue <= 0) {
        [fields removeObjectForKey:@"pci"];
    }
    return fields;
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

int sysprobe_preferred_data_slot(void)
{
    @autoreleasepool {
        id client = commCenterClient();
        if (client == nil) {
            return -1;
        }
        // -(CTXPCServiceSubscriptionContext *)getPreferredDataSubscriptionContextSync:(NSError **)error;
        // 上游注释：「获取的 context 信息是全的」。返回 -1 让调用方自己退回首卡槽。
        SEL sel = NSSelectorFromString(@"getPreferredDataSubscriptionContextSync:");
        if (![client respondsToSelector:sel]) {
            return -1;
        }
        id (*send)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
        NSError *error = nil;
        id context = nil;
        @try {
            context = send(client, sel, &error);
        } @catch (NSException *e) {
            return -1;
        }
        if (context == nil || error != nil) {
            return -1;
        }
        NSNumber *slotID = [context valueForKey:@"slotID"];
        if (![slotID isKindOfClass:[NSNumber class]]) {
            return -1;
        }
        int slot = slotID.intValue;
        // 只认 1 / 2：KVC 拿到 0 或越界值说明读回来的东西不对，退回首卡槽更安全。
        return (slot == 1 || slot == 2) ? slot : -1;
    }
}

NSDictionary * _Nullable sysprobe_slot_info(int slot)
{    @autoreleasepool {
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

        // 服务小区那一组标识。放最后：它是唯一一个可能等满 1 秒的调用。
        //
        // 一次 `copyCellInfo` 把频段 / PCI / TAC / 基站 ID 全取回来 —— 它们本来就在
        // 同一个服务小区字典里，分开取等于多等几次 1 秒。
        NSDictionary *cellFields = servingCellFields(client, context);
        NSNumber *band = [cellFields objectForKey:@"band"];
        if ([band isKindOfClass:[NSNumber class]] && band.integerValue > 0) {
            info[@"band"] = band;
        }
        NSNumber *pci = [cellFields objectForKey:@"pci"];
        if ([pci isKindOfClass:[NSNumber class]] && pci.integerValue >= 0) {
            info[@"pci"] = pci;
        }
        NSNumber *tac = [cellFields objectForKey:@"tac"];
        if ([tac isKindOfClass:[NSNumber class]] && tac.integerValue > 0) {
            info[@"tac"] = tac;
            // LTE/NR 的位置区码就是跟踪区码 —— 上游 CellularInfo 在 4G/5G 下也是
            // 直接把 TAC 显示在 LAC 那一栏。2G/3G 时 `kCTCellMonitorTAC` 读不到，
            // 界面那一栏于是整行不显示（见 `BandPanels`）。
            info[@"lac"] = tac;
        }
        NSNumber *cellId = [cellFields objectForKey:@"cellId"];
        if ([cellId isKindOfClass:[NSNumber class]] && cellId.integerValue > 0) {
            info[@"cellId"] = cellId;
        }

        return info;
    }
}

NSDictionary * sysprobe_signal_sync(int slot)
{
    @autoreleasepool {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];

        id client = commCenterClient();
        if (client == nil) {
            return info;
        }
        // 信号挂在 descriptor 上，不在 context 上 —— 与 `sysprobe_slot_info` 同一条路。
        id descriptor = serviceDescriptor(slot);
        if (descriptor == nil) {
            return info;
        }

        SEL sel = NSSelectorFromString(@"getSignalStrengthMeasurements:error:");
        if (![client respondsToSelector:sel]) {
            return info;
        }
        id (*send)(id, SEL, id, NSError **) = (id (*)(id, SEL, id, NSError **))objc_msgSend;
        NSError *error = nil;
        id measurements = nil;
        @try {
            measurements = send(client, sel, descriptor, &error);
        } @catch (NSException *e) {
            measurements = nil;
        }
        if (measurements == nil) {
            return info;
        }

        NSNumber *rsrp = [measurements valueForKey:@"rsrp"];
        NSNumber *snr = [measurements valueForKey:@"snr"];
        // 哨兵判据与 `sysprobe_slot_info` 一致：**小于 0 才算真的读到了**。
        // 少了这一句，0 会被当成「信号极好」，判定逻辑整个反过来。
        if ([rsrp isKindOfClass:[NSNumber class]] && rsrp.integerValue < 0) {
            info[@"rsrp"] = rsrp;
        }
        if ([snr isKindOfClass:[NSNumber class]]) {
            info[@"snr"] = snr;
        }
        return info;
    }
}

BOOL sysprobe_refresh_modem(void)
{
    @autoreleasepool {
        // 先走一遍客户端初始化：CoreTelephony 的 dlopen 就是它在做的，
        // 下面两个 dlsym 要的是同一个 handle。
        (void)commCenterClient();
        void *handle = gCoreTelephonyHandle != NULL ? gCoreTelephonyHandle : RTLD_DEFAULT;
        if (handle == NULL) {
            return NO;
        }

        // CTServerConnectionRef 在本工程里没有类型定义（`CTServerConnection` 是私有的
        // 结构体），用 `void *` 接 —— 它只是被传给下面那个函数，不解引用。
        void *(*create)(void *, void *, void *) =
            (void *(*)(void *, void *, void *))dlsym(handle, "_CTServerConnectionCreate");
        void (*resetModem)(void *, CFStringRef) =
            (void (*)(void *, CFStringRef))dlsym(handle, "_CTServerConnectionResetModem");

        // 上游对这两个符号是直接 extern 声明后链接的；这里没链接框架，只能 dlsym，
        // 所以「符号不存在」必须自己挡掉 —— 挡掉之后是「什么都不做」，不是崩。
        if (create == NULL || resetModem == NULL) {
            return NO;
        }

        // 上游的调用方式：`_CTServerConnectionCreate(kCFAllocatorDefault, nil, nil)`。
        // 第一个参数虽然在原型里是 allocator，但这里刻意传 NULL —— 与上游逐字一致。
        void *connection = create(NULL, NULL, NULL);
        if (connection == NULL) {
            return NO;
        }

        // reason 字符串沿用上游的 "UserTriggeredReload"。
        @try {
            resetModem(connection, CFSTR("UserTriggeredReload"));
        } @catch (NSException *e) {
            return NO;
        }

        // 无权限时 CommCenter 会静默丢弃请求 —— 不报错也不抛异常。所以这里返回 YES
        // 只代表「调用发出去了」，不代表 modem 真的重载了。判定要靠前后 RSRP 的变化。
        return YES;
    }
}

SysProbeBandStatus sysprobe_band_status(void)
{
    return gStatus;
}

#pragma mark - Wi-Fi 判据

/// Wi-Fi 接口名。
///
/// iOS 上只有一个 `en0`。蜂窝是 `pdp_ip0`，虚拟隧道是 `utun*`，AirDrop 的 `awdl0`
/// 也不能算 —— 而它们的地址同样是「up 且有地址」，所以必须按名字筛，不能只看有没有地址。
/// （`NetworkKind` 那边用的是同一条规则，见 `Sources/Shared/Hardware/HardwareMonitor.swift`。）
static const char *const kWiFiInterfaceName = "en0";

BOOL sysprobe_wifi_connected(void)
{
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return NO;
    }

    BOOL connected = NO;
    for (struct ifaddrs *ifa = interfaces; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_name == NULL) { continue; }
        if ((ifa->ifa_flags & IFF_UP) == 0) { continue; }
        if (strcmp(ifa->ifa_name, kWiFiInterfaceName) != 0) { continue; }

        if (ifa->ifa_addr->sa_family == AF_INET) {
            const struct sockaddr_in *v4 = (const struct sockaddr_in *)ifa->ifa_addr;
            uint32_t address = ntohl(v4->sin_addr.s_addr);
            // 169.254.0.0/16 是 APIPA：连上了 AP 但没拿到 DHCP 租约。那种状态下
            // 「连着 Wi-Fi」只是名义上的，蜂窝仍然是唯一出路 —— 与系统自己那句
            // 「Wi-Fi 无互联网连接」同向，所以这里不算连接。
            if (address != 0 && (address & 0xFFFF0000u) != 0xA9FE0000u) {
                connected = YES;
                break;
            }
        } else if (ifa->ifa_addr->sa_family == AF_INET6) {
            const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)ifa->ifa_addr;
            // 链路本地（fe80::/10）必须排除：**Wi-Fi 开着但没连上任何 AP 时，
            // `en0` 上恰好就只剩这一条地址** —— 少了这一句，判据会恒为真，
            // 于是「连着 Wi-Fi 就暂停」这个开关会把自动刷新永久停掉。
            if (!IN6_IS_ADDR_LINKLOCAL(&v6->sin6_addr) &&
                !IN6_IS_ADDR_LOOPBACK(&v6->sin6_addr)) {
                connected = YES;
                break;
            }
        }
    }

    freeifaddrs(interfaces);
    return connected;
}
