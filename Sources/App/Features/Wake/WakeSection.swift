import SwiftUI
// `strerror` —— 把 errno 翻译成一句话，写进页脚。
import Darwin

/// 维护页里的「网络唤醒」区。
///
/// 内容：设备列表（名称 + MAC／IP）、每行的唤醒按钮、新增／编辑／删除。
///
/// ── 几个刻意的设计选择 ──────────────────────────────────────────────────────
///
/// · **唤醒按钮放在行内，编辑／删除放滑动操作。** 行内再塞两个按钮会挤成一团，
///   而且这个区的主要动作就是「唤醒」—— 它该是伸手就够到的那个；
/// · **滑动删除不开全滑**（`allowsFullSwipe: false`）：删掉一台设备只要再填一次就能回来，
///   但误删的观感很差，不值得省这一次点击；
/// · **缺 MAC 时唤醒按钮禁用**，而不是等点了再报错 —— 见 `WakeDevice.canWake`；
/// · 反馈写在页脚，不用弹窗：维护页上层已经挂了确认弹窗与全屏覆盖，
///   再加一个 alert 只会互相抢呈现。
struct WakeSection: View {
    @StateObject private var store = WakeStore()

    /// 当前打开的编辑页。`nil` = 不显示。
    @State private var editor: WakeEditor?
    /// 上一次唤醒的结果。写在页脚里。
    @State private var outcome: WakeResult?

    var body: some View {
        Section {
            if store.devices.isEmpty {
                Text("No devices yet.")
                    .foregroundStyle(Color.mwMuted)
            } else {
                ForEach(store.devices) { device in
                    WakeDeviceRow(device: device) {
                        wake(device)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.remove(device)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editor = WakeEditor(isNew: false, device: device)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                }
            }

            Button {
                editor = WakeEditor(isNew: true, device: WakeDevice(name: "", mac: "", host: ""))
            } label: {
                Label("Add Device", systemImage: "plus")
            }
        } header: {
            Text("Wake on LAN")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("A magic packet is sent to this network's broadcast address. The target machine needs Wake on LAN enabled in its firmware, and this phone needs to be on the same Wi-Fi.")
                // 反馈写在这里 —— 见类型头最后一条。
                if let outcome {
                    Text(verbatim: outcomeText(outcome))
                        .foregroundStyle(outcome.ok ? Color.mwAccent : Color.mwDanger)
                }
            }
        }
        .sheet(item: $editor) { item in
            WakeEditorSheet(isNew: item.isNew, device: item.device) { saved in
                if item.isNew {
                    store.add(name: saved.name, mac: saved.mac, host: saved.host)
                } else {
                    store.update(saved)
                }
                editor = nil
            } onCancel: {
                editor = nil
            }
        }
    }

    // MARK: - 动作

    /// 发魔术包。
    ///
    /// 子进程不用起，但 `getifaddrs` + `sendto` 仍会占住调用线程一小会儿，
    /// 所以与 `DeviceActions` 那几个调用一样放到主 actor 之外。
    private func wake(_ device: WakeDevice) {
        guard let mac = WakeService.parseMAC(device.mac) else {
            outcome = WakeResult()
            return
        }
        let host = device.host
        Task {
            let result = await Task.detached { WakeService.wake(mac: mac, host: host) }.value
            outcome = result
        }
    }

    private func outcomeText(_ result: WakeResult) -> String {
        if result.ok {
            return Strings.text("Magic packet sent.") + " " + result.delivered.joined(separator: ", ")
        }
        guard let first = result.failed.first else {
            return Strings.text("Could not send the magic packet.")
        }
        return Strings.text("Could not send the magic packet.") + " "
            + String(cString: strerror(first.code))
    }
}

/// 编辑页的身份。
///
/// 用一份**草稿**而不是直接改 `devices` 里的元素：用户可能改到一半点取消，
/// 那不该在列表里留下痕迹。
private struct WakeEditor: Identifiable {
    let id = UUID()
    var isNew: Bool
    var device: WakeDevice
}

// MARK: - 行

private struct WakeDeviceRow: View {
    let device: WakeDevice
    let wake: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.name.isEmpty ? Strings.text("Untitled") : device.name)
                Text(verbatim: device.subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.mwMuted)
            }
            Spacer(minLength: 8)
            Button {
                wake()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
            }
            .disabled(!device.canWake)
            // **这个修饰符是必需的，不是装饰**：默认样式下这一整行会变成一个命中区域，
            // 点哪儿都触发这个按钮（与维护区那两个按钮同一个坑）。
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - 编辑页

private struct WakeEditorSheet: View {
    let isNew: Bool
    let device: WakeDevice
    let onSave: (WakeDevice) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var mac: String
    @State private var host: String

    init(isNew: Bool,
         device: WakeDevice,
         onSave: @escaping (WakeDevice) -> Void,
         onCancel: @escaping () -> Void) {
        self.isNew = isNew
        self.device = device
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: device.name)
        _mac = State(initialValue: device.mac)
        _host = State(initialValue: device.host)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Strings.text("Name"), text: $name)
                    TextField(Strings.text("MAC Address"), text: $mac)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .font(.system(.body, design: .monospaced))
                    TextField(Strings.text("IP Address"), text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.decimalPad)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Device")
                } footer: {
                    Text("Waking needs the MAC address. The IP is optional — leave it empty to send to this network's broadcast address.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(isNew ? Strings.text("Add Device") : Strings.text("Edit Device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        var updated = device
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.mac = mac.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    /// 名称与 MAC 都得有 —— MAC 少了叫不醒（见 `WakeDevice`），名称少了列表里是一行空白。
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && WakeService.parseMAC(mac) != nil
    }
}
