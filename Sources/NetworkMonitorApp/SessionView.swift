import Charts
import MonitorCore
import SwiftUI

/// An app's sessions: a strip comparing recent ones, and the selected session in full —
/// what it cost, how long it ran, and how hard it pulled minute by minute. Answers
/// "how much did that evening of cloud gaming use?", which period totals can't.
struct SessionView: View {
    let app: AppUsage
    let engine: MonitorEngine

    @AppStorage("rateInBits") private var rateInBits = false
    @State private var sessions: [AppSession]?
    @State private var selectedID: Date?
    @State private var hoveredBar: Date?
    @State private var hoveredMinute: Date?
    @Environment(\.dismiss) private var dismiss

    private static let stripCount = 30

    private var selected: AppSession? {
        sessions?.first { $0.id == selectedID } ?? sessions?.first
    }

    /// The app's chart color when it has one, so it reads as the same app as the main
    /// chart; otherwise the first series hue rather than gray, which would look disabled.
    private var tint: Color {
        engine.colorSlots[app.key].map { DS.seriesColor(slot: $0) } ?? DS.series[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let sessions, sessions.isEmpty {
                Text("// NO SESSIONS RECORDED YET")
                    .font(DS.mono(9))
                    .foregroundStyle(DS.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sessions, let selected {
                strip(Array(sessions.prefix(Self.stripCount).reversed()), selected: selected)
                stats(selected)
                rateChart(selected)
                list(sessions, selected: selected)
            } else {
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 640, height: 640)
        .background(DS.ground)
        .task { sessions = await engine.sessions(for: app.key) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(app: app, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName.uppercased())
                    .font(DS.mono(11, weight: .bold))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                SectionLabel("SESSIONS // INTERNET")
            }
            Spacer()
            BracketButton(title: "CLOSE") { dismiss() }
                .frame(width: 80)
        }
    }

    // MARK: - Strip

    /// One bar per session, oldest left. Click picks a session; hover names it.
    private func strip(_ recent: [AppSession], selected: AppSession) -> some View {
        Chart(recent) { session in
            BarMark(
                x: .value("Session", key(session)),
                y: .value("Bytes", session.bytes)
            )
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            .foregroundStyle(session.id == selected.id ? tint : DS.hairline)

            if session.id == hoveredBar {
                RuleMark(x: .value("Session", key(session)))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        tooltip(
                            session.start.formatted(.dateTime.weekday().day().hour().minute()).uppercased(),
                            formatBytes(session.bytes)
                        )
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 2)) { value in
                AxisGridLine().foregroundStyle(DS.grid)
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(formatBytes(UInt64(max(0, bytes)))).font(DS.mono(8)).foregroundStyle(DS.inkMuted)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        if let id = session(at: location, proxy: proxy, geometry: geometry, in: recent) {
                            selectedID = id
                        }
                    }
                    .onContinuousHover { phase in
                        if case .active(let location) = phase {
                            hoveredBar = session(at: location, proxy: proxy, geometry: geometry, in: recent)
                        } else {
                            hoveredBar = nil
                        }
                    }
            }
        }
        .frame(height: 70)
        .accessibilityLabel("Recent sessions by data used")
    }

    /// Categories must be unique strings; the session's end is its identity.
    private func key(_ session: AppSession) -> String {
        String(Int(session.end.timeIntervalSince1970))
    }

    private func session(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        in recent: [AppSession]
    ) -> Date? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = location.x - geometry[plot].origin.x
        guard let category: String = proxy.value(atX: x) else { return nil }
        return recent.first { key($0) == category }?.id
    }

    // MARK: - Selected session

    private func stats(_ session: AppSession) -> some View {
        HStack(spacing: 10) {
            Panel {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("SESSION_TOTAL")
                    Text(formatBytes(session.bytes))
                        .font(DS.display(22))
                        .foregroundStyle(DS.ink)
                    Text(
                        session.start.formatted(.dateTime.weekday().day().month().hour().minute()).uppercased()
                            + " → " + session.end.formatted(.dateTime.hour().minute())
                    )
                    .font(DS.mono(8))
                    .foregroundStyle(DS.inkMuted)
                }
            }
            stat("DURATION", Duration.seconds(session.duration).formatted(
                .units(allowed: [.hours, .minutes], width: .narrow)
            ))
            stat("AVG_RATE", formatRate(session.averageRate, bits: rateInBits))
            stat("PEAK_RATE", formatRate(session.peakRate, bits: rateInBits))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(label)
                Text(value)
                    .font(DS.mono(13, weight: .bold))
                    .foregroundStyle(DS.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Throughput across the session, as a rate so it reads like the stream setting
    /// ("45 Mbps") rather than as bytes per minute.
    private func rateChart(_ session: AppSession) -> some View {
        let points = filled(session)

        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel("THROUGHPUT // PER_MINUTE")

            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Rate", Double(point.bytes) / 60))
                        .interpolationMethod(DS.curve)
                        .foregroundStyle(tint.opacity(0.18))
                    LineMark(x: .value("Time", point.date), y: .value("Rate", Double(point.bytes) / 60))
                        .interpolationMethod(DS.curve)
                        .foregroundStyle(tint)
                        .lineStyle(DS.lineStyle(width: 2))
                }

                if let hoveredMinute, let point = points.min(by: {
                    abs($0.date.timeIntervalSince(hoveredMinute)) < abs($1.date.timeIntervalSince(hoveredMinute))
                }) {
                    RuleMark(x: .value("Time", point.date))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .foregroundStyle(DS.inkMuted)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            tooltip(
                                point.date.formatted(.dateTime.hour().minute()),
                                formatRate(Double(point.bytes) / 60, bits: rateInBits)
                            )
                        }
                }
            }
            .chartXSelection(value: $hoveredMinute)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(DS.grid)
                    AxisValueLabel {
                        if let rate = value.as(Double.self) {
                            Text(formatRate(rate, bits: rateInBits)).font(DS.mono(8)).foregroundStyle(DS.inkMuted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(DS.grid)
                    AxisValueLabel().font(DS.mono(8)).foregroundStyle(DS.inkMuted)
                }
            }
            .frame(height: 150)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous).fill(DS.panel))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
        }
    }

    /// Every minute of the session, zero where nothing was recorded, so a pause draws as
    /// a dip instead of a straight line implying traffic that never happened.
    private func filled(_ session: AppSession) -> [UsagePoint] {
        let recorded = Dictionary(session.points.map { ($0.date, $0.bytes) }, uniquingKeysWith: +)
        return stride(from: session.start, to: session.end, by: 60).map {
            UsagePoint(date: $0, bytes: recorded[$0] ?? 0)
        }
    }

    // MARK: - List

    private func list(_ sessions: [AppSession], selected: AppSession) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    row(session, isSelected: session.id == selected.id)
                        .background(index.isMultiple(of: 2) ? DS.ground : DS.panel.opacity(0.6))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = session.id }
                        .accessibilityAddTraits(.isButton)
                }
            }
            // Room for the selected row's frame, which the scroll view would clip.
            .padding(1)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                .strokeBorder(DS.border, lineWidth: 1)
        )
    }

    /// The selected row is framed in white with a ✦, the same "this one" mark as the
    /// active source in the reference design.
    private func row(_ session: AppSession, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(session.start.formatted(.dateTime.weekday().day().month().hour().minute()).uppercased())
                .frame(width: 150, alignment: .leading)
            Text("→ " + session.end.formatted(.dateTime.hour().minute()))
                .frame(width: 70, alignment: .leading)
            Text(Duration.seconds(session.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatBytes(session.bytes))
                .foregroundStyle(DS.ink)
                .frame(width: 80, alignment: .trailing)
            Text("✦")
                .foregroundStyle(isSelected ? DS.ink : .clear)
                .accessibilityHidden(true)
        }
        .font(DS.mono(9, weight: isSelected ? .bold : .regular))
        .foregroundStyle(isSelected ? DS.ink : DS.inkSecondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusMark, style: .continuous)
                .strokeBorder(isSelected ? DS.ink : .clear, lineWidth: 1)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tooltip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(DS.mono(8, weight: .bold)).foregroundStyle(DS.ink)
            Text(value).font(DS.mono(8)).foregroundStyle(DS.inkSecondary)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(DS.ground))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(DS.border, lineWidth: 1)
        )
    }
}
