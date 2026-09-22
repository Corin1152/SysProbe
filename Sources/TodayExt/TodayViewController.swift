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
/// **界面是纯 UIKit 的**（`TodayWidgetView`），不是 SwiftUI。原因写在那个类型的
/// 文档里：用 `UIHostingController` 装 SwiftUI 会让 appex 拖进整个 SwiftUI 运行时，
/// 而扩展的内存预算与启动 watchdog 撑不起它 —— 症状就是负一屏显示「无法载入」。
/// 能正常工作的 CPU-X，它的 appex 里 SwiftUI 符号是 0。
///
/// 类名显式暴露给 ObjC 运行时。`NSExtensionPrincipalClass` 要靠 `NSClassFromString`
/// 找到这个类，而 Swift 给主模块里的类注册的运行时名字带着模块前缀
/// （`TodayExtension.TodayViewController`）—— 一旦模块名变了、或系统那边按不带前缀的
/// 名字查，就找不到类，负一屏显示「无法载入」。给一个显式的 `@objc(...)` 名字、
/// plist 里用同一个字符串，这一层不确定性就没有了。
@objc(SysProbeTodayViewController)
final class TodayViewController: UIViewController, NCWidgetProviding {

    private let monitor = PowerMonitor()
    private let widget = TodayWidgetView()
    private var snapshotSubscription: AnyCancellable?

    /// 收起态以下的高度下限。
    private let minimumHeight: CGFloat = 110

    override func viewDidLoad() {
        super.viewDidLoad()

        // 文案由扩展自己的 `en.lproj` / `zh-Hans.lproj` 提供（两份都打进了 appex）。
        //
        // 语言只能跟随系统：工程里没有 App Group entitlement，扩展读不到主 App 的
        // `UserDefaults`，所以设置页里那个语言开关管不到这一屏。`TodayFont` 与
        // `Strings.text` 读的都是 `AppLanguage.current` 这个全局，这里先给它落一个值。
        AppLanguage.current = .systemPreferred

        view.backgroundColor = .clear

        enableExpandedDisplayMode()

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

        preferredContentSize = CGSize(width: 0, height: minimumHeight)

        // 每秒一次的重采样由 `PowerMonitor` 驱动；这里只订阅它的快照。
        // `PowerMonitor` 是 `@MainActor` 隔离的，所以订阅与回调都在主 actor 上。
        //
        // 不写 `deinit { cancel() }`：`AnyCancellable` 释放时自己就会取消，而
        // `deinit` 是非隔离的 —— 在那里碰一个主 actor 隔离的存储属性是 Swift 6
        // 会拦下来的写法，为了一个本来就自动的行为去绕它不划算。
        snapshotSubscription = monitor.$snapshot
            .sink { [weak self] _ in self?.refresh() }
    }

    // MARK: 刷新

    private func refresh() {
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
    /// 「没被用到」，就把它从 appex 的加载列表里丢掉了（本工程的 appex 确实没有链
    /// NotificationCenter；能正常显示的 CPU-X，那个 appex 是链了的）。
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

    // MARK: 生命周期 —— 只有可见时才跑秒级刷新

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // `PowerMonitor.start()` 就是一个 1 秒的重采样循环，和 CPU-X 里那个
        // NSTimer 等价：进程活着就一直在跑。重复调用是幂等的。
        monitor.start()
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 滑走 / 锁屏后停止重采样，别在后台空转耗电。已记录的会话保持打开。
        monitor.pause()
    }

    // MARK: NCWidgetProviding

    /// 系统在负一屏不可见时偶尔要一个快照。这里不去重读传感器：
    /// 真正的刷新由 `viewWillAppear` 那个 1 秒循环负责，而重读会碰主 actor 状态，
    /// 与这个协议要求的 nonisolated 上下文冲突。给系统一个「有数据」即可。
    nonisolated func widgetPerformUpdate(completionHandler: @escaping (NCUpdateResult) -> Void) {
        completionHandler(.newData)
    }

    /// 高度已经按内容算好（见 `updatePreferredHeight`），模式切换时无需再调整。
    nonisolated func widgetActiveDisplayModeDidChange(_ activeDisplayMode: NCWidgetDisplayMode,
                                                      withMaximumSize maxSize: CGSize) {
    }
}
