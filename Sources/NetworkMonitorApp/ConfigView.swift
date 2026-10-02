import AppKit
import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings popover. Everything here would clutter the dropdown if it sat on the panel.
struct ConfigView: View {
    @Bindable var engine: MonitorEngine

    @AppStorage("rateInBits") private var rateInBits = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var exportStatus: String?

    /// Round numbers rather than a free-form field: this is noise reduction, not a
    /// measurement.
    private static let thresholds: [UInt64] = [0, 100_000, 1_000_000, 10_000_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("FILTERS") {
                BracketButton(
                    title: engine.filter.appsOnly ? "APPS_ONLY: ON" : "APPS_ONLY: OFF",
                    emphasized: engine.filter.appsOnly
                ) {
                    engine.filter.appsOnly.toggle()
                }

                caption("HIDE SYSTEM PROCESSES")

                TabRow(
                    options: Self.thresholds,
                    selection: $engine.filter.minimumBytes
                ) { $0 == 0 ? "OFF" : formatBytes($0).replacingOccurrences(of: " ", with: "") }

                caption("MIN_TRAFFIC PER APP")
            }

            section("UNITS") {
                BracketButton(
                    title: rateInBits ? "RATE: MBPS" : "RATE: MB/S",
                    emphasized: rateInBits
                ) {
                    rateInBits.toggle()
                }

                caption("SPEEDS IN BITS, AS ISPS QUOTE THEM")
            }

            section("STARTUP") {
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

                caption("START AT LOGIN")
            }

            section("DATA") {
                BracketButton(title: "Export CSV", icon: "square.and.arrow.down", action: export)
                caption(exportStatus ?? "CURRENT PERIOD AND SCOPE")
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(DS.ground)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text("// \(text)")
            .font(DS.mono(8))
            .foregroundStyle(DS.inkMuted)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = engine.suggestedExportName
        panel.allowedContentTypes = [.commaSeparatedText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try engine.exportCSV(to: url)
            exportStatus = "SAVED \(engine.apps.count) ROWS"
        } catch {
            exportStatus = "EXPORT FAILED"
        }
    }
}
