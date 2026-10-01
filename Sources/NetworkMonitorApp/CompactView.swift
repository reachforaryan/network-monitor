import Charts
import MonitorCore
import SwiftUI

/// The menu bar dropdown. Deliberately small: one headline total, the live rate, and the
/// five biggest apps. Filters and settings live behind CONFIG so this panel stays calm.
struct CompactView: View {
    @Bindable var engine: MonitorEngine
    let openDetail: () -> Void

    @State private var showConfig = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TabRow(options: Period.allCases, selection: $engine.period) { $0.label }

            totalPanel

            // The count is only known for the scope currently being queried, so it is
            // shown on the active tab rather than guessed for both.
            TabRow(
                options: Scope.allCases,
                selection: $engine.scope,
                badge: { $0 == engine.scope ? engine.apps.count : nil }
            ) { $0 == .internet ? "NET" : "ALL" }

            topApps

            TickRuler()

            footer
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
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionLabel("TOTAL_USAGE")
                    Spacer()
                    Text(engine.period.headline.uppercased())
                        .font(DS.mono(8))
                        .tracking(1)
                        .foregroundStyle(DS.inkMuted)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(formatBytes(engine.periodTotal))
                        .font(DS.display(19))
                        .foregroundStyle(DS.ink)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        rateLine("↓", formatRate(engine.rate.received))
                        rateLine("↑", formatRate(engine.rate.sent))
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
                if engine.apps.count > engine.topApps.count {
                    Text("[\(engine.topApps.count)/\(engine.apps.count)]")
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
                let largest = engine.topApps.first?.total ?? 1
                VStack(spacing: 7) {
                    ForEach(engine.topApps) { app in
                        AppRow(
                            app: app,
                            share: largest > 0 ? Double(app.total) / Double(largest) : 0,
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
                    Text("\(Int((share * 100).rounded()))%")
                        .font(DS.mono(8))
                        .foregroundStyle(DS.inkMuted)
                        .frame(width: 26, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.displayName), \(formatBytes(app.total))")
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
            .foregroundStyle(value > 0 ? DS.ink : DS.border)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...yMax)
        .chartLegend(.hidden)
        .frame(height: 30)
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
