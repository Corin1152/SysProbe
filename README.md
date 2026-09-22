# SysProbe

iPhone 硬件信息 + 充电功率/适配器读数工具。三屏结构：

| 屏 | 内容 |
|---|---|
| **Hardware** | CPU（型号/核心数/主频/实时占用/每核负载）、内存（分项占用 + 优化）、存储、网络（连着 Wi-Fi 就看 Wi-Fi，断了才显示蜂窝）、系统版本 |
| **Power** | 充电功率大环、电芯电压/电流/温度、供电路径与转换效率、本次充电累计 |
| **Adapter** | 适配器实际/额定功率、握手信息、广播供电规格（PDO）、实时供电轨、通路电阻 |

外加一个**负一屏 Today Extension**，1 秒刷新，展示功率与适配器读数。

三屏右上角各有一个齿轮，进入同一个设置页（界面语言、充电时保持常亮、电池能量估算、
诊断信息、致谢）。入口与面板都挂在视图树的根上，不归任何一页所有 —— 面板挂在分页里的话，
切语言时整棵树换 identity，会把面板连同自己一起关掉。

## 安装

未签名构建，安装时用你自己的凭证签名：

- **巨魔（TrollStore）**：直接把 ipa 拖进去装
- AltStore / SideStore / Sideloadly / Xcode 均可

需要 iPhone，iOS 16.2 或更高。

## 图标

蓝底白齿轮，配色取自参考图（`#6E97FD` → `#4574F5` 的极轻竖向渐变，中间调 `#4C7CF8`），
造型走 iOS 16 设置图标那一路：厚实的梯形齿、圆角齿顶与齿根圆角、明显的中孔。

素材是**脚本生成**的，不是手工画的位图 —— 改配色或改齿轮比例只要动
`scripts/make-appicon.py` 顶部的常量，然后重跑：

```bash
python scripts/make-appicon.py Sources/App/Assets.xcassets/AppIcon.appiconset
```

它会写出 9 张 PNG（20/29/40/60 的 @2x@3x + 1024 marketing）和 `Contents.json`。
想顺手出一张带圆角的主屏效果图，再加第二个参数给个输出路径即可。

两个容易踩的点：主图是**满幅正方形、不带圆角、不带 alpha**（圆角由系统裁），
以及 `project.yml` 里的 `ASSETCATALOG_COMPILER_APPICON_NAME` 必须设 —— 不设的话
catalog 照编，但图标不会写进 `Info.plist`，装上去就是个白方块，构建一声不吭。

## 为什么只能侧载

Power 与 Adapter 两屏的读数来自 Apple 的**私有 IOKit 接口**（`AppleSmartBattery`、
`IOPSCopyExternalPowerAdapterDetails`、`HID` 传感器服务等）。全部是只读访问，
没有任何写入，也不需要任何私有 entitlement —— 但私有 API 意味着它**永远无法通过
App Store 审核**。

## 负一屏为什么能 1 秒刷新

用的是**传统 Today Extension**（`com.apple.widget-extension`），不是 WidgetKit。

传统扩展是真正被加载进负一屏的视图控制器，只要负一屏可见，进程就活着，于是可以按
自己的节奏（1 秒）重读数据并刷新 —— 不受 WidgetKit「时间线预算、最快约 5 分钟」的
限制。代价是滑走或锁屏后扩展被挂起，刷新停止，此时由 `widgetPerformUpdate` 提供快照。

传统扩展自 iOS 14 起被标记废弃、iOS 18 起被移除。**iPhone X 的系统封顶就是 iOS 16.x**，
所以在这个目标上不存在保质期问题。

### 会让它显示「无法载入」的几种原因

都是**静默**的：构建全绿、界面正常安装，只有真机上才看得出来。CI 里有断言卡住其中几条。

**按验证成本从低到高排**，别凭直觉挑一个最显眼的差异当根因 —— 我在这上面连续判断错过
两次（先怪 principal class 与 NotificationCenter 分类，再怪 SwiftUI 运行时），两次都
不是根因。

- **启动路径上不能有 IO。** 传统扩展的内存预算与启动 watchdog 都远小于主 App。
  `PowerMonitor` 这类对象的构造会 `dlopen` 框架、枚举 IOKit 服务、读文件系统 ——
  在主 App 里是几十毫秒，在扩展里就可能被 watchdog 掐掉。现在 `viewDidLoad` 只做三件
  不可能失败的事（落一次语言、设背景色、挂一个占位标签），真正的内容全部推迟到
  `viewDidAppear`；属性初始化也一并去掉了 —— 那段跑在 `viewDidLoad` **之前**，
  同属启动路径。**占位文字「正在读取传感器…」能看到，就说明扩展加载成功了**，
  问题在内容那一侧。
- **`NSExtensionPrincipalClass` 必须是显式的 ObjC 类名。** 写成「模块名.类名」
  （`TodayExtension.TodayViewController`）要靠模块名在运行期被解析成类，解析不到就找不到
  类 —— 负一屏显示「无法载入」。现在 `TodayViewController` 标了
  `@objc(SysProbeTodayViewController)`，plist 里用同一个裸名字，逐字注册进 ObjC 运行时。
- **`widgetLargestAvailableDisplayMode` 需要 `NotificationCenter.framework` 在场。**
  那个属性是 `NSExtensionContext` 的一个分类方法，实现在 NotificationCenter 里；而
  iOS 26 SDK 把它的声明并进了 UIKit —— 于是 Swift 调用它只生成 `objc_msgSend`、
  **不产生任何链接依赖**，链接器就把那个库当「没被用到」丢掉了（`-dead_strip_dylibs`；
  本工程的 appex 正是这么丢掉 `Charts.framework` 的）。库不在，分类就没注册，直接调就是
  `unrecognized selector`：扩展在 `viewDidLoad` 里当场崩掉，负一屏显示「无法载入」。
  修法是先把框架 `dlopen` 进来（分类随之注册），再先探响应性、后走 `method(for:)` 调用 ——
  选择器不在就安静跳过，退回收起态但内容照常显示，不会崩。能正常显示的 CPU-X，它的 appex
  是链了 NotificationCenter 的，而且根本不调这个 API。

- **扩展注册缓存。** iOS 会缓存已安装扩展的元数据，**覆盖安装不会刷新它**。
  完全卸载 App → 重启设备 → 重装。这一步成本很低，值得先做。
- **签名。** 未签名 IPA 由 TrollStore 自签。能正常工作的参照（CPU-X）其 appex 二进制
  里**有** `LC_CODE_SIGNATURE`，完全未签名的**没有**。如果前几条都排除后仍失败，
  下一步是给 appex 加 ad-hoc 签名，让产物结构与参照一致。

另外，这一屏也刻意**不用 SwiftUI**：appex 里带 SwiftUI 运行时会让 dyld 把
`SwiftUI.framework` 映射进来（几十 MB），而扩展的预算远小于主 App。取数层
`Shared/Power` 因此去掉了 `LocalizedStringKey`（改用 `Strings.text` 直接返回 `String`，
译文来源是同一份 `.lproj`）。**但它不是「无法载入」的充分原因** —— 把它脱干净之后
（链接列表里没有 SwiftUI、未定义符号 0 个），装上去照样失败。别把它当终点。

### 点一下打开主 App

负一屏上点任意位置都会打开主 App，做法与 CPU-X 一致：

- 主 App 注册一个自定义 URL scheme（`sysprobe`，见 `Support/SysProbe-Info.plist` 的
  `CFBundleURLTypes`）。CPU-X 注册的是 `armcpuz`。这是个数组，`INFOPLIST_KEY_*` 表达
  不了，所以和 `UILaunchScreen` 一样落在局部 plist 里。
- 组件上挂一个 `UITapGestureRecognizer`，走
  `extensionContext?.open(URL(string: "sysprobe://open")!, completionHandler: nil)`
  —— 扩展里没有 `UIApplication`（那个 API 在 appex 上编译就过不去），
  `extensionContext` 是唯一能唤起居主 App 的通道。
- 主 App 侧 `.onOpenURL` 只把设置面板收起来；分页不重置，停在用户上次看的那一屏。

CI 有两条断言卡住「静默失败」：主 App 必须注册了 `sysprobe`，且 appex 的源码里真的
构造了那个 URL。缺任何一半都是点上去没反应、也没有任何报错。

## 语言

设置页可以在 English / 简体中文 之间切换，**切换后不重启即生效**。

做法是提供真实的本地化资源：`Sources/Shared/Localization/` 下的 `en.lproj` 与
`zh-Hans.lproj` 两份 `Localizable.strings`，**键就是英文原文**（漏翻一条会退回英文，
是能用的降级）。`RootView` 把当前语言喂进环境 —— `.environment(\.locale, app.language.locale)`
—— SwiftUI 就按这个 locale 去 bundle 的 `.lproj` 里挑译文，全 App 的字面量一起换，
一个调用点都不用改。

### 一个反直觉的点：换掉 `Bundle.main` 的类对 SwiftUI 无效

早先试过 `object_setClass(Bundle.main, LocalizedBundle.self)`，覆写
`localizedString(forKey:value:table:)`。这条路对 `NSLocalizedString` / `String(localized:)`
有效，但 **SwiftUI 的 `Text("…")`（字面量 → `LocalizedStringKey`）根本不走这个方法** ——
它有一套独立的解析路径，只认真正打进 bundle 的本地化资源。症状很好认：切换语言后只有
**直接查表**的那几条跟着变（设置页的「可用」），其余 `Text("…")` 全部原地不动。

结论：想让全 App 的字面量跟着语言走，只有两条路 —— 要么给每个调用点手工包一层，要么
老老实实提供 `.lproj` 并把 `\.locale` 喂进环境。这里选后者。

### 其余要点

- **字形要单独换。** 译文由环境 locale 决定，换 locale 时 SwiftUI 自己会重算；但字形不是
  —— `AppFont` 读的是 `AppLanguage.current` 这个全局。所以换语言时整棵分页树仍然换一次
  identity（`.id(app.language)`），保证字形、字距、大小写跟译文一起换。`TabView` 的选中项
  绑在 `AppState` 上，重建不会把用户踢回第一页。
- **`Strings.text(_:)`** 给「键在运行期才知道」的地方用（适配器传输方式、设置页的可用状态、
  内存优化的失败原因、图表 series 名）：这些地方本来就得先拿到一个 `String`，而 `Text`
  那条路要的是编译期字面量，套不上去。它直接去 `.lproj` 里查。
- **负一屏小组件跟随系统语言，不受这个开关控制。** 扩展跑在独立进程里，工程没有 App Group
  entitlement，读不到主 App 的 `UserDefaults`；两份 `.lproj` 也打进了 appex，扩展按系统
  locale 去挑。

改文案直接改那两份 `.strings`，然后跑 `bash scripts/check-localization.sh`：它会核对两份
文件的键集合、重复键，以及中英占位符数量是否一致。

中文字形是另一件事：SF Rounded 只有拉丁字形，汉字会掉回苹方 SC，同一行里数字圆润、
汉字方正，字重与基线都对不齐。所以中文下整体退回 `.default` design，让系统那条
「SF Pro + 苹方 SC」的字形链处理中英混排；拉丁全大写的微标签在中文下也不再转大写、
不再加字距。全部由 `AppFont` 一处收口。

## 滚动流畅性

三页都是「一秒一拍」的采样，早期版本用的是 `Task.sleep` 循环，**滚动时会卡顿**。原因是
`Task.sleep` 的续体跑在 MainActor 的执行器上，**不受 run loop 模式影响**：滚动的整段时间里
它照样每秒醒一次，读一轮 IORegistry / HID 传感器 / `getifaddrs` / 存储容量，再把整棵视图树
重算一遍（含一张 180 点的 Swift Charts）。十几到几十毫秒砸进正在滚动的那一帧里，就是看得见
的掉帧。

改成挂在 `.default` 模式上的 `Timer`（**不是** `.common`）之后就解决了：UIScrollView 一开始
拖动就会把 run loop 切到 tracking 模式，采样在整个滚动手势期间自动让路，手指一松立刻接上。
这不是降低刷新率 —— 不滚动时仍然是一秒一拍。

另外三处：

- **实时曲线抽稀到 72 点**。原始序列最多 180 个（三分钟 × 一秒），全量交给 Swift Charts 是
  540 个 mark，而它每秒都要重算。抽稀保峰值（每桶取最大值），尖峰不会被抹掉；三个并列的
  `ForEach` 也合成一个，同一批点不再走三遍。曲线的发布频率降到两秒一次，采样本身仍是每秒一个。
- **出厂就定死的量不再每秒重读**。机型、核心数、最高频率、系统版本、内核版本、物理内存
  全部缓存；存储容量改成十秒问一次文件系统。
- **表盘的弧线量化到 0.5% 一档**。它带着 0.45 秒的隐式动画，而瓦数每秒在千分之几上抖，
  不量化的话动画每一秒都会被打断重来。

最后，功率页的曲线只在**这一页被选中时**才真正构建：`TabView` 会把切走的分页留在视图树里，
采样一发布那张图就跟着重算。没在看的时候用等高占位顶住，切回来时布局不跳。

## CPU 频率这一项

`sysctl hw.cpufrequency` / `hw.cpufrequency_max` 是 macOS（Intel）专有的键，iOS 真机上
恒返回失败；网上流传很广的那段 `sysctl(mib, 2, &results, ...)` 取 `HW_CPU_FREQ` 是早期
iOS 的遗留代码，Apple 后来把主频这个内核变量对沙箱关掉了。`IOReport`（`powermetrics`
走的那条路）要 `com.apple.private.ioreport` 特权。

所以频率是**实测**的，走的正是 CPU-X 那条路 —— 它的界面把 `CPU Design Speed`（设计主频）
与 `CPU Current Speed`（当前主频）并列，后者就是实测值。

- `Sources/Shared/Hardware/CPUFrequencyProbe.c`：在 Apple 的 ARM64 核上，一条**依赖**的
  `add` 延迟正好是 1 个周期，于是「32 条首尾相接的 add」一轮就是 32 个周期（循环自身的
  `subs` / `b.ne` 不在这条依赖链上，乱序核有足够余量把它们完全重叠掉）。跑固定轮数、
  量墙钟时间，频率 = 周期数 / 秒。这条链是**延迟受限**而非吞吐受限的，所以结果与核的
  发射宽度无关，不需要按微架构查表。
- 调频是按核的，所以探针起一条自己的 pthread 并把 QoS 抬到 user-interactive，让调度器把
  它放到性能核上、把频率顶上去；先跑一段热身再计测（调频响应在几十毫秒量级），取三轮里
  的最高值。合计约 15–20 ms 的忙循环，跑在专用队列上，不阻塞主线程。
- `CPUFrequency.swift` 负责校验：探针的模型一旦不成立会读出离谱的数字，那比显示标称值
  还糟。窗口给得很宽（标称的 1/5 到 1.15 倍），下界放低是为了不把**真正的降频**
  （热限频、低电量模式）误判成失效 —— 那是这台机器此刻真实的主频。
- 探针测不出、或结果不可信时，回落成机型表里的标称主频（`HardwareMonitor.clocks`，
  覆盖 A9–A18 共 11 颗芯片）。认不出来的机型显示「—」，不编数字。
- 三秒测一次：频率不会那么快变，一秒一次是白烧电。

为什么探针是 C 而不是 Swift：Swift 没有内联汇编，用纯 Swift 写循环优化器会把它改写掉，
周期数就不确定了。接线见 `Support/SysProbe-Bridging-Header.h` 与 `project.yml` 的
`SWIFT_OBJC_BRIDGING_HEADER`。

## 网络那一栏

实时速率与累计流量来自 `sysctl(NET_RT_IFLIST2)` 的 `if_data64`。

之前用的是 `getifaddrs` 的 `ifa_data`，那是错的，而且错得很隐蔽：`ifa_data` **只在
`AF_LINK` 那条记录上非空**，而地址在 `AF_INET` 记录上 —— 一次遍历里在 `AF_INET` 记录上
读它，拿到的是 NULL，于是 `ifi_ibytes` / `ifi_obytes` 永远是 0。症状正是「地址显示得出来，
流量一直是零」。即便读对了记录，`ifa_data` 指向的是 32 位的 `struct if_data`，4 GB 就回绕，
累计流量根本没法用。`NET_RT_IFLIST2` 返回 `if_msghdr2` + `if_data64`，计数器 64 位，也正是
`netstat` 在 64 位系统上走的那条路。地址仍走 `getifaddrs` —— 两者本来就在两条不同的记录上，
硬凑到一次遍历里就是上面那个坑。

选哪条链路**先看类型、再看流量**：连着 Wi-Fi 就是 Wi-Fi，断了才轮到蜂窝。插着 SIM 卡时
`pdp_ip0` 一直是 up、也一直有 IPv4 地址，所以「有地址」区分不出 Wi-Fi 和蜂窝；而按累计
字节数挑同样会挑错 —— 后台同步、推送常常悄悄走蜂窝，累计量反而比 Wi-Fi 大。

## 闪屏

启动、切分页、进／出设置页时曾各闪一下。逐条排查出来的结构性成因：

- **启动屏底色。** `UILaunchScreen_Generation` 生成的启动屏用系统背景色（浅色下白、
  深色下黑），与画布（`#EEF1F6` / `#06070A`）差一截，第一帧就跳一下。补了一张
  `LaunchBackground` 颜色资源（`Sources/App/Assets.xcassets/`），并把它写进
  `Support/SysProbe-Info.plist` 的 `UILaunchScreen.UIColorName`。
- **`Backdrop` 里的 `.blendMode(.plusLighter)`。** 发光层走的是 SwiftUI 的混合模式，
  底下是 Core Image 的合成滤镜，要额外一遍离屏渲染；而弹设置面板、切分页这些转场里
  UIKit 正在对整棵视图做变换，这一遍常常来不及，露出来就是一帧空白。现在整张背景
  （渐变 + 网格 + 发光）画在**同一个 `Canvas`** 里，发光用 `GraphicsContext.blendMode`
  —— Core Graphics 自己的混合模式，一层 CALayer、一次画完，没有额外的合成组。
  唯一的代价是发光换色不再有 0.8 秒渐变（`Canvas` 不参与隐式动画插值）。
- **画布底色兜底。** `Backdrop`、每个分页、设置面板、`RootView` 最底层都压了一层不透明的
  `Color.mwCanvas`。转场里任何一帧上层还没画上内容，露出来的都是画布色，而不是窗口底色。
- **设置面板的容器底色。** 面板用 `presentationBackground`（iOS 16.4+）设成画布色；
  面板内部的画布改成 `Form` 的**兄弟节点**而不是它的 `.background` ——
  `NavigationStack` 自己的底色是系统分组色，只铺 `Form` 的话导航栏那一条露出来的还是它。
- **根视图每秒重算。** `RootView` 的 `body` 里是整棵 `TabView` 加一个 sheet 修饰符，
  而它曾订阅每秒发布一次的 `PowerMonitor` —— 整棵树连带面板修饰符每秒重建一次。
  采样的生命周期拆进了 `MonitorLifecycle`：一个零尺寸视图，订阅不再传染给 `RootView`。
- **齿轮按钮不再观察 `AppState`。** `PageScaffold` 原先是 `@EnvironmentObject AppState`，
  于是 `showingSettings` 一变，三个分页（各自一棵 `NavigationStack` + `ScrollView` +
  面板树）会在**同一帧**各重算一次 —— 而这一帧恰好就是设置面板开始做呈现动画的那一帧。
  现在改成把「打开设置」当一个闭包传下去，只有 `RootView` 需要观察那个状态；
  功率页判断「自己是不是当前分页」也换成了本地状态。
- **`Backdrop` 的 `.drawingGroup()`。** 它把网格层渲进一张离屏纹理，而每次转场 SwiftUI
  都可能把那张纹理丢掉重画，中间会有一帧是空的。网格只有 ~50 条线，`Canvas` 本身就是一层
  CALayer、只有尺寸变化才重画，`.drawingGroup()` 去掉即可。

## 内存优化说明

iOS 不允许任何 App 释放别的 App 的内存 —— 内存由内核按进程管理，系统通过 jetsam
自行回收。这里的「优化」做的是业界通行的做法：短时间内申请一大块内存并逐页写入，
把内存压力顶上去，逼内核回收文件缓存与可回收页，然后立刻全部释放；同时清掉本 App
自己的缓存，并给出前后可用内存对比。

几个细节决定了它到底有没有效果：

- **写的是 xorshift 序列，不是同一个字节。** 早先用 `memset(…, 0xA5, …)`，而 iOS 的 VM
  压缩器对「一整页都是 0xA5」的页几乎能压到零 —— 这 8 MB 实际只占几十 KB 物理内存，
  压力根本没顶上去。每页都不重样的数据压不动，分配才真的落在物理内存上。
- **停止判据是 `free`，不是「可用」。** 判据曾经是「可用」（free + inactive）且阈值
  250 MB，那个闸门定得太高：iOS 的 inactive 里绝大部分是可回收页，系统在 free 只剩几十
  兆时照样活得好好的，于是循环往往刚跑一两轮就退出，实际只分配了几十兆。真正会触发
  jetsam 的是 **free 池被耗尽**，所以闸门设在它上面（80 MB）；而 free 被我们压下去时，
  内核会主动回收缓存把它顶回来 —— 那正好是我们要它做的事。
- **释放后立刻读，不等系统把缓存填回去。** 以前会 sleep 0.25 秒再读，而那个等待正好把要
  看的东西等没了：刚释放的页立刻是 free，可磁盘缓存也会在几百毫秒内重新长回来，一觉醒来
  「可用」已经回到原样。要看的是回收的**峰值**。
- 上限是物理内存的 18%（且不超过 448 MB）—— iPhone X 只有 3 GB，真按「能占多少占多少」
  去压，极容易被 jetsam 当成内存大户直接杀掉。

**「可用」的口径也改了。** 现在是 `free + purgeable + speculative`，也就是内核**此刻就能
拿出来**的页，刻意**不含 `inactive`**：inactive 里的页虽然多数可回收，但内核回收它们的
同时就把 free 顶上去了 —— 两者之和在优化前后几乎不变，把它算进「可用」，读出来就是同一个
数，那正是「优化完已用/可用都没变化」的由来。CPU-X 的内存清理报的也是 `Mem Free`
（空闲内存），口径一致。`used` 取「总量 − 可用」，与「可用」互补。

**把它当作一次推动，而不是保证。** 面板上读得到的变化，就是这一轮真正逼出去的缓存。

## 构建

```bash
brew install xcodegen
bash scripts/build-ipa.sh          # 产出 build/export/SysProbe-unsigned.ipa
```

工程文件（`.xcodeproj`）不入库，每次构建由 `project.yml` 重新生成。

**工具链要求：Xcode 26 / Swift 6.2 或更新。** 代码里把 `nonisolated` 标注在类型与扩展
声明上（`nonisolated struct` / `nonisolated extension`），并依赖
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` —— 这两样都要 Swift 6.2 起步。工具链过旧时
错误会出现在编译深处且不点名真正原因，所以 CI 第一步就明确检查。

CI 在 GitHub Actions 的 macOS runner 上跑同一套步骤，推送到 `main` 即构建，
打 `v*` tag 会额外发布 Release。构建完还会断言两件容易静默失败的事：内嵌的 `.appex`
确实是 `com.apple.widget-extension`（万一退化成 WidgetKit，界面照样能装能显示，但刷新会
悄悄掉到 5 分钟以上且不报任何错），以及图标确实接上了（`CFBundleIconName` 指向 `AppIcon`、
`Assets.car` 存在、bundle 根目录有图标 PNG，另加一条对源 asset set 槽位完整性的检查）。

顺带记一个坑：**不要断言 actool 输出了哪几个倍率**。Xcode 26 / iOS 26 SDK 只吐一张规范化
的图标 PNG（`AppIcon60x60@2x.png`），其余倍率交给 `Assets.car`，这是新版图标管线而不是缺陷 ——
按「@2x 和 @3x 都会产出」去写断言，构建会被自己的断言判死。

## 授权与致谢

Power / Adapter 两屏的取数层与设计系统移植自
[MiniWatts](https://github.com/ResistanceTo/MiniWatts)（Apache License 2.0）。
详见 `LICENSE` 与 `NOTICE`。
