import Charts
import MonitorCore
import SwiftUI

/// The full picture: throughput over time for the whole machine and the top apps,
/// with every app that used the network listed below.
struct DetailView: View {
    @Bindable var engine: MonitorEngine
    @State private var hovered: Date?

    private static let totalSeriesName = "All traffic"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            controls
            summary
            chart
            appList
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $engine.period) {
                ForEach(Period.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Scope", selection: $engine.scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Internet excludes loopback and local-only traffic")

            Spacer()

            if let errorMessage = engine.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.period.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatBytes(engine.periodTotal))
                    .font(.system(size: 28, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(formatBytes(engine.apps.reduce(0) { $0 + $1.received }), systemImage: "arrow.down")
                Label(formatBytes(engine.apps.reduce(0) { $0 + $1.sent }), systemImage: "arrow.up")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Throughput per \(engine.period.grainLabel)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if engine.totalSeries.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.grid.opacity(0.3))
                    .frame(height: 220)
                    .overlay {
                        Text("No history for this period yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            } else {
                let data = chartData
                Chart {
                    ForEach(data.rows) { row in
                        LineMark(
                            x: .value("Time", row.date),
                            y: .value("Bytes", row.bytes),
                            series: .value("Series", row.series)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", row.series))
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: row.series == Self.totalSeriesName ? 2 : 1.5,
                                lineCap: .round
                            )
                        )
                    }

                    if let hovered, let marker = nearestPoint(to: hovered) {
                        RuleMark(x: .value("Time", marker.date))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(Theme.grid)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                tooltip(at: marker.date, data: data)
                            }
                    }
                }
                .chartForegroundStyleScale(domain: data.names, range: data.colors)
                .chartXSelection(value: $hovered)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Theme.grid)
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(formatBytes(UInt64(max(0, bytes))))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Theme.grid.opacity(0.6))
                        AxisTick().foregroundStyle(Theme.grid)
                        AxisValueLabel()
                    }
                }
                .chartLegend(position: .bottom, spacing: 12)
                .frame(height: 220)
            }
        }
    }

    private func tooltip(at date: Date, data: ChartData) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(engine.period.tooltipFormat))
                .font(.caption2.weight(.semibold))

            ForEach(Array(data.names.enumerated()), id: \.element) { index, name in
                if let bytes = data.values[name]?[date] {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(data.colors[index])
                            .frame(width: 6, height: 6)
                        Text(name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(formatBytes(bytes))
                            .monospacedDigit()
                    }
                    .font(.caption2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 220)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
    }

    // MARK: - App list

    private var appList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("All apps")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(engine.apps.count) with traffic")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(engine.apps.enumerated()), id: \.element.id) { index, app in
                        DetailRow(
                            app: app,
                            share: Double(app.total) / Double(max(engine.apps.first?.total ?? 1, 1)),
                            color: Theme.color(slot: engine.colorSlots[app.key])
                        )
                        .background(index.isMultiple(of: 2) ? Color.clear : Theme.grid.opacity(0.25))
                    }
                }
            }
            .frame(minHeight: 140)
        }
    }

    // MARK: - Series plumbing

    private struct SeriesRow: Identifiable {
        let series: String
        let date: Date
        let bytes: UInt64

        var id: String { "\(series)@\(date.timeIntervalSince1970)" }
    }

    /// Everything the chart needs, built in one pass. The tooltip used to look values
    /// up by rebuilding this for every series on every hover frame.
    private struct ChartData {
        let rows: [SeriesRow]
        let names: [String]
        let colors: [Color]
        let values: [String: [Date: UInt64]]
    }

    /// The total line plus one line per charted app.
    ///
    /// Each app is given a value at every bucket the chart plots, zero included. A
    /// sparse series would otherwise draw a straight line across the quiet stretches,
    /// implying traffic that never happened — and an app seen in a single bucket, like
    /// a one-off download, would have no line to draw at all.
    private var chartData: ChartData {
        let buckets = engine.totalSeries.map(\.date)

        var rows = engine.totalSeries.map {
            SeriesRow(series: Self.totalSeriesName, date: $0.date, bytes: $0.bytes)
        }
        var names = [Self.totalSeriesName]
        var colors = [Theme.total]
        var values = [Self.totalSeriesName: Dictionary(
            engine.totalSeries.map { ($0.date, $0.bytes) },
            uniquingKeysWith: +
        )]

        for app in engine.topApps {
            guard let points = engine.appSeries[app.key] else { continue }

            let name = seriesName(for: app, taken: names)
            let byBucket = Dictionary(points.map { ($0.date, $0.bytes) }, uniquingKeysWith: +)
            let filled = Dictionary(uniqueKeysWithValues: buckets.map { ($0, byBucket[$0] ?? 0) })

            // Built from `buckets`, not `filled`: a line connects its points in data
            // order, and a dictionary has none.
            rows += buckets.map { SeriesRow(series: name, date: $0, bytes: filled[$0] ?? 0) }
            names.append(name)
            colors.append(Theme.color(slot: engine.colorSlots[app.key]))
            values[name] = filled
        }

        return ChartData(rows: rows, names: names, colors: colors, values: values)
    }

    /// Display names aren't unique — two copies of an app, or two daemons sharing a
    /// filename, would otherwise collapse into one zigzagging series drawn across both
    /// apps' values.
    private func seriesName(for app: AppUsage, taken: [String]) -> String {
        let base = app.displayName
        guard taken.contains(base) else { return base }

        let folder = ((app.key as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folder.isEmpty ? app.key : "\(base) (\(folder))"
    }

    /// Selection reports an interpolated x, so snap to the bucket actually plotted.
    private func nearestPoint(to date: Date) -> UsagePoint? {
        engine.totalSeries.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
}

private struct DetailRow: View {
    let app: AppUsage
    let share: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image(for: app))
                .resizable()
                .frame(width: 18, height: 18)

            Text(app.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, alignment: .leading)

            Capsule()
                .fill(color)
                .frame(height: 4)
                .scaleEffect(x: max(share, 0.01), y: 1, anchor: .leading)
                .frame(maxWidth: .infinity)

            Group {
                Label(formatBytes(app.received), systemImage: "arrow.down")
                    .frame(width: 84, alignment: .trailing)
                Label(formatBytes(app.sent), systemImage: "arrow.up")
                    .frame(width: 84, alignment: .trailing)
                Text(formatBytes(app.total))
                    .frame(width: 74, alignment: .trailing)
                    .fontWeight(.medium)
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(app.displayName), \(formatBytes(app.received)) received, \(formatBytes(app.sent)) sent"
        )
    }
}

extension Period {
    var grainLabel: String {
        switch self {
        case .day: "minute"
        case .week: "hour"
        case .month: "day"
        }
    }

    var tooltipFormat: Date.FormatStyle {
        switch self {
        case .day: .dateTime.hour().minute()
        case .week: .dateTime.weekday().hour()
        case .month: .dateTime.month().day()
        }
    }
}
