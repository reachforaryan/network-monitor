import Charts
import MonitorCore
import SwiftUI

/// The menu bar dropdown. Deliberately small: one headline total, the live rate, and the
/// five biggest apps. Filters and settings live behind CONFIG so this panel stays calm.
struct CompactView: View {
    @Bindable var engine: MonitorEngine
    let openDetail: () -> Void

    @State private var showConfig = false
    @AppStorage("rateInBits") private var rateInBits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 8) {
                TabRow(options: Period.allCases, selection: $engine.period) { $0.label }
                totalPanel
            }

            topApps

            VStack(spacing: 10) {
                TickRuler()
                footer
            }
        }
        .padding(12)
        .frame(width: 310)
        .background(DS.ground)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NET_CTRL // TRAFFIC")
                    .font(DS.display(11))
                    .tracking(0.5)
                    .foregroundStyle(DS.ink)
                Text("PER-PROCESS BANDWIDTH")
                    .font(DS.mono(8))
                    .tracking(1)
                    .foregroundStyle(DS.inkSecondary)
            }

            Spacer()

            HStack(spacing: 5) {
                Rectangle()
                    .fill(engine.isLive ? DS.live : DS.inkMuted)
                    .frame(width: 5, height: 5)
                Text(engine.isLive ? "LIVE" : "IDLE")
                    .font(DS.mono(8, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(engine.isLive ? DS.ink : DS.inkMuted)
            }
        }
    }

    private var totalPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel("TOTAL_USAGE")
                    Spacer()
                    // Scope sits here because it qualifies this number, not just the
                    // list. The period is already named by the tabs above, so the
                    // old "TODAY" caption was repeating the selected tab back.
                    TabRow(options: Scope.allCases, selection: $engine.scope, compact: true) {
                        $0 == .internet ? "NET" : "ALL"
                    }
                    .frame(width: 92)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(formatBytes(engine.periodTotal))
                        .font(DS.display(19))
                        .foregroundStyle(DS.ink)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        rateLine("↓", formatRate(engine.rate.received, bits: rateInBits))
                        rateLine("↑", formatRate(engine.rate.sent, bits: rateInBits))
                    }
                }

                Sparkline(history: engine.rateHistory)
                    .accessibilityLabel("Throughput over the last minute")
            }
        }
    }

    private func rateLine(_ arrow: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(arrow).foregroundStyle(DS.inkMuted)
            Text(value).foregroundStyle(DS.inkSecondary)
        }
        .font(DS.mono(9))
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("TOP_APPS")
                Spacer()
                if engine.unfilteredCount > engine.topApps.count {
                    Text("[\(engine.topApps.count)/\(engine.unfilteredCount)]")
                        .font(DS.mono(8, weight: .bold))
                        .foregroundStyle(DS.inkMuted)
                }
            }

            if engine.topApps.isEmpty {
                Text(engine.errorMessage?.uppercased() ?? "// NO TRAFFIC RECORDED")
                    .font(DS.mono(9))
                    .foregroundStyle(DS.inkMuted)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 7) {
                    ForEach(engine.topApps) { app in
                        AppRow(
                            app: app,
                            share: engine.share(of: app),
                            color: DS.seriesColor(slot: engine.colorSlots[app.key])
                        )
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            BracketButton(title: "Details", action: openDetail)

            BracketButton(title: "Config", icon: "gearshape") { showConfig.toggle() }
                .popover(isPresented: $showConfig, arrowEdge: .bottom) {
                    ConfigView(engine: engine)
                }

            BracketButton(title: "Quit") {
                Task {
                    await engine.flushBeforeQuit()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

/// One app in the top-five list: identity, magnitude, and a hatched share bar.
private struct AppRow: View {
    let app: AppUsage
    let share: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            IconTile(app: app)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(app.displayName.uppercased())
                        .font(DS.mono(10, weight: .bold))
                        .tracking(0.3)
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Text(formatBytes(app.total))
                        .font(DS.mono(9))
                        .foregroundStyle(DS.inkSecondary)
                }

                HStack(spacing: 6) {
                    HatchedBar(fraction: share, height: 7, tint: color)
                    Text(percentage)
                        .font(DS.mono(8))
                        .foregroundStyle(DS.inkMuted)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.displayName), \(formatBytes(app.total)), \(percentage) of total")
    }

    /// Rounding a real but tiny share to "0%" reads as "used nothing", which is a
    /// different claim from "used a little".
    private var percentage: String {
        let percent = share * 100
        if percent > 0, percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }
}

/// Last minute of throughput as discrete bars — one per sample, newest at the right.
/// Blocky rather than smoothed, to match everything around it.
private struct Sparkline: View {
    let history: [MonitorEngine.Rate]

    var body: some View {
        Chart(Array(padded.enumerated()), id: \.offset) { index, value in
            BarMark(
                x: .value("Sample", index),
                y: .value("Bytes per second", value),
                width: .fixed(3)
            )
            .foregroundStyle(value > 0 ? DS.ink : DS.hairline)
            .cornerRadius(1.5)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...yMax)
        .chartLegend(.hidden)
        .frame(height: 24)
        .chartPlotStyle {
            $0.clipShape(RoundedRectangle(cornerRadius: DS.radiusMark, style: .continuous))
        }
    }

    /// Left-padded so the newest sample stays pinned to the right edge instead of the
    /// chart stretching while history fills up.
    private var padded: [Double] {
        let values = history.map(\.total)
        let missing = max(0, MonitorEngine.sparklineLength - values.count)
        return Array(repeating: 0, count: missing) + values
    }

    /// A floor keeps idle background chatter from drawing as a full-height mountain.
    private var yMax: Double {
        max(padded.max() ?? 0, 64_000)
    }
}

extension Period {
    var headline: String {
        switch self {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        }
    }
}
