import SwiftUI

/// 设置面板。**三行菜单，各自进一页。**
///
/// 从首页右上角的齿轮打开。原来是一整页 —— 维护动作、语言、十来行诊断信息、
/// 致谢全摊在同一个 `Form` 里；现在拆成三页，因为诊断那一段本身就有十来行，
/// 摊在菜单里会把另外两项挤到屏幕外。
///
/// 三个入口刻意做成 `NavigationLink` 而不是把内容铺开：这一页的职责是**导航**，
/// 不是承载内容。要改哪一块就去哪一页，返回时 `NavigationStack` 自己记得位置。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// 「频段设置」那一行是否显示。默认显示。
    ///
    /// 频段写错会导致无服务，所以那一页里留了一个关掉入口的开关（原版也有）。
    /// 关掉之后菜单只剩两行，而且**没有地方能再打开** —— 这是故意的：
    /// 一个能被随手关掉、又能随手打开的开关挡不住误触。
    @AppStorage("sysprobe.showBandEditor") private var showBandEditor = true

    var body: some View {
        NavigationStack {
            // 画布铺在 `Form` **外面**、与它做兄弟节点，而不是 `Form` 的 `.background`。
            //
            // 两处差别都是看得见的：`NavigationStack` 自己的底色是系统分组色，只铺 `Form`
            // 的话导航栏那一条露出来的是它；而弹入／退出转场的第一帧若内容还没画上，
            // 露出来的同样是它 —— 深色下是近黑、浅色下是灰白，看起来就是整屏闪一下。
            ZStack {
                Color.mwCanvas
                Backdrop(glow: .mwAccent)
                Form {
                    Section {
                        NavigationLink {
                            MaintenanceView()
                        } label: {
                            Label("Maintenance", systemImage: "wrench.and.screwdriver")
                        }

                        if showBandEditor {
                            NavigationLink {
                                BandEditorView()
                            } label: {
                                Label("Network Bands", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }

                        NavigationLink {
                            AboutView()
                        } label: {
                            Label("About", systemImage: "info.circle")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .mwSheetBackground()
    }
}
