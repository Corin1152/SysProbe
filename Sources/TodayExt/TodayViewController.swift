import UIKit
import SwiftUI
import NotificationCenter

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
/// 类名显式暴露给 ObjC 运行时。`NSExtensionPrincipalClass` 要靠 `NSClassFromString`
/// 找到这个类，而 Swift 给主模块里的类注册的运行时名字带着模块前缀
/// （`TodayExtension.TodayViewController`）—— 一旦模块名变了、或系统那边按不带前缀的
/// 名字查，就找不到类，负一屏显示「无法载入」。给一个显式的 `@objc(...)` 名字、
/// plist 里用同一个字符串，这一层不确定性就没有了。
@objc(SysProbeTodayViewController)
final class TodayViewController: UIViewController, NCWidgetProviding {

    private let monitor = PowerMonitor()
    private var hosting: UIHostingController<TodayContentView>?

    /// 收起态以下的高度下限。展开态的高度按内容实测（见 `updatePreferredHeight`），
    /// 内容少时也不至于塌成一条。
    private let minimumHeight: CGFloat = 520

    override func viewDidLoad() {
        super.viewDidLoad()

        // 文案由扩展自己的 `en.lproj` / `zh-Hans.lproj` 提供（两份都打进了 appex），
        // SwiftUI 按环境里的 locale 去挑，系统是中文就是中文。
        //
        // 语言只能跟随系统：工程里没有 App Group entitlement，扩展读不到主 App 的
        // `UserDefaults`，所以设置页里那个语言开关管不到这一屏。`AppFont` 读的是
        // `AppLanguage.current` 这个全局，这里先给它落一个值。
        AppLanguage.current = .systemPreferred

        view.backgroundColor = .clear

        enableExpandedDisplayMode()
        preferredContentSize = CGSize(width: 0, height: minimumHeight)

        let host = UIHostingController(rootView: TodayContentView(monitor: monitor))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hosting = host
    }

    // MARK: 展开态

    /// 打开「展开 / 收起」两种形态。
    ///
    /// 不设这一句，负一屏就只有收起态、永远展不开，内容会被压成一小条。
    ///
    /// **这里刻意不直接写 `extensionContext?.widgetLargestAvailableDisplayMode = .expanded`。**
    /// 那个属性是 `NSExtensionContext` 的一个分类方法，实现在
    /// **`NotificationCenter.framework`** 里；而 iOS 26 SDK 已经把它的声明并进了 UIKit，
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
    /// 链接器会做 `-dead_strip_dylibs` —— 本工程的 appex 就被它丢掉了用不到的
    /// `Charts.framework`；而分类方法不是符号、引用不到，加了照样会被丢掉。
    /// `dlopen` 绕开链接期，直接把库拉进来。
    ///
    /// 系统框架，允许 dlopen；`HIDSensors` 读 IOKit 用的也是同一招。
    private static let loadNotificationCenter: Void = {
        // 返回值显式丢掉：这个 `static let` 的类型是 `Void`（它只负责「加载」这个副作用），
        // 而 `dlopen` 返回的是句柄。丢掉的那个句柄不该被 `dlclose` —— 分类注册在
        // 进程生命期里都要在。
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
        guard let host = hosting else { return }
        let width = view.bounds.width
        guard width > 1 else { return }

        let fitted = host.sizeThatFits(in: CGSize(width: width,
                                                  height: .greatestFiniteMagnitude))
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
