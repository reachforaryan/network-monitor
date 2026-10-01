import MonitorCore
import SwiftUI

/// Settings popover. Everything here would clutter the dropdown if it sat on the panel.
struct ConfigView: View {
    @Bindable var engine: MonitorEngine

    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("CONFIG")

            VStack(alignment: .leading, spacing: 6) {
                BracketButton(
                    title: launchAtLogin ? "AUTO: ON" : "AUTO: OFF",
                    emphasized: launchAtLogin
                ) {
                    launchAtLogin.toggle()
                    LoginItem.set(launchAtLogin)
                    // Registration fails when running unbundled, so report what actually
                    // happened rather than leaving the button lit against nothing.
                    launchAtLogin = LoginItem.isEnabled
                }

                Text("// START AT LOGIN")
                    .font(DS.mono(8))
                    .foregroundStyle(DS.inkMuted)
            }
        }
        .padding(12)
        .frame(width: 210)
        .background(DS.ground)
    }
}
