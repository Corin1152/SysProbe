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

    /// 组件顶部那行（App 图标 + 名称 + 展开箭头）由**系统**绘制；它占的高度既不在
    /// `systemLayoutSizeFitting` 的结果里，也不是我们报给系统的 `preferredContentSize`
    /// 的「内容部分」—— `preferredContentSize.height` 是**含那一行**的总高度。
    ///
    /// 少算这段补偿，内容就会被组件底边裁掉。**0.0.41 实机上「存储」那一条连同
    /// 「已用 … · 剩余 …」被切掉一半，就是这么来的**：内容自然高 119pt、我们报了
    /// 120pt，系统再扣掉头部，内容区就只剩 99pt。
    ///
    /// 取值依据是两次实机反推，互相印证：
    ///   · 0.0.40：内容 92pt、报 118pt → 显示完整且略有富余，说明头部 ≤ 26pt；
    ///   · 0.0.41：内容 119pt、报 120pt → 被裁约 20pt，说明头部 ≈ 21pt。
    /// 取 24pt，落在两者之间偏保守一侧。
    private static let systemHeaderHeight: CGFloat = 24

    /// 内容区上下各留的呼吸空间。
    ///
    /// 组件高度必须比「内容 + 系统头部」**再多出这一段**：多出来的部分由
    /// `TodayWidgetView` 的 `centerY` 约束平均分到上下两端；少掉它，最下面那条存储
    /// 进度条就会紧贴组件底边（0.0.44 的效果图里正是如此）。
    /// 0.0.39 看着舒服，也是因为它报的高度（118）比内容（约 92）多出二十几点。
    private static let contentBreathing: CGFloat = 8

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredHeight()
    }

    /// 按内容的自然高度定展开态的高度。
    ///
    /// `maximumHeight` 是系统在形态切换回调里给的上限；平时不传，即不设限。
    ///
    /// 只有变化超过半点时才会写回，否则会自己触发一轮新的布局，形成死循环。
    private func updatePreferredHeight(maximumHeight: CGFloat = .greatestFiniteMagnitude) {
        guard let widget else { return }
        let width = view.bounds.width
        guard width > 1 else { return }

        let fitted = widget.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        // 组件总高 = 内容自然高 + 系统头部 + 上下留白。
        //   · 头部：`preferredContentSize.height` 是**含它**的总高，少算会被底边裁；
        //   · 留白：给内容上下各匀一截，否则存储条那条进度条会贴着组件底边。
        let wanted = max(minimumHeight,
                         (fitted.height + Self.systemHeaderHeight
                          + Self.contentBreathing * 2).rounded(.up))
        let height = min(wanted, maximumHeight)
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

    /// 高度已经按内容算好（见 `updatePreferredHeight`），但**这里仍要重设一次**：
    /// 系统在形态切换时会把 `preferredContentSize` 归到它给的上限（收起态那条很小），
    /// 不重设的话展开态也会被按那个高度裁掉内容。
    ///
    /// 回调由系统在主线程上发起，所以 `assumeIsolated` 是安全的；改成 `Task { @MainActor }`
    /// 反而会因为捕获非 Sendable 的 `self` 而编译不过。
    nonisolated func widgetActiveDisplayModeDidChange(_ activeDisplayMode: NCWidgetDisplayMode,
                                                      withMaximumSize maxSize: CGSize) {
        MainActor.assumeIsolated {
            updatePreferredHeight(maximumHeight: maxSize.height)
        }
    }
}
