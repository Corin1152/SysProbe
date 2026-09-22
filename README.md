# SysProbe

iPhone 硬件信息 + 充电功率/适配器读数工具。三屏结构：

| 屏 | 内容 |
|---|---|
| **Hardware** | CPU（型号/核心数/实时占用/每核负载）、内存（分项占用 + 优化）、存储、网络、系统版本 |
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

## 闪屏

启动、切分页、进／出设置页时曾各闪一下。四处结构性成因：

- **启动屏底色。** `UILaunchScreen_Generation` 生成的启动屏用系统背景色（浅色下白、
  深色下黑），与画布（`#EEF1F6` / `#06070A`）差一截，第一帧就跳一下。补了一张
  `LaunchBackground` 颜色资源（`Sources/App/Assets.xcassets/`），并把它写进
  `Support/SysProbe-Info.plist` 的 `UILaunchScreen.UIColorName`。
- **设置页底色。** 设置页原先是裸 `Form`，用的是系统分组背景，与画布的冷色调不是一回事，
  弹入／退出时整屏底色跳一次。现在铺上同一张 `Backdrop`（配 `.scrollContentBackground(.hidden)`），
  转场前后同底。
- **根视图每秒重算。** `RootView` 的 `body` 里是整棵 `TabView` 加一个 sheet 修饰符，而它
  订阅了每秒发布一次的 `PowerMonitor`（`shouldStayAwake` 要读插电状态）—— 于是整棵树连带
  面板修饰符每秒重建一次。采样与「常亮」的生命周期拆进了 `MonitorLifecycle`：一个零尺寸
  视图，订阅不再传染给 `RootView`。
- **`Backdrop` 的 `.drawingGroup()`。** 它把网格层渲进一张离屏纹理，而每次转场 SwiftUI
  都可能把那张纹理丢掉重画，中间会有一帧是空的。网格只有 ~50 条线，`Canvas` 本身就是一层
  CALayer、只有尺寸变化才重画，`.drawingGroup()` 去掉即可。

## 内存优化说明

iOS 不允许任何 App 释放别的 App 的内存 —— 内存由内核按进程管理，系统通过 jetsam
自行回收。这里的「优化」做的是业界通行的做法：短时间内申请一大块内存并逐页写入，
把内存压力顶上去，逼内核回收文件缓存与可回收页，然后立刻全部释放；同时清掉本 App
自己的缓存，并给出前后可用内存对比。

**把它当作一次推动，而不是保证。** 出于安全考虑，分配上限被限制在物理内存的 20%
（且不超过 512 MB），并在可用内存低于 250 MB 时提前停止 —— iPhone X 只有 3 GB 物理
内存，真按「能占多少占多少」去压，极容易被 jetsam 当成内存大户直接杀掉。

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
