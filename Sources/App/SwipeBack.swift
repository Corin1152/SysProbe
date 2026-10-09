import SwiftUI
import UIKit

/// 手势提交后的去向。
enum SwipeBackMode {
    /// 覆盖层（设置子页）：跟手平移，提交时回调让上层把自己关掉。
    case cover
    /// 普通分页：只识别手势（不平移——整个 `TabView` 底下没有可露出的页面），
    /// 提交时回调（切回第一屏硬件页）。
    case tab
}

/// 把当前环境整包交给子托管控制器。
///
/// `SwipeBackContainer` 的内容闭包是塞进独立 `UIHostingController` 的，**不会**
/// 自动继承环境（locale、environmentObject 都得手动带过去）。
///
/// 刻意写成**非泛型**：托管控制器与它都放在文件作用域，就是为了不让
/// `UIViewController` 落在泛型上下文里 —— 之前把 VC 嵌在泛型
/// `SwipeBackContainer<Content>` 内部时，它隐式带上泛型参数，编译 Release 时
/// 在 `deinit` 的 EarlyPerfInliner 里触发过编译器崩溃（Swift 6.3.3）。
struct SwipeBackInjectedContent: View {
    let content: AnyView
    let environment: EnvironmentValues

    var body: some View {
        content.environment(\.self, environment)
    }
}

/// 全屏「左滑返回」手势容器 —— 手势识别逻辑对齐系统交互式 pop 转场
/// （目标 dylib 的实现方式），按要求**不含触感反馈**。
///
/// 与 dylib 一致的部分：
///
/// - 手势是挂在整页上的**全屏** `UIPanGestureRecognizer`，不限于左边缘；
/// - `shouldBegin` 只认**横向主导、且方向向右**的速度（`|vx| > |vy|` 且 `vx > 0`），
///   与系统 pop 手势同一套判定；
/// - 与滚动视图的 pan **并存**（横向拖不被竖向列表吃掉），落在控件
///   （滑杆、开关等 `UIControl`）上的触摸一律**让位**；
/// - 覆盖层模式跟手平移，松手按 UIKit 交互式转场的默认阈值提交或回弹，
///   动画即系统 push/pop 的滑出样式。
///
/// 为什么用 `UIViewControllerRepresentable` 包一层，而不是 SwiftUI
/// `DragGesture`：分页里有滑杆这类 `UIControl`，SwiftUI 手势没有「手势器之间
/// 让位」的语义，会跟滑杆的拖动同时触发；UIKit 的 delegate 链才是 dylib
/// 那套冲突规则的原生载体。
struct SwipeBackContainer<Content: View>: UIViewControllerRepresentable {

    /// 手势是否启用。分页模式下由「不在第一屏、且没打开设置子页」决定。
    var enabled: Bool
    var mode: SwipeBackMode
    var onCommit: () -> Void
    @ViewBuilder var content: () -> Content

    /// 当前 SwiftUI 环境整包传给子托管控制器（见 `SwipeBackInjectedContent`）。
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> SwipeBackHostViewController {
        let controller = SwipeBackHostViewController()
        controller.mode = mode
        return controller
    }

    func updateUIViewController(_ controller: SwipeBackHostViewController, context: Context) {
        controller.mode = mode
        controller.onCommit = onCommit
        controller.setGestureEnabled(enabled)
        controller.setContent(
            SwipeBackInjectedContent(content: AnyView(content()), environment: environment)
        )
    }
}

/// 承载内容的控制器：一个全屏 pan 手势 + 一个装 SwiftUI 内容的子托管控制器。
///
/// 放在文件作用域、且**不带泛型参数** —— 见 `SwipeBackInjectedContent` 的说明。
@MainActor
final class SwipeBackHostViewController: UIViewController {

    var mode: SwipeBackMode = .tab
    var onCommit: (() -> Void)?

    private var hosting: UIHostingController<SwipeBackInjectedContent>?
    private var pan: UIPanGestureRecognizer?
    private let panDelegate = SwipeBackPanDelegate()
    /// 提交滑出动画期间不再响应新的平移，避免页面被拖回去。
    private var isCommitting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        panDelegate.owner = self
        recognizer.delegate = panDelegate
        view.addGestureRecognizer(recognizer)
        pan = recognizer
    }

    func setGestureEnabled(_ enabled: Bool) {
        pan?.isEnabled = enabled
    }

    func setContent(_ content: SwipeBackInjectedContent) {
        if let hosting {
            hosting.rootView = content
            return
        }
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        // 滑出时的前缘阴影：区分滑动层与下层页面（系统 pop 的视觉特征之一）。
        host.view.layer.shadowColor = UIColor.black.cgColor
        host.view.layer.shadowOpacity = 0.2
        host.view.layer.shadowRadius = 8
        host.view.layer.shadowOffset = CGSize(width: -4, height: 0)
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        hosting = host
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let hostView = hosting?.view else { return }
        hostView.frame = view.bounds
        hostView.layer.shadowPath = UIBezierPath(rect: hostView.bounds).cgPath
    }

    /// 触摸落点是否在控件（滑杆、开关等）里。
    func touchLandsOnControl(_ point: CGPoint) -> Bool {
        guard let hit = view.hitTest(point, with: nil) else { return false }
        var current: UIView? = hit
        while let node = current, node !== view {
            if node is UIControl { return true }
            current = node.superview
        }
        return false
    }

    // MARK: - 手势处理

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch mode {
        case .tab:
            // 分页模式不跟手：松手那一刻仍满足方向条件就切回第一屏。
            if recognizer.state == .ended {
                commitTabIfEligible(recognizer)
            }
        case .cover:
            dragCover(recognizer)
        }
    }

    /// 分页模式：位移与方向双重确认后才提交。
    private func commitTabIfEligible(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        guard translation.x > 60,
              velocity.x > 0,
              abs(velocity.x) > abs(velocity.y) else { return }
        onCommit?()
    }

    /// 覆盖层模式：跟手平移，松手按系统交互式转场的默认阈值提交或回弹。
    private func dragCover(_ recognizer: UIPanGestureRecognizer) {
        guard let hostView = hosting?.view, !isCommitting else { return }
        switch recognizer.state {
        case .changed:
            let x = max(0, recognizer.translation(in: view).x)
            hostView.transform = CGAffineTransform(translationX: x, y: 0)

        case .ended, .cancelled:
            let width = view.bounds.width
            let x = hostView.transform.tx
            let velocity = recognizer.velocity(in: view).x
            // 阈值对齐系统 pop：拖过屏宽的三分之一，或快速短拖，即完成返回。
            let shouldFinish = recognizer.state == .ended
                && (x > width / 3 || (velocity > 900 && x > 30))
            if shouldFinish {
                isCommitting = true
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    options: [.curveEaseIn, .beginFromCurrentState]
                ) {
                    hostView.transform = CGAffineTransform(translationX: width, y: 0)
                } completion: { _ in
                    hostView.transform = .identity
                    self.isCommitting = false
                    self.onCommit?()
                }
            } else {
                UIView.animate(
                    withDuration: 0.4,
                    delay: 0,
                    usingSpringWithDamping: 1,
                    initialSpringVelocity: 0,
                    options: [.beginFromCurrentState]
                ) {
                    hostView.transform = .identity
                }
            }

        default:
            break
        }
    }
}

/// 手势的 delegate：dylib 那套让位规则的等价实现。
///
/// 单独一个对象，而不是让控制器自己当 delegate：`UIViewController` 在 ObjC 里
/// 就带着 `gestureRecognizerShouldBegin:` 的实现，在 Swift 子类里重新实现它到底
/// 算不算覆盖，随 SDK 版本而变 —— 编译期就报过 `does not override any method
/// from its superclass`。独立的 `NSObject` 没有这层历史包袱。
final class SwipeBackPanDelegate: NSObject, UIGestureRecognizerDelegate {

    weak var owner: SwipeBackHostViewController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let owner,
              let recognizer = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = recognizer.velocity(in: owner.view)
        // 横向主导、且向右 —— 与 dylib（也即系统 pop 手势）同一套判定。
        guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) else { return false }
        // 落在控件（滑杆、开关等）上的触摸一律让位。
        return !owner.touchLandsOnControl(recognizer.location(in: owner.view))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 只与滚动视图并存：横向拖动不被竖向列表吃掉；竖向拖动时
        // `shouldBegin` 已经拒绝，不会误触发返回。
        otherGestureRecognizer.view is UIScrollView
    }
}
