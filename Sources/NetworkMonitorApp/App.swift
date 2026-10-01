import SwiftUI

@main
struct NetworkMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("Network Monitor", systemImage: "network") {
            Text("Collecting…")
        }
        .menuBarExtraStyle(.window)
    }
}
