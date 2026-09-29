import SwiftUI

/// 「关于」页。版本号 + 移植来源的署名。
///
/// 署名不是客套：MiniWatts 是 Apache-2.0、ChargeLimiter 是 GPL-3.0，
/// 用了别人的代码就得说清楚。第三段刻意写成「本仓库自己实现、只参考了两个常量」——
/// 照实写比含糊地写「移植自某某」更准确。
struct AboutView: View {
    var body: some View {
        ZStack {
            Color.mwCanvas
            Backdrop(glow: .mwAccent)
            Form {
                Section {
                    // 排查问题时第一步就是确认装的是哪一版。
                    LabeledContent("App version", value: AppInfo.version)
                } header: {
                    Text("Version")
                }

                Section {
                    Text("Power and adapter readings are ported from MiniWatts, © the MiniWatts authors, licensed under the Apache License 2.0. They are read from Apple's private IOKit interfaces — read-only, no writes — which is why this app is sideload-only.")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                    Text("Charge control is ported from ChargeLimiter, © lich4, licensed under the GNU GPL v3. Its daemon is fetched from the upstream release at build time rather than stored in this repository.")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                    // 署名照实写：代码是本仓库自己写的，只有两个「在真机上验证过的
                    // 取值」参考了 RebootTools。别把这条写成「移植自某某」——那不准。
                    Text("Reboot and respring are implemented in this repository rather than reused from another app. The two constants they rely on — reboot(0) and the signal sent to SpringBoard — follow RebootTools by dongchenshuo, which credits 肖博vlog for the reboot core.")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                    // 「频段设置」是后加的功能，署名同样照实写。
                    Text("Network band configuration reads and writes baseband bands through Apple's private CoreTelephony interfaces. The call shape follows CellularInfo by DevelopCubeLab, licensed under the GNU GPL v3.")
                        .font(.footnote)
                        .foregroundStyle(Color.mwMuted)
                } header: {
                    Text("Credits")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
