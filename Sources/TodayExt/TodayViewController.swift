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
/// ## 启动路径刻意压到最小
///
/// 这一屏曾经一直显示「无法载入」。产物层面能查的都查过了：类确实注册在
/// `__objc_classlist` 里、名字对得上、入口点是 `NSExtensionMain`、
/// `LC_BUILD_VERSION` 正常、没有缺失的链接库、也**没有** SwiftUI 依赖。
/// 剩下唯一解释得通的是：**扩展进程在启动阶段被 watchdog 掐掉**。
///
/// 所以这里把启动路径拆成两段：
///
/// 1. `viewDidLoad` 只做三件不可能失败的事 —— 落一次语言、设背景色、挂一个占位
///    标签。**不碰 IO、不建视图树、不 `dlopen`。** 只要这一段跑完，系统就认为
///    扩展「加载成功」，负一屏不会再显示「无法载入」。
/// 2. 真正的内容（`PowerMonitor` 的构造会碰 IOKit、HID 与文件系统；`TodayWidgetView`
///    要建二十来个视图；`dlopen` 要拉一个框架）全部推迟到 `viewDidAppear`。
///
/// 属性初始化（原来的 `private let monitor = PowerMonitor()`）也一并去掉了 ——
/// 那段跑在 `viewDidLoad` **之前**，属于启动路径的一部分，正是最可疑的位置。
///
/// 类名显式暴露给 ObjC 运行时。`NSExtensionPrincipalClass` 要靠 `NSClassFromString`
/// 找到这个类，而 Swift 给主模块里的类注册的运行时名字带着模块前缀
/// （`TodayExtension.TodayViewController`）—— 一旦模块名变了、或系统那边按不带前缀的
/// 名字查，就找不到类，负一屏显示「无法载入」。给一个显式的 `@objc(...)` 名字、
/// plist 里用同一个字符串，这一层不确定性就没有了。
@objc(SysProbeTodayViewController)
final class TodayViewController: UIViewController, NCWidgetProviding {

    // 全部延迟创建，理由见类型文档。
    private var monitor: PowerMonitor?
    private var widget: TodayWidgetView?
    private var snapshotSubscription: AnyCancellable?
    private var placeholder: UILabel?
    private var didInstallContent = false

    /// 收起态以下的高度下限。
    private let minimumHeight: CGFloat = 110

    /// 启动轨迹的第一个点。
    ///
    /// 这是**最早**能插进代码的地方 —— dyld 加载与 ObjC 类注册都在它之前完成，
    /// 所以轨迹里能看到 `init`，就等于「进程起来了、类也注册了」。
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        TodayTrace.mark("init")
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        TodayTrace.mark("viewDidLoad:begin")
        super.viewDidLoad()

        // 这一段就是「扩展能加载」的全部条件。保持它又短又安全。
        //
        // 语言只能跟随系统：工程里没有 App Group entitlement，扩展读不到主 App 的
        // `UserDefaults`，所以设置页里那个语言开关管不到这一屏。`TodayFont` 与
        // `Strings.text` 读的都是 `AppLanguage.current` 这个全局。
        AppLanguage.current = .systemPreferred

        view.backgroundColor = .clear
        installPlaceholder()
        preferredContentSize = CGSize(width: 0, height: minimumHeight)

        // 走到这里，扩展已经「加载成功」了 —— 系统不会再显示「无法载入」。
        TodayTrace.mark("viewDidLoad:end")
    }

    // MARK: 生命周期

    override func viewDidAppear(_ animated: Bool) {
        TodayTrace.mark("viewDidAppear:begin")
        super.viewDidAppear(animated)
        installContentIfNeeded()
        // `PowerMonitor.start()` 就是一个 1 秒的重采样循环，和 CPU-X 里那个
        // NSTimer 等价：进程活着就一直在跑。重复调用是幂等的。
        monitor?.start()
        TodayTrace.mark("viewDidAppear:end")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 滑走 / 锁屏后停止重采样，别在后台空转耗电。已记录的会话保持打开。
        monitor?.pause()
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

        // 分步打点：这几步各自会碰不同的系统资源（dlopen 框架、IOKit、视图树），
        // 哪一步没走完，轨迹就停在哪一步的名字上。
        TodayTrace.mark("expandedMode")
        enableExpandedDisplayMode()

        TodayTrace.mark("monitor:begin")
        let monitor = PowerMonitor()
        TodayTrace.mark("monitor:end")

        TodayTrace.mark("widget:begin")
        let widget = TodayWidgetView()
        TodayTrace.mark("widget:end")

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

        self.monitor = monitor
        self.widget = widget

        // 每秒一次的重采样由 `PowerMonitor` 驱动；这里只订阅它的快照。
        // `PowerMonitor` 是 `@MainActor` 隔离的，所以订阅与回调都在主 actor 上。
        //
        // 不写 `deinit { cancel() }`：`AnyCancellable` 释放时自己就会取消，而
        // `deinit` 是非隔离的 —— 在那里碰一个主 actor 隔离的存储属性是 Swift 6
        // 会拦下来的写法，为了一个本来就自动的行为去绕它不划算。
        snapshotSubscription = monitor.$snapshot
            .sink { [weak self] _ in self?.refresh() }

        refresh()
    }

    private func refresh() {
        guard let monitor, let widget else { return }
        placeholder?.isHidden = true
        widget.apply(monitor.snapshot,
                     headline: monitor.headline,
                     resistance: monitor.pathResistance)
        updatePreferredHeight()
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
    /// **`NotificationCenter.framework`** 里；而较新的 SDK 已经把它的声明并进了 UIKit，
    /// 于是 Swift 调用它只生成 `objc_msgSend`、不产生任何链接依赖 —— 链接器看这个库
    /// 「没被用到」，就把它从 appex 的加载列表里丢掉了。
    ///
    /// 后果在真机上才显现：那个分类根本没注册，直接调就是 `unrecognized selector`
    /// —— 扩展在 `viewDidLoad` 里当场崩掉，负一屏显示「无法载入」。
    ///
    /// 所以这里先把框架 `dlopen` 进来（分类随之注册），再**先探响应性、后走
    /// `method(for:)` 直接调**：选择器在就设成展开态，不在就安静跳过
    /// （小组件退回收起态，但内容照常显示，不会崩）。
    private func enableExpandedDisplayMode() {
        Self.loadNotificationCenter
        let selector = NSSelectorFromString("setWidgetLargestAvailableDisplayMode:")
        guard let context = extensionContext,
              context.responds(to: selector),
              let implementation = context.method(for: selector) else { return }
        // `NCWidgetDisplayMode.expanded` 的原始值是 1。写成字面量是因为
        // `NCWidgetDisplayMode` 同样来自那个可能没被加载的模块。
        typealias Setter = @convention(c) (NSObject, Selector, Int) -> Void
        unsafeBitCast(implementation, to: Setter.self)(context, selector, 1)
    }

    /// 把 `NotificationCenter.framework` 加载进本进程（懒执行，只做一次）。
    ///
    /// 为什么用 `dlopen` 而不是在 `project.yml` 里加 `-framework NotificationCenter`：
    /// 链接器会做 `-dead_strip_dylibs`；而分类方法不是符号、引用不到，加了照样会被丢掉。
    /// `dlopen` 绕开链接期，直接把库拉进来。
    ///
    /// 返回值显式丢掉：这个 `static let` 的类型是 `Void`（它只负责「加载」这个副作用），
    /// 而 `dlopen` 返回的是句柄。丢掉的那个句柄不该被 `dlclose` —— 分类注册在
    /// 进程生命期里都要在。
    private static let loadNotificationCenter: Void = {
        _ = dlopen("/System/Library/Frameworks/NotificationCenter.framework/NotificationCenter",
                   RTLD_NOW)
    }()

    // MARK: 尺寸

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredHeight()
    }

    /// 按内容的自然高度定展开态的高度。
    ///
    /// 只有变化超过半点时才会写回，否则会自己触发一轮新的布局，形成死循环。
    private func updatePreferredHeight() {
        guard let widget else { return }
        let width = view.bounds.width
        guard width > 1 else { return }

        let fitted = widget.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        let height = max(minimumHeight, fitted.height.rounded(.up))
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

    /// 高度已经按内容算好（见 `updatePreferredHeight`），模式切换时无需再调整。
    nonisolated func widgetActiveDisplayModeDidChange(_ activeDisplayMode: NCWidgetDisplayMode,
                                                      withMaximumSize maxSize: CGSize) {
    }
}

// MARK: - 启动轨迹

/// 扩展的启动轨迹，写进**剪贴板**。
///
/// ## 为什么是剪贴板
///
/// 扩展与外界只有这一条通道：
///
/// - 没有 App Group entitlement，写文件主 App 读不到；
/// - 崩溃若发生在 `viewDidLoad` 之前，界面上什么都显示不出来（系统直接显示「无法载入」）；
/// - 用户的电脑是 Windows，没有 Mac 的 Console.app 可看设备日志。
///
/// 剪贴板是唯一「扩展能写、用户能读」的地方。随便找个输入框粘一下就能看到进程走到了
/// 哪一步 —— 比让用户去翻「设置 → 隐私 → 分析与改进 → 分析数据」里那一长串快得多。
///
/// ## 怎么读
///
/// 轨迹是**累加**的，粘出来的是完整路径。停在哪一步，问题就在它的下一步：
///
/// - 什么都没有 → 进程根本没起来（dyld 或系统层），与代码无关
/// - 停在 `viewDidLoad:begin` → `AppLanguage.current` 或 `installPlaceholder()`
/// - 停在 `viewDidAppear:begin` → `enableExpandedDisplayMode()` 或 `PowerMonitor()`
/// - 停在 `monitor:begin` → `PowerMonitor` 的构造（IOKit / HID / 文件系统）
///
/// **定位完就该把它摘掉** —— 它会覆盖用户的剪贴板。
///
/// 刻意不写 `nonisolated`：工程默认主 actor 隔离，而 `UIPasteboard` 也是主 actor
/// 隔离的，保持默认才不用在两个隔离域之间绕。
enum TodayTrace {

    /// 已经走过的点。只在扩展进程里、只从主线程写。
    private static var stages: [String] = []

    static func mark(_ stage: String) {
        stages.append(stage)
        let stamp = ISO8601DateFormatter().string(from: Date())
        UIPasteboard.general.string = """
        SysProbe widget trace
        \(stamp)
        \(stages.joined(separator: " → "))
        """
    }
}
