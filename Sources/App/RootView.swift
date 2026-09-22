import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var monitor: PowerMonitor
    @EnvironmentObject private var hardware: HardwareMonitor
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HardwareView()
                .tabItem { Label("Hardware", systemImage: "cpu") }
            DashboardView()
                .tabItem { Label("Power", systemImage: "bolt.fill") }
            AdapterView()
                .tabItem { Label("Adapter", systemImage: "powerplug.fill") }
        }
        .tint(.mwAccent)
        // iOS 16: the two-parameter `onChange(of:initial:)` is iOS 17-only, so the
        // first run is done explicitly in `onAppear`.
        .onAppear {
            monitor.start()
            hardware.start()
            UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                monitor.start()
                hardware.start()
            case .background:
                monitor.pause()
                hardware.pause()
            default:
                break
            }
        }
        .onChange(of: shouldStayAwake) { awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }

    /// Hold the screen on, but only while it is actually earning something: the app
    /// is in front and the phone is plugged in.
    private var shouldStayAwake: Bool {
        monitor.keepScreenAwakeWhileCharging
            && monitor.snapshot.externalConnected
            && scenePhase == .active
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringResource
    var glow: Color = .mwAccent
    var toolbar: AnyView?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringResource,
         glow: Color = .mwAccent,
         toolbar: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.toolbar = toolbar
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop(glow: glow)
                ScrollView {
                    LazyVStack(spacing: 14) {
                        content()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    // Pinned to the container's width so nothing inside can widen the
                    // scroll content.
                    .mwContainerWidth()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if let toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { toolbar }
                }
            }
        }
    }
}
