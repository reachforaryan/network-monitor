import AppKit
import MonitorCore
import ServiceManagement
import SwiftUI

@main
struct NetworkMonitorApp: App {
    static let detailWindowID = "detail"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(engine: delegate.engine)
        } label: {
            MenuBarLabel(engine: delegate.engine)
        }
        .menuBarExtraStyle(.window)

        Window("Network Usage", id: Self.detailWindowID) {
            DetailView(engine: delegate.engine)
        }
        .defaultSize(width: 860, height: 640)
    }
}

/// Live throughput in the menu bar itself, so the common question — is something
/// using the network right now, and how much — needs no click.
///
/// The rate collapses to the bare icon when idle rather than sitting at zero, which
/// would be permanent clutter for most of the day.
private struct MenuBarLabel: View {
    let engine: MonitorEngine

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "network")

            if engine.isLive {
                Text("↓\(compactRate(engine.rate.received)) ↑\(compactRate(engine.rate.sent))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
        }
    }
}

/// Wrapper so the dropdown can reach `openWindow`, which isn't available in `App`'s
/// own body.
private struct MenuBarContent: View {
    let engine: MonitorEngine

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        CompactView(engine: engine) {
            openWindow(id: NetworkMonitorApp.detailWindowID)
            // A menu bar app isn't frontmost, so the new window needs bringing forward.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Launch-at-login, which only works for a real bundle — under `swift run` there is
/// nothing registrable, so the toggle reads as off and setting it does nothing.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}

/// Sampling has to start at launch, not when the dropdown is first opened, so it is
/// kicked off here rather than from a view's `task`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = MonitorEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DS.registerFonts()
        engine.start()
    }
}
