import Charts
import MonitorCore
import SwiftUI

/// The menu bar dropdown. Deliberately small: one headline total, the live rate, and
/// the five biggest apps. Everything else lives in the detail window.
struct CompactView: View {
    @Bindable var engine: MonitorEngine
    let openDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            liveRate
            topApps
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 290)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(engine.period.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(engine.periodTotal))
                    .font(.system(size: 22, weight: .semibold))
            }

            Picker("Period", selection: $engine.period) {
                ForEach(Period.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var liveRate: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(engine.isLive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Label(formatRate(engine.rate.received), systemImage: "arrow.down")
                Label(formatRate(engine.rate.sent), systemImage: "arrow.up")
                Spacer()
            }
            .font(.system(.caption, design: .rounded))
            .monospacedDigit()
            .labelStyle(.titleAndIcon)

            Sparkline(history: engine.rateHistory)
                .frame(height: 30)
                .accessibilityLabel("Throughput over the last minute")
        }
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top apps")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if engine.topApps.isEmpty {
                Text(engine.errorMessage ?? "No traffic yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                let largest = engine.topApps.first?.total ?? 1
                ForEach(engine.topApps) { app in
                    AppRow(
                        app: app,
                        share: largest > 0 ? Double(app.total) / Double(largest) : 0,
                        color: Theme.color(slot: engine.colorSlots[app.key])
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Picker("Scope", selection: $engine.scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Internet excludes loopback and local-only traffic")

            Spacer()

            Button("Details…", action: openDetail)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.caption)
    }
}

/// One app in the top-five list: identity on the left, magnitude on the right, with a
/// thin bar carrying the comparison.
private struct AppRow: View {
    let app: AppUsage
    let share: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcon.image(for: app))
                .resizable()
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(formatBytes(app.total))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                Capsule()
                    .fill(color)
                    .frame(width: nil, height: 3)
                    .scaleEffect(x: max(share, 0.01), y: 1, anchor: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.displayName), \(formatBytes(app.total))")
    }
}

/// Last minute of throughput. One series, so it needs no legend — the label above
/// names it.
private struct Sparkline: View {
    let history: [MonitorEngine.Rate]

    var body: some View {
        Chart(Array(history.enumerated()), id: \.offset) { index, rate in
            AreaMark(x: .value("Sample", index), y: .value("Bytes per second", rate.total))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    .linearGradient(
                        colors: [Theme.total.opacity(0.28), Theme.total.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            LineMark(x: .value("Sample", index), y: .value("Bytes per second", rate.total))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.total)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...Double(max(MonitorEngine.sparklineLength - 1, 1)))
        .chartYScale(domain: 0...yMax)
        .chartPlotStyle { $0.background(Theme.grid.opacity(0.35)).clipShape(.rect(cornerRadius: 4)) }
        .chartLegend(.hidden)
    }

    /// A floor keeps an idle connection from drawing noise as a full-height mountain.
    private var yMax: Double {
        max(history.map(\.total).max() ?? 0, 64_000)
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
