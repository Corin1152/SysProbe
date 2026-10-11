import SwiftUI
import UIKit

/// 「清理」页：磁盘缓存扫描与清理（移植自对 iOSCleanerPro 1.0 的分析，见
/// `Tools/RootTool.c` 的来源说明）。
///
/// ── 刻意不做的三件事 ──────────────────────────────────────────────────────
///
///   1. **不自动扫描**。打开页面就跑一次几十秒的递归统计，是拿用户的电与耐心
///      换一行数字；扫描由按钮触发，扫完之前整个页面只有「扫描」一个动作。
///   2. **不显示任何估算值**。工具没扫出来的（比如系统应用取不到显示名）就退回
///      bundle id，没实测到缓存的 App 就不进列表 —— 样本里那段「Safari 150 MB」
///      式的占位数据是这页的反面教材。
///   3. **不提供逐文件视图**。工具按目录与应用容器清理，粒度到「哪一类 / 哪个 App」
///      为止 —— 再细就是文件管理器了，不是维护功能。
///
/// ── 并发与失败模式 ────────────────────────────────────────────────────────
///
/// 阻塞调用全部走 `Task.detached`（与 `MaintenanceView` 同一约定）。清理没有
/// 「取消」：子进程在后台把活干完，界面这边超时只会报「没返回结果」，
/// 绝不提示用户「失败了」却让 root 工具继续删 —— 那两种状态必须分开。
struct CleanView: View {

    /// 工具能不能用。`nil` = 还没测出来；与维护页同一套自检（`DeviceActions.probe()`），
    /// 两个页面各自跑一次毫秒级的子进程，不为共用状态引入跨页耦合。
    @State private var toolReady: Bool?

    @State private var scan: StorageScanResult?
    @State private var isScanning = false
    @State private var scanFailed = false

    @State private var isCleaning = false
    /// 最近一次清理释放的字节数。只显示最近一次，不做累计 —— 累计值跨操作
    /// 含义会漂移（这次清了 A，下次清了 B，加起来什么都不是）。
    @State private var lastFreed: Int64?
    @State private var cleanFailed = false

    /// 正在等确认的清理目标。`nil` = 没有待确认的操作。
    ///
    /// 所有清理动作（全部 / 分项 / 单个 App）共用一个确认弹窗，标题与说明按
    /// 目标拼 —— 与维护页两个动作共弹窗的写法一致，避免快速连点时错位。
    @State private var pendingClean: CleanTarget?
    @State private var isConfirming = false

    /// 图标缓存。`NSCache` 是线程安全的类，作为引用类型挂在 `@State` 上
    /// 随视图存续即可，不值得为它造一个 ObservableObject。
    @State private var iconCache = NSCache<NSString, UIImage>()

    /// 「受保护」的应用 bundle id —— 「清理应用缓存」与「一键清理全部」都会跳过它们。
    ///
    /// 落 `UserDefaults`：这是用户的长期选择，不该每次进页面都忘掉。
    /// 没用 `@AppStorage` 是因为它没有集合形态（只支持 String/Int/Bool/URL/Data…），
    /// 硬塞一个分隔符拼接的字符串反而更绕。
    @State private var protectedBundles: Set<String> = []

    /// 预览卡片里哪几类展开了。存 rawValue，默认全收起 ——
    /// 四类全展开最多 24 行，会把页面拉得很长。
    @State private var expandedPreviews: Set<String> = []

    var body: some View {
        ZStack {
            Color.mwCanvas
            Backdrop(glow: .mwAccent)
            ScrollView {
                VStack(spacing: 12) {
                    totalHeader
                    actionButtons

                    if let scan {
                        appsSection
                        previewSection
                        footerNotes()
                    } else {
                        toolRow
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .mwContainerWidth()
            }
        }
        .navigationTitle("Clean")
        .navigationBarTitleDisplayMode(.inline)
        // 自检要起一个子进程并等它结束（毫秒级，但最长会等到 1 秒），放到
        // 主 actor 之外 —— 与维护页同一句话，同一个理由。
        .task {
            toolReady = await Task.detached { DeviceActions.probe() }.value
            loadProtectedBundles()
        }
        .confirmationDialog(
            Text(verbatim: confirmTitle),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(confirmActionLabel, role: .destructive) {
                if let target = pendingClean {
                    Task { await performClean(target) }
                }
            }
            Button("Cancel", role: .cancel) { pendingClean = nil }
        } message: {
            Text(verbatim: confirmMessage)
        }
        .alert("Scan failed.", isPresented: $scanFailed) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("The root tool did not return a result. Check the Root tool line on the About page.")
        }
        .alert("Could not run the cleaner.", isPresented: $cleanFailed) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("The root tool did not return a result. Check the Root tool line on the About page.")
        }
    }

    // MARK: 版式

    // 这一页的版式照上游 iOSCleanerPro 1.0：**居中的合计 + 一条强调色分隔线 +
    // 一列全宽圆角大按钮**，而不是设置页那种分组列表。配色与字体仍用本 App 的
    // 设计 token（`mwAccent` / `AppFont`），不照搬上游的纯蓝 + 系统字体 ——
    // 那会让这一页在 App 内部看起来是另一个程序。

    /// 顶部：可清理量 + 分隔线。原版也是这两样，位置和含义都一致。
    private var totalHeader: some View {
        VStack(spacing: 10) {
            Group {
                if let scan {
                    Text(Strings.text("Cleanable: %@",
                                      Formatting.bytes(UInt64(cleanableBytes(scan)))))
                } else if isScanning {
                    Text("Measuring…")
                } else {
                    Text("Tap Scan to measure what can be cleaned.")
                }
            }
            .font(AppFont.text(14))
            .foregroundStyle(Color.mwMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)

            Capsule()
                .fill(Color.mwAccent)
                .frame(height: 2)
        }
        .padding(.bottom, 2)
    }

    /// 一列全宽大按钮。顺序与上游一致：扫描 → 各分项 → 一键清理全部（红色）。
    ///
    /// 每个按钮**自带金额**（`detail`），因为「清哪个更划算」是用户按按钮前唯一
    /// 想知道的事 —— 上游也是把大小写在标题里。区别是这里不做「清理应用缓存」
    /// 之外的合并：上游那一个按钮清全部应用，这里也保留，另加「日志」一项
    /// （上游把日志并进了系统缓存）。
    private var actionButtons: some View {
        VStack(spacing: 10) {
            bigButton(title: Strings.text(scan == nil ? "Scan" : "Rescan"),
                      detail: nil,
                      icon: "magnifyingglass",
                      busy: isScanning,
                      enabled: toolReady == true && !isScanning && !isCleaning) {
                Task { await runScan() }
            }

            ForEach(detailScopes, id: \.rawValue) { scope in
                bigButton(title: title(for: scope),
                          detail: bytesText(for: scope),
                          icon: icon(for: scope),
                          busy: false,
                          enabled: toolReady == true && scan != nil && !isCleaning) {
                    request(.category(scope))
                }
            }

            bigButton(title: Strings.text("Clean app caches"),
                      detail: appBytesText,
                      icon: "square.grid.2x2",
                      busy: false,
                      enabled: toolReady == true && scan != nil && !isCleaning) {
                request(.category(.apps))
            }

            bigButton(title: Strings.text("Clean All"),
                      detail: totalBytesText,
                      icon: "paintbrush.fill",
                      busy: isCleaning,
                      enabled: toolReady == true && scan != nil && !isCleaning,
                      destructive: true) {
                request(.all)
            }
        }
    }

    /// 一个全宽按钮。`detail` 为 nil 时不显示后缀（「扫描」就没有量可写）。
    ///
    /// 底色是实心的 `mwAccent`／`mwDanger`，所以前景色写死白色 —— 这是这一页
    /// 唯一一处不用 `mwInk` 的地方，理由是它压在强调色上而不是画布上。
    private func bigButton(title: String,
                           detail: String?,
                           icon: String,
                           busy: Bool,
                           enabled: Bool,
                           destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)
                Text(verbatim: title)
                    .font(AppFont.text(15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let detail {
                    Text(verbatim: detail)
                        .font(AppFont.text(14))
                        .opacity(0.85)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView().tint(.white)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(destructive ? Color.mwDanger : Color.mwAccent)
            )
            // **只按「工具能不能用」决定浓淡，不按「有没有扫描结果」。**
            //
            // 上一版是按 `enabled` 来的，于是没扫描时下面五个按钮全是 0.35 的淡蓝，
            // 只有最上面的「扫描」是实心 —— 一排按钮两种深浅，看着像坏了。
            // 未扫描时它们本来就点不动（没有目标），但那属于「还不能点」，
            // 不属于「这个功能不可用」，不该用同一种视觉表达。
            .opacity(toolReady == true ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 分项里出现的四类目录。照片缓存与下载目录是评估时砍掉的，别加回来。
    private let detailScopes: [StorageCleanScope] = [.system, .logs, .temp, .update]

    private func icon(for scope: StorageCleanScope) -> String {
        switch scope {
        case .system: return "shippingbox"
        case .logs: return "doc.text"
        case .temp: return "clock.arrow.circlepath"
        case .update: return "arrow.down.circle"
        default: return "folder"
        }
    }

    /// 按钮上那个大小文案。
    ///
    /// **0 单独处理**：`ByteCountFormatter` 在 `allowedUnits` 不含 byte 时会把 0
    /// 格式化成 "Zero KB" 这种半截结果 —— 而这一页「某项是 0」是很常见的状态
    /// （刚清完、或本来就没有日志）。统一成 `0 B`，所有语言都读得通，
    /// 也不用为它新引一条本地化键。
    private func bytesLabel(_ value: Int64) -> String {
        value <= 0 ? "0 B" : Formatting.bytes(UInt64(value))
    }

    private func bytesText(for scope: StorageCleanScope) -> String? {
        guard let scan else { return nil }
        let bytes: Int64
        switch scope {
        case .system: bytes = scan.systemBytes
        case .logs: bytes = scan.logsBytes
        case .temp: bytes = scan.tempBytes
        case .update: bytes = scan.updateBytes
        default: bytes = 0
        }
        return bytesLabel(bytes)
    }

    private func title(for scope: StorageCleanScope) -> String {
        switch scope {
        case .system: return Strings.text("Clean system cache")
        case .logs: return Strings.text("Clean logs")
        case .temp: return Strings.text("Clean temp files")
        case .update: return Strings.text("Clean update files")
        default: return scope.rawValue
        }
    }

    /// 预览卡片里那一行的短标题。与按钮标题（动词开头）不同 ——
    /// 预览是名词性的「这一类里有什么」。
    private func previewTitle(for scope: StorageCleanScope) -> String {
        switch scope {
        case .system: return Strings.text("System cache")
        case .logs: return Strings.text("Logs")
        case .temp: return Strings.text("Temp files")
        case .update: return Strings.text("Update files")
        default: return scope.rawValue
        }
    }

    /// 本次实际能清掉的字节数：四类目录 + 未被保护的应用缓存。
    /// 顶部「可清理」与两个大按钮共用这一个口径。
    private func cleanableBytes(_ scan: StorageScanResult) -> Int64 {
        scan.cleanableBytes(protecting: protectedBundles)
    }

    /// 全部应用缓存的合计，给「清理应用缓存」那个按钮。
    private var appBytesText: String? {
        guard let scan else { return nil }
        let total = scan.apps
            .filter { !protectedBundles.contains($0.bundle) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return bytesLabel(total)
    }

    private var totalBytesText: String? {
        guard let scan else { return nil }
        return bytesLabel(cleanableBytes(scan))
    }

    /// 工具状态一行 + 页脚说明。扫完之前显示工具状态，扫完之后并进页脚。
    private var toolRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Root tool", value: DeviceActions.toolSummary(ready: toolReady))
                .font(AppFont.text(13))
            Text("Sizes are measured live from the privileged root tool. Cleaning deletes the contents of each directory and keeps the directories themselves; everything here is regenerated as needed.")
                .font(AppFont.text(11))
                .foregroundStyle(Color.mwMuted)
            Text("The system cache clean keeps a small set of critical system items: location learning, Siri, and iCloud sync state.")
                .font(AppFont.text(11))
                .foregroundStyle(Color.mwMuted)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.mwCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwCardStroke, lineWidth: 1)
        )
    }

    /// 扫完之后的页脚：释放量 + 工具状态 + 两条说明。
    ///
    /// 不接 `scan` 参数 —— 它要的东西（`lastFreed` / `toolReady`）都在 `self` 上，
    /// 传进来反而让读者以为用了扫描结果。
    private func footerNotes() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let freed = lastFreed, freed > 0 {
                Text(Strings.text("Freed %@", Formatting.bytes(UInt64(freed))))
                    .font(AppFont.text(13, weight: .semibold))
                    .foregroundStyle(Color.mwAccent)
            }
            LabeledContent("Root tool", value: DeviceActions.toolSummary(ready: toolReady))
                .font(AppFont.text(12))
            Text("Sizes are measured live from the privileged root tool. Cleaning deletes the contents of each directory and keeps the directories themselves; everything here is regenerated as needed.")
                .font(AppFont.text(11))
                .foregroundStyle(Color.mwMuted)
            // 排除名单的存在要在这里说，而不是只在确认弹窗里 —— 弹窗一闪就没，
            // 页脚才是用户会回头核对的地方。
            Text("The system cache clean keeps a small set of critical system items: location learning, Siri, and iCloud sync state.")
                .font(AppFont.text(11))
                .foregroundStyle(Color.mwMuted)
        }
        .padding(.top, 4)
    }

    // MARK: 应用缓存

    /// 按 App 的缓存列表。每行两个图标按钮：盾牌（保护，不参与批量清理）与
    /// 垃圾桶（只清这一个）。整行不是点击区域，名字那一列不带任何动作 ——
    /// 误触面越小越好。
    ///
    /// 卡片而不是 Form 分组：这一页已经改成「大按钮 + 卡片」的版式，再混一个
    /// 系统分组列表进来，两种行高与边距会互相打架。卡片底色、描边、圆角用的
    /// 是同一组设计 token。
    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App caches")
                .font(AppFont.text(13, weight: .semibold))
                .foregroundStyle(Color.mwMuted)

            if let scan {
                if scan.apps.isEmpty {
                    Text("No app caches were measured.")
                        .font(AppFont.text(13))
                        .foregroundStyle(Color.mwMuted)
                }
                ForEach(scan.apps) { app in
                    HStack(spacing: 10) {
                        AppIconView(bundlePath: app.bundlePath, cache: iconCache)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: app.name)
                                .font(AppFont.text(15, weight: .medium))
                                .lineLimit(1)
                            Text(verbatim: app.bundle)
                                .font(AppFont.text(11))
                                .foregroundStyle(Color.mwMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(Formatting.bytes(UInt64(app.bytes)))
                            .font(AppFont.mono(13))
                            .foregroundStyle(Color.mwMuted)
                        // 保护开关。**不是 `Toggle`**：这一行已经有另一个图标按钮，
                        // 系统开关的体量会把应用名挤掉。
                        //
                        // 被保护的行压到 0.6 透明度 —— 视觉上「这次不参与」，
                        // 但垃圾桶按钮仍然可用：保护只挡批量清理，不挡点名清理。
                        Button {
                            toggleProtection(app.bundle)
                        } label: {
                            Image(systemName: isProtected(app.bundle) ? "shield.fill" : "shield")
                                .font(.system(size: 15))
                                .foregroundStyle(isProtected(app.bundle)
                                                 ? Color.mwAccent : Color.mwMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isCleaning)
                        .accessibilityLabel(Strings.text(isProtected(app.bundle)
                                                         ? "Allow cleaning" : "Protect from cleaning"))
                        Button {
                            request(.app(bundle: app.bundle, name: app.name))
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.mwDanger)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isCleaning)
                    }
                    .opacity(isProtected(app.bundle) ? 0.6 : 1)
                }

                Text("Only apps whose cache could actually be measured are listed. Names and icons come from the app bundles; when they cannot be read, the bundle identifier is shown.")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)

                Text("Tap the shield to protect an app. Protected apps are skipped by Clean app caches and Clean All; the trash button still cleans one on its own.")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)

                // 一个应用缓存都没实测到时，把工具回传的诊断行摊开。三种失败原因
                // （容器目录打不开 / MCM 元数据读不出 / Caches 真是空的）在界面上
                // 长得一模一样，不给这几行就只能靠猜。正常扫到东西时不显示。
                if scan.apps.isEmpty, !scan.diagnostics.isEmpty {
                    Text("Root tool diagnostics")
                        .font(AppFont.text(12, weight: .semibold))
                        .padding(.top, 2)
                    ForEach(scan.diagnostics, id: \.self) { line in
                        Text(verbatim: line)
                            .font(AppFont.mono(11))
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.mwCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwCardStroke, lineWidth: 1)
        )
    }

    // MARK: 预览

    /// 「将要删除什么」的预览。
    ///
    /// 只列工具**实测到**的条目（每类最大 6 条），没有任何估算或示例数据 ——
    /// 与这一页「不显示任何估算值」的原则一致。
    ///
    /// 折叠而不是全铺开：四类全展开最多 24 行，而多数时候用户只想扫一眼
    /// 「哪一类最占地方」。收起状态下每行右边就是该类的实测总量，
    /// 已经足够做那个判断。
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What will be removed")
                .font(AppFont.text(13, weight: .semibold))
                .foregroundStyle(Color.mwMuted)

            if let scan {
                ForEach(previewScopes(in: scan), id: \.rawValue) { scope in
                    previewRow(scope: scope, items: scan.previewEntries(for: scope))
                }

                Text("The largest items measured in each category — this is what cleaning deletes. Items that are in use are skipped and left in place.")
                    .font(AppFont.text(11))
                    .foregroundStyle(Color.mwMuted)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.mwCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwCardStroke, lineWidth: 1)
        )
    }

    /// 预览里的一行：标题 + 该类总量，点一下展开条目。
    ///
    /// 用 `Button` 而不是 `DisclosureGroup` + 自定义 `Binding`：这一页已经有两处
    /// 手写 `Binding`（`MaintenanceView` 的开关），而这里只是「展开/收起」，
    /// 一个 `Set` 加一个按钮就说清楚了。
    private func previewRow(scope: StorageCleanScope,
                            items: [StorageScanResult.Preview]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                togglePreview(scope)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expandedPreviews.contains(scope.rawValue)
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mwMuted)
                        .frame(width: 12)
                    Text(verbatim: previewTitle(for: scope))
                        .font(AppFont.text(13))
                    Spacer(minLength: 8)
                    Text(verbatim: bytesText(for: scope) ?? "")
                        .font(AppFont.mono(12))
                        .foregroundStyle(Color.mwMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedPreviews.contains(scope.rawValue) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Text(verbatim: item.name)
                                .font(AppFont.text(12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Formatting.bytes(UInt64(item.bytes)))
                                .font(AppFont.mono(12))
                                .foregroundStyle(Color.mwMuted)
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: 保护名单与预览展开

    /// 保护名单的持久化键。与 `PowerMonitor.wattHoursKey` 同一写法 ——
    /// 键收在类型内部，别处不再写第二遍字面量。
    private static let protectedBundlesKey = "clean.protectedBundles"

    /// 哪些类别有可预览的条目。空的那类不占一行 —— 一行「0 B」没有信息量。
    private func previewScopes(in scan: StorageScanResult) -> [StorageCleanScope] {
        detailScopes.filter { !scan.previewEntries(for: $0).isEmpty }
    }

    private func togglePreview(_ scope: StorageCleanScope) {
        if expandedPreviews.contains(scope.rawValue) {
            expandedPreviews.remove(scope.rawValue)
        } else {
            expandedPreviews.insert(scope.rawValue)
        }
    }

    private func isProtected(_ bundle: String) -> Bool {
        protectedBundles.contains(bundle)
    }

    /// 切换保护状态并立即落盘。**不等待确认**：保护是保守动作，多保护一个
    /// 应用不会删掉任何东西；要它弹窗只会让人懒得去保护。
    private func toggleProtection(_ bundle: String) {
        if protectedBundles.contains(bundle) {
            protectedBundles.remove(bundle)
        } else {
            protectedBundles.insert(bundle)
        }
        // 排序后存：`UserDefaults` 里是一份稳定顺序的数组，人工查看时好读。
        UserDefaults.standard.set(protectedBundles.sorted(), forKey: Self.protectedBundlesKey)
    }

    private func loadProtectedBundles() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.protectedBundlesKey) ?? []
        protectedBundles = Set(stored)
    }

    // MARK: 确认与执行

    private func request(_ target: CleanTarget) {
        pendingClean = target
        isConfirming = true
    }

    private var confirmTitle: String {
        switch pendingClean {
        case .all: return Strings.text("Clean all caches?")
        case .category(.system): return Strings.text("Delete the system cache?")
        case .category(.logs): return Strings.text("Delete the logs?")
        case .category(.temp): return Strings.text("Delete the temporary files?")
        case .category(.update): return Strings.text("Delete the update files?")
        case .category(.apps): return Strings.text("Delete every app's cache?")
        case .app(_, let name): return Strings.text("Delete the cache of %@?", name)
        case .none, .category(.app), .category(.all):
            return ""
        }
    }

    private var confirmActionLabel: String {
        pendingClean == .all ? Strings.text("Clean All") : Strings.text("Clean")
    }

    private var confirmMessage: String {
        switch pendingClean {
        case .all:
            return Strings.text("The contents of the system cache, the logs, the temporary files, the update files and every app's cache directory are deleted. Everything here is regenerated by the system and the apps as needed.")
        case .category(.system):
            return Strings.text("The contents of the system cache directory are deleted. A small set of critical system items — location learning, Siri, iCloud sync state — is kept.")
        case .category(.logs):
            return Strings.text("The contents of the system log directories are deleted.")
        case .category(.temp):
            return Strings.text("The contents of /var/tmp are deleted.")
        case .category(.update):
            return Strings.text("Downloaded system update files are deleted. The system downloads an update again the next time one is offered.")
        case .category(.apps):
            return Strings.text("Every app's cache directory is emptied. Apps rebuild their caches as needed; if one is running, restart it afterwards.")
        case .app(_, _):
            return Strings.text("This app rebuilds its cache as needed. If it is running, restart it afterwards.")
        case .none, .category(.app), .category(.all):
            return ""
        }
    }

    /// 真的去执行。清完**自动重扫**：不重扫的话界面上的数字停留在清理前，
    /// 用户唯一能做的就是手动再点一次扫描 —— 那不如直接做掉。重扫是只读操作，
    /// 代价可以接受。
    private func performClean(_ target: CleanTarget) async {
        guard !isCleaning else { return }
        isCleaning = true

        // 保护名单先拍成快照再进后台：`Task.detached` 里读不到主 actor 上的
        // `@State`，而这个数组本身就是 `Sendable` 的。
        let protected = protectedBundles.sorted()

        let result: StorageCleanResult?
        switch target {
        case .all:
            result = await Task.detached {
                StorageCleaner.clean(.all, exclude: protected)
            }.value
        case .category(let scope):
            // 分项里的 system / logs / temp / update 都碰不到应用容器，名单传下去
            // 也没人用；只有 `.apps` 真的需要它。统一传，少一个分支。
            result = await Task.detached {
                StorageCleaner.clean(scope, exclude: protected)
            }.value
        case .app(let bundle, _):
            // 点名清一个应用时不传名单 —— 用户明确要清它，保护不该反过来挡掉。
            result = await Task.detached {
                StorageCleaner.clean(.app, bundleId: bundle)
            }.value
        }

        isCleaning = false
        guard let result else {
            cleanFailed = true
            return
        }
        lastFreed = result.freedBytes
        await runScan()
    }

    /// 扫描。阻塞调用放主 actor 之外；失败置位给 alert，不在这里说话。
    private func runScan() async {
        guard !isScanning else { return }
        isScanning = true
        scanFailed = false

        let result = await Task.detached { StorageCleaner.scan() }.value

        isScanning = false
        if let result {
            scan = result
        } else {
            scanFailed = true
        }
    }
}

/// 等确认的清理目标。三个来源：主按钮（全部）、分项行（某一类）、应用行（某个 App）。
fileprivate nonisolated enum CleanTarget: Equatable {
    case all
    case category(StorageCleanScope)
    case app(bundle: String, name: String)
}

/// 应用图标。取图路径与样本一致：包根目录下 actool 渲染出来的 60×60@2x，
/// 没有就退回 1x，再没有就显示占位符号 —— **绝不画假图标**。
private struct AppIconView: View {
    let bundlePath: String?
    let cache: NSCache<NSString, UIImage>

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.mwMuted)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: bundlePath) { await load() }
    }

    private func load() async {
        guard let bundlePath, image == nil else { return }
        let key = bundlePath as NSString
        if let cached = cache.object(forKey: key) {
            image = cached
            return
        }
        // 读文件放主 actor 之外：列表一滚就是几十个包路径的磁盘读。
        //
        // 跨这条边界传回来的是 `Data` 而不是 `UIImage`：`Data` 的 `Sendable` 是
        // 确定的，而 `UIImage` 的隔离与 `Sendable` 性跟着 UIKit 的标注走
        // （`@MainActor` / `@unchecked Sendable` 在不同 SDK 上不一样），不值得为
        // 省一次 60×60 的解码去赌 SDK 版本。解码留在主 actor 上，单张是微秒级。
        let data = await Task.detached(priority: .utility) { () -> Data? in
            for name in ["AppIcon60x60@2x.png", "AppIcon60x60.png"] {
                let path = bundlePath + "/" + name
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty {
                    return data
                }
            }
            return nil
        }.value
        guard let data, let loaded = UIImage(data: data) else { return }
        cache.setObject(loaded, forKey: key)
        image = loaded
    }
}
