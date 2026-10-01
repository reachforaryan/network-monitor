import AppKit
import SwiftUI

@main
struct NetworkMonitorApp: App {
    static let detailWindowID = "detail"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(engine: delegate.engine)
        } label: {
            Image(systemName: "network")
        }
        .menuBarExtraStyle(.window)

        Window("Network Usage", id: Self.detailWindowID) {
            DetailView(engine: delegate.engine)
        }
        .defaultSize(width: 860, height: 640)
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

/// Sampling has to start at launch, not when the dropdown is first opened, so it is
/// kicked off here rather than from a view's `task`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = MonitorEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()
    }
}
