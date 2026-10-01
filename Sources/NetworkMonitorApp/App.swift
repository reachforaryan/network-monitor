import AppKit
import SwiftUI

@main
struct NetworkMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            CompactView(engine: delegate.engine, openDetail: {})
        } label: {
            Image(systemName: "network")
        }
        .menuBarExtraStyle(.window)
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
