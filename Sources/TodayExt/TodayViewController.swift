import Combine
import NotificationCenter
import UIKit

/// 负一屏（Today View）小组件。
///
/// 走的是**传统 Today Extension**（`com.apple.widget-extension`）而不是 WidgetKit：
/// 这是一个真正被加载进负一屏的视图控制器，只要负一屏可见，进程就活着，
/// 于是可以按自己的节奏（1 秒）不断重读数据并刷新界面 —— 不受 WidgetKit
/// 那套「时间线预算、最快 5 分钟」的限制。CPU-X 的负一屏用的正是这个机制。
///
/// 代价是：滑走 / 锁屏后扩展会被挂起，刷新随之停止，此时由
/// `widgetPerformUpdate` 提供一个快照。传统扩展自 iOS 14 起被标记废弃、
/// iOS 18 起被移除 —— 而本机（iPhone X）的系统封顶就是 iOS 16.x，所以不受影响。
///
/// 界面是纯 UIKit 的（`TodayWidgetView`），不用 SwiftUI。
///
/// ## 这一屏曾经显示「无法载入」，真根因是缺一个库
///
/// 排查过程值得记下来：产物层面能查的全查过（principal class 的实际注册名、入口点、
/// `LC_BUILD_VERSION`、链接库、`NSExtension` 键、可执行权限、SwiftUI 依赖、签名、
/// 注册缓存），全部正常。最后是真机崩溃日志一次定位的：
///
///     +[EXConcreteExtensionContextVendor _extensionContextClass]   ← 系统代码
///     EXC_BREAKPOINT / SIGTRAP
///
/// 系统建立扩展的 XPC 连接时，按 `NSExtensionPointIdentifier` 找出该用哪个
/// `NSExtensionContext` 子类 —— 对 `com.apple.widget-extension` 就是
/// `NCWidgetExtensionContext`，它实现在 `NotificationCenter.framework` 里。
/// 而 appex **从来没链过那个库**，于是类找不到、当场 trap。
/// **这个时机早于系统实例化本类**，所以连 `init` 都跑不到 —— 修法见 `project.yml`
/// 的 `OTHER_LDFLAGS`。
///
/// 教训：**先要崩溃日志，再改代码。** 产物对比只能产生「相关」，产生不了「因果」。
@objc(SysProbeTodayViewController)
final class TodayViewController: UIViewController, NCWidgetProviding {

    // 全部延迟创建。属性初始化跑在 `viewDidLoad` 之前，属于启动路径 ——
    // 那里碰 IOKit / 文件系统，在扩展那点启动预算里就可能被 watchdog 掐掉。
    private var hardware: HardwareMonitor?
    private var power: PowerMonitor?
    private var widget: TodayWidgetView?
    private var placeholder: UILabel?
    private var subscriptions: [AnyCancellable] = []
    private var didInstallContent = false

    /// 电芯温度（来自守护进程的 `get_bat_info`）。首拍时还没有，界面按「—」显示。
    private var battery: BatteryInfo?
    /// 一次电池读取还没回来时置位，用来丢拍而不是让 Task 堆积。
    private var batteryInFlight = false

    /// 收起态的高度下限。数值对齐 CPU-X 的组件（约 118pt）。
    private let minimumHeight: CGFloat = 118

    /// **系统在组件顶部画的那一行**（App 图标 + 名称 + 展开箭头）的高度估算。
    ///
    /// `preferredContentSize.height` 是**含那一行**的总高度，所以算组件总高时必须加上它。
    ///
    /// 取值依据是两次实机反推，互相印证：
    ///   · 0.0.40：内容 92pt、报 118pt → 显示完整且略有富余，说明头部 ≤ 26pt；
    ///   · 0.0.41：内容 119pt、报 120pt → 被裁约 20pt，说明头部 ≈ 21pt。
    /// 取 24pt，落在两者之间偏保守一侧。
    ///
    /// **定义在 `TodayWidgetView` 上**（那里是唯一真值来源）—— 两边必须同源，
    /// 否则组件总高与实际布局对不上。
    private static var systemHeaderHeight: CGFloat { TodayWidgetView.systemHeaderHeight }

    /// 内容在组件内的上 / 下留白（**不等**，理由见 `TodayWidgetView` 里那两个常量）。
    ///
    /// 它们同时被 `TodayWidgetView` 用作布局约束、被本类用来算组件总高 ——
    /// 与系统头部同理，只留一份真值。
    private static var contentTopInset: CGFloat { TodayWidgetView.contentTopInset }
    private static var contentBottomInset: CGFloat { TodayWidgetView.contentBottomInset }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 这一段就是「扩展能加载」的全部条件：不碰 IO、不建视图树、不 `dlopen`。
        // 只要它跑完，负一屏就不会再显示「无法载入」。
        //
        // 语言只能跟随系统：工程里没有 App Group entitlement，扩展读不到主 App 的
        // `UserDefaults`，所以设置页里那个语言开关管不到这一屏。`TodayFont` 与
        // `Strings.text` 读的都是 `AppLanguage.current` 这个全局。
        AppLanguage.current = .systemPreferred

        view.backgroundColor = .clear
        installPlaceholder()
        preferredContentSize = CGSize(width: 0, height: minimumHeight)
    }

    // MARK: 生命周期

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installContentIfNeeded()
        hardware?.start()
        power?.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 滑走 / 锁屏后停止重采样，别在后台空转耗电。
        hardware?.pause()
        power?.pause()
    }

    // MARK: 占位

    /// 内容就位之前先显示这一行，免得第一帧是一片空白。
    ///
    /// 它还有个诊断作用：如果负一屏上能看到这句话，说明扩展**加载成功了**，
    /// 后面出问题就都在内容那一侧，而不是扩展配置。
    private func installPlaceholder() {
        let label = UILabel()
        label.text = Strings.text("Reading sensors…")
        label.font = TodayFont.text(13)
        label.textColor = TodayStyle.muted
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])
        placeholder = label
    }

    // MARK: 真正的内容

    private func installContentIfNeeded() {
        guard !didInstallContent else { return }
        didInstallContent = true

        enableExpandedDisplayMode()

        let hardware = HardwareMonitor(includeCPUFrequency: false)
        let power = PowerMonitor()
        let widget = TodayWidgetView()
        widget.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(widget)
        NSLayoutConstraint.activate([
            widget.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            widget.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            widget.topAnchor.constraint(equalTo: view.topAnchor),
            widget.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 点一下整块组件就打开主 App。CPU-X 走的是同一条路：主 App 注册一个自定义
        // URL scheme，扩展这边用 `extensionContext.open(_:)` 把它唤起来。
        let tap = UITapGestureRecognizer(target: self, action: #selector(openApp))
        tap.cancelsTouchesInView = false
        widget.addGestureRecognizer(tap)

        self.hardware = hardware
        self.power = power
        self.widget = widget

        // 两个采样器都是 1 秒一拍，但只订阅其中一个的节奏就够了 —— 回调里同时读两份
        // 快照，省掉一条多余的刷新路径（两条都订阅会让同一秒里刷两遍）。
        // `PowerMonitor` 是 `@MainActor` 隔离的，所以订阅与回调都在主 actor 上。
        //
        // 不写 `deinit { cancel() }`：`AnyCancellable` 释放时自己就会取消，而
        // `deinit` 是非隔离的 —— 在那里碰一个主 actor 隔离的存储属性是 Swift 6
        // 会拦下来的写法，为了一个本来就自动的行为去绕它不划算。
        power.$snapshot
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        refresh()
    }

    private func refresh() {
        guard let hardware, let power, let widget else { return }
        placeholder?.isHidden = true
        widget.apply(hardware: hardware.snapshot, power: power.snapshot, battery: battery)
        updatePreferredHeight()
        loadBattery()
    }

    /// 读一次电芯温度（异步，来自守护进程的 `get_bat_info`）。
    ///
    /// **不在这里递归调用 `refresh`** —— 读到的值下一拍（1 秒后）自然就用上了。
    /// 温度变化本来就慢，晚一拍看不出来；递归反而会让每秒多刷一次。
    ///
    /// 守护进程没起来时 `batteryInfo()` 返回 nil，界面按「—」显示 —— 这与原来
    /// 「四组里突然出现破折号」的顾虑不同：温度这一项本来就可能没有读数。
    private func loadBattery() {
        guard !batteryInFlight else { return }
        batteryInFlight = true
        Task { [weak self] in
            let info = await BatteryBridge.batteryInfo()
            self?.battery = info
            self?.batteryInFlight = false
        }
    }

    // MARK: 点击跳转

    @objc private func openApp() {
        guard let url = URL(string: Self.hostAppURL) else { return }
        // `extensionContext` 是扩展唯一能唤起居主 App 的通道 —— 扩展里没有
        // `UIApplication`（那个 API 在 appex 上编译就过不去）。
        extensionContext?.open(url, completionHandler: nil)
    }

    /// 与主 App 的 `CFBundleURLTypes` 里注册的 scheme 一致（见 `Support/SysProbe-Info.plist`）。
    private static let hostAppURL = "sysprobe://open"

    // MARK: 展开态

    /// 打开「展开 / 收起」两种形态。
    ///
    /// 不设这一句，负一屏就只有收起态、永远展不开，内容会被压成一小条。
    ///
    /// **这里刻意不直接写 `extensionContext?.widgetLargestAvailableDisplayMode = .expanded`。**
    /// 那个属性是 `NSExtensionContext` 的一个分类方法，实现在
    /// `NotificationCenter.framework` 里；较新的 SDK 已经把它的声明并进了 UIKit，
    /// 于是 Swift 调用它只生成 `objc_msgSend`、不产生任何链接依赖 —— 它和
    /// `NCWidgetExtensionContext` 一样，都得靠 `project.yml` 里那句
    /// `-framework NotificationCenter` 才能保证那个库真的在场。
    ///
    /// 这里仍然保留「先探响应性、后走 `method(for:)` 直接调」的写法：选择器不在就
    /// 安静跳过（小组件退回收起态，但内容照常显示，不会崩）。
    private func enableExpandedDisplayMode() {
        let selector = NSSelectorFromString("setWidgetLargestAvailableDisplayMode:")
        guard let context = extensionContext,
              context.responds(to: selector),
              let implementation = context.method(for: selector) else { return }
        // `NCWidgetDisplayMode.expanded` 的原始值是 1。写成字面量是因为
        // `NCWidgetDisplayMode` 同样来自那个模块。
        typealias Setter = @convention(c) (NSObject, Selector, Int) -> Void
        unsafeBitCast(implementation, to: Setter.self)(context, selector, 1)
    }

    // MARK: 尺寸

    /// 系统在形态切换回调里给的最大高度（nil = 还没拿到）。
    ///
    /// **这是这份代码里唯一「不用猜」的高度信息** —— 系统会主动告诉能给我们多大。
    /// 我们报的 `preferredContentSize.height` 必须夹在它之内，否则系统会**静默 clamp**：
    /// 视图被压矮 → 内部那条「环格高度」的约束被打破 → 环缩多少完全不可控
    /// （0.0.44~0.0.47 每版环的大小都不一样，就是没夹住的结果）。
    private var systemMaximumHeight: CGFloat?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredHeight()
    }

    /// 按内容的自然高度定展开态的高度。
    ///
    /// `maximumHeight` 是系统在形态切换回调里给的上限；平时不传，就用记住的那个。
    ///
    /// 只有变化超过半点时才会写回，否则会自己触发一轮新的布局，形成死循环。
    private func updatePreferredHeight(maximumHeight: CGFloat? = nil) {
        guard let widget else { return }
        let width = view.bounds.width
        guard width > 1 else { return }

        let limit = maximumHeight ?? systemMaximumHeight ?? .greatestFiniteMagnitude

        let fitted = widget.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        // 组件总高 = 内容自然高 + 系统头部 + 上下留白（上下**不等**：上 2 / 下 10）。
        //   · 头部：`preferredContentSize.height` 是**含它**的总高，少算会被底边裁；
        //   · 留白：上小是为了把内容往上顶（头部只占上方）、下大是为了不贴底边。
        let wanted = max(minimumHeight,
                         (fitted.height + Self.systemHeaderHeight
                          + Self.contentTopInset + Self.contentBottomInset).rounded(.up))
        let height = min(wanted, limit)
        guard preferredContentSize.width != width
                || abs(preferredContentSize.height - height) > 0.5 else { return }
        preferredContentSize = CGSize(width: width, height: height)
    }

    // MARK: NCWidgetProviding

    /// 系统在负一屏不可见时偶尔要一个快照。这里不去重读传感器：
    /// 真正的刷新由那个 1 秒循环负责，而重读会碰主 actor 状态，
    /// 与这个协议要求的 nonisolated 上下文冲突。给系统一个「有数据」即可。
    nonisolated func widgetPerformUpdate(completionHandler: @escaping (NCUpdateResult) -> Void) {
        completionHandler(.newData)
    }

    /// 系统告诉我们「这个形态下最大能给多大」。
    ///
    /// **只认展开态（`.expanded`）的上限。** 收起态也会回调一次，给的值很小
    /// （约一行文字的高度）—— 记下它的话，之后每次算高度都被那个小值夹住，
    /// **展开后的组件也跟着矮一截、环跟着变小**。这正是 0.0.44~0.0.47
    /// 「环每版大小都不一样、总是明显小于设计值」的**上游原因**：
    /// 设计 105.5pt 的环，真机上只画到 72~86pt。
    ///
    /// 接住展开态上限之后，`preferredContentSize` 就能报到系统真正允许的值，
    /// 环也就能长到它该有的尺寸（环格 = 组件高 − 头部 − 留白，环格外沿 = 环格 − 14.5）。
    ///
    /// 回调由系统在主线程上发起，所以 `assumeIsolated` 是安全的；改成 `Task { @MainActor }`
    /// 反而会因为捕获非 Sendable 的 `self` 而编译不过。
    nonisolated func widgetActiveDisplayModeDidChange(_ activeDisplayMode: NCWidgetDisplayMode,
                                                      withMaximumSize maxSize: CGSize) {
        MainActor.assumeIsolated {
            guard activeDisplayMode == .expanded else { return }
            systemMaximumHeight = maxSize.height
            updatePreferredHeight(maximumHeight: maxSize.height)
        }
    }
}
