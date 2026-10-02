import Charts
import MonitorCore
import SwiftUI

/// The full picture: throughput over time for the machine and its top apps, with every
/// app that used the network listed below.
struct DetailView: View {
    @Bindable var engine: MonitorEngine
    @State private var hovered: Date?

    private static let totalSeriesName = "ALL TRAFFIC"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summary
            chart
            appList
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 540)
        .background(DS.ground)
        .sheet(item: $engine.sessionsApp) { app in
            SessionView(app: app, engine: engine)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NET_CTRL // ANALYSIS")
                    .font(DS.display(13))
                    .foregroundStyle(DS.ink)
                Text("PER-PROCESS BANDWIDTH HISTORY")
                    .font(DS.mono(8))
                    .tracking(1)
                    .foregroundStyle(DS.inkSecondary)
            }

            Spacer()

            // Wide gap so the two selectors don't read as one five-option row.
            HStack(spacing: 18) {
                TabRow(options: Period.allCases, selection: $engine.period) { $0.label }
                    .frame(width: 230)
                TabRow(options: Scope.allCases, selection: $engine.scope) {
                    $0 == .internet ? "NET" : "ALL"
                }
                .frame(width: 130)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Panel {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("TOTAL_\(engine.period.label)")
                    Text(formatBytes(engine.periodTotal))
                        .font(DS.display(22))
                        .foregroundStyle(DS.ink)
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("RECEIVED")
                    Text(formatBytes(engine.periodReceived))
                        .font(DS.mono(15, weight: .bold))
                        .foregroundStyle(DS.inkSecondary)
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("SENT")
                    Text(formatBytes(engine.periodSent))
                        .font(DS.mono(15, weight: .bold))
                        .foregroundStyle(DS.inkSecondary)
                }
            }

            if let errorMessage = engine.errorMessage {
                Panel {
                    Text(errorMessage.uppercased())
                        .font(DS.mono(8))
                        .foregroundStyle(DS.inkMuted)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel("THROUGHPUT_PER_\(engine.period.grainLabel)")

            if engine.totalSeries.isEmpty {
                Panel {
                    Text("// NO HISTORY FOR THIS PERIOD YET")
                        .font(DS.mono(9))
                        .foregroundStyle(DS.inkMuted)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            } else {
                let data = chartData
                Chart {
                    // The total is a filled backdrop, not a line: drawn as a white line it
                    // sat right on top of whichever app dominated and read as an outline
                    // around it. As an area, the apps read against "everything".
                    ForEach(data.rows) { row in
                        if row.series == Self.totalSeriesName {
                            AreaMark(x: .value("Time", row.date), y: .value("Bytes", row.bytes))
                                .interpolationMethod(DS.curve)
                                .foregroundStyle(by: .value("Series", row.series))
                        } else {
                            LineMark(
                                x: .value("Time", row.date),
                                y: .value("Bytes", row.bytes),
                                series: .value("Series", row.series)
                            )
                            .interpolationMethod(DS.curve)
                            .foregroundStyle(by: .value("Series", row.series))
                            .lineStyle(DS.lineStyle(width: 1.5))
                        }
                    }

                    if let hovered, let marker = nearestPoint(to: hovered) {
                        RuleMark(x: .value("Time", marker.date))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle(DS.inkMuted)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                tooltip(at: marker.date, data: data)
                            }
                    }
                }
                .chartForegroundStyleScale(domain: data.names, range: data.colors)
                .chartXSelection(value: $hovered)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(DS.grid)
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(formatBytes(UInt64(max(0, bytes))))
                                    .font(DS.mono(8))
                                    .foregroundStyle(DS.inkMuted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(DS.grid)
                        AxisValueLabel()
                            .font(DS.mono(8))
                            .foregroundStyle(DS.inkMuted)
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 210)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous).fill(DS.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                        .strokeBorder(DS.border, lineWidth: 1)
                )

                legend(data)
            }
        }
    }

    /// Built by hand rather than with `chartLegend`, so the swatches are square blocks
    /// in the same language as everything else.
    private func legend(_ data: ChartData) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(data.names.enumerated()), id: \.element) { index, name in
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(data.colors[index])
                        .frame(width: 8, height: 8)
                        // The total's fill is deliberately dim; an outline keeps its
                        // swatch findable against the black.
                        .overlay(Rectangle().strokeBorder(index == 0 ? DS.inkMuted : .clear, lineWidth: 1))
                    Text(name.uppercased())
                        .font(DS.mono(8))
                        .foregroundStyle(DS.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private func tooltip(at date: Date, data: ChartData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(engine.period.tooltipFormat).uppercased())
                .font(DS.mono(8, weight: .bold))
                .foregroundStyle(DS.ink)

            ForEach(Array(data.names.enumerated()), id: \.element) { index, name in
                if let bytes = data.values[name]?[date] {
                    HStack(spacing: 5) {
                        Rectangle()
                            .fill(data.colors[index])
                            .frame(width: 6, height: 6)
                        Text(name.uppercased())
                            .lineLimit(1)
                            .foregroundStyle(DS.inkSecondary)
                        Spacer(minLength: 10)
                        Text(formatBytes(bytes))
                            .foregroundStyle(DS.ink)
                    }
                    .font(DS.mono(8))
                }
            }
        }
        .padding(9)
        .frame(maxWidth: 230)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(DS.ground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(DS.border, lineWidth: 1)
        )
    }

    // MARK: - App list

    private var appList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                SectionLabel("ALL_APPS")

                // Shows what is hidden rather than presenting a filtered list as the
                // whole picture.
                Text(
                    engine.apps.count == engine.unfilteredCount
                        ? "[\(engine.apps.count)]"
                        : "[\(engine.apps.count)/\(engine.unfilteredCount)]"
                )
                .font(DS.mono(8, weight: .bold))
                .foregroundStyle(DS.inkMuted)

                Spacer()

                searchField

                BracketButton(
                    title: engine.filter.appsOnly ? "APPS_ONLY" : "ALL_PROCS",
                    emphasized: engine.filter.appsOnly
                ) {
                    engine.filter.appsOnly.toggle()
                }
                .frame(width: 118)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(engine.apps.enumerated()), id: \.element.id) { index, app in
                        DetailRow(
                            app: app,
                            share: engine.share(of: app),
                            color: DS.seriesColor(slot: engine.colorSlots[app.key]),
                            striped: !index.isMultiple(of: 2)
                        ) {
                            engine.sessionsApp = app
                        }
                    }
                }
            }
            .frame(minHeight: 130)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Text(">")
                .font(DS.mono(9, weight: .bold))
                .foregroundStyle(DS.inkMuted)

            TextField("SEARCH", text: $engine.filter.search)
                .textFieldStyle(.plain)
                .font(DS.mono(9))
                .foregroundStyle(DS.ink)

            if !engine.filter.search.isEmpty {
                Button {
                    engine.filter.search = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7))
                        .foregroundStyle(DS.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 190)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(DS.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(DS.border, lineWidth: 1)
        )
    }

    // MARK: - Series plumbing

    private struct SeriesRow: Identifiable {
        let series: String
        let date: Date
        let bytes: UInt64

        var id: String { "\(series)@\(date.timeIntervalSince1970)" }
    }

    /// Everything the chart needs, built in one pass. The tooltip used to look values up
    /// by rebuilding this for every series on every hover frame.
    private struct ChartData {
        let rows: [SeriesRow]
        let names: [String]
        let colors: [Color]
        let values: [String: [Date: UInt64]]
    }

    /// The total line plus one line per charted app.
    ///
    /// Each app is given a value at every bucket the chart plots, zero included. A sparse
    /// series would otherwise draw a straight line across the quiet stretches, implying
    /// traffic that never happened — and an app seen in a single bucket, like a one-off
    /// download, would have no line to draw at all.
    private var chartData: ChartData {
        let buckets = engine.totalSeries.map(\.date)

        var rows = engine.totalSeries.map {
            SeriesRow(series: Self.totalSeriesName, date: $0.date, bytes: $0.bytes)
        }
        var names = [Self.totalSeriesName]
        var colors = [DS.totalFill]
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
            colors.append(DS.seriesColor(slot: engine.colorSlots[app.key]))
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

/// One app. The whole row opens its sessions, and says so: a `[ SESSIONS ]` cue that
/// lights on hover, since a plain data row gives no hint it can be clicked.
private struct DetailRow: View {
    let app: AppUsage
    let share: Double
    let color: Color
    let striped: Bool
    let openSessions: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: openSessions) { content }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(app.displayName), \(formatBytes(app.received)) received, \(formatBytes(app.sent)) sent"
            )
            .accessibilityHint("Shows this app's sessions")
    }

    private var content: some View {
        HStack(spacing: 10) {
            IconTile(app: app, size: 22)

            Text(app.displayName.uppercased())
                .font(DS.mono(10, weight: .bold))
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 150, alignment: .leading)

            HatchedBar(fraction: share, height: 7, tint: color)
                .frame(maxWidth: .infinity)

            Group {
                Text("↓ \(formatBytes(app.received))").frame(width: 92, alignment: .trailing)
                Text("↑ \(formatBytes(app.sent))").frame(width: 92, alignment: .trailing)
                Text(formatBytes(app.total))
                    .foregroundStyle(DS.ink)
                    .frame(width: 80, alignment: .trailing)
            }
            .font(DS.mono(9))
            .foregroundStyle(DS.inkSecondary)

            Text("[ SESSIONS ]")
                .font(DS.mono(8, weight: .bold))
                .foregroundStyle(isHovering ? DS.ink : DS.inkMuted)
                .frame(width: 86, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isHovering ? DS.panelRaised : (striped ? DS.panel.opacity(0.6) : DS.ground))
        .contentShape(Rectangle())
    }
}

extension Period {
    var grainLabel: String {
        switch self {
        case .day: "MINUTE"
        case .week: "HOUR"
        case .month: "DAY"
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
