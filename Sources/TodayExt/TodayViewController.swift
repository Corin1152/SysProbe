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
final class TodayViewController: UIViewController, NCWidgetProviding {

    private let monitor = PowerMonitor()
    private var hosting: UIHostingController<TodayContentView>?

    /// 收起态以下的高度下限。展开态的高度按内容实测（见 `updatePreferredHeight`），
    /// 内容少时也不至于塌成一条。
    private let minimumHeight: CGFloat = 520

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        // 允许「展开 / 收起」两种形态：收起时系统只给一小条，展开时用
        // `preferredContentSize`。不设这一句，负一屏就只有收起态，永远展不开。
        extensionContext?.widgetLargestAvailableDisplayMode = .expanded
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
