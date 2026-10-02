import Foundation
import MonitorCore
import Observation

/// Drives sampling and exposes everything the views render.
///
/// Sampling and persistence both happen on background actors; only the merge into
/// observable state runs here, so the menu bar never waits on a subprocess.
@MainActor
@Observable
final class MonitorEngine {
    static let pollInterval: Duration = .seconds(2)
    static let flushInterval: Duration = .seconds(15)
    static let topAppCount = 5
    /// 60s of history at the poll interval.
    static let sparklineLength = 30

    struct Rate: Sendable, Equatable {
        var received: Double = 0
        var sent: Double = 0

        var total: Double { received + sent }
    }

    var period: Period = .day {
        didSet { if period != oldValue { scheduleRefresh() } }
    }

    var scope: Scope = .internet {
        didSet { if scope != oldValue { scheduleRefresh() } }
    }

    /// Narrows the lists and the charted apps. Does not change what is recorded, and
    /// deliberately does not change `periodTotal` — see `recomputeApps()`.
    var filter: UsageFilter = .none {
        didSet {
            guard filter != oldValue else { return }
            Self.persist(filter)
            recomputeApps()
        }
    }

    /// How many apps had traffic before filtering, so the UI can show "12 of 47" rather
    /// than quietly presenting a filtered list as the whole picture.
    private(set) var unfilteredCount = 0

    /// The app whose sessions are open — shared so the dropdown can open the detail
    /// window straight onto them.
    var sessionsApp: AppUsage?

    private(set) var rate = Rate()
    private(set) var rateHistory: [Rate] = []
    /// Palette slot per app, so an app keeps its color as ranks swap.
    private(set) var colorSlots: [String: Int] = [:]
    private(set) var totalSeries: [UsagePoint] = []
    private(set) var appSeries: [String: [UsagePoint]] = [:]
    private(set) var errorMessage: String?

    /// Full list for the selected period, biggest first. Stored rather than computed:
    /// the views read it many times per render, and recomputing merged a dictionary and
    /// re-sorted it every time.
    private(set) var apps: [AppUsage] = []
    private(set) var topApps: [AppUsage] = []

    /// Period totals stay unfiltered so the three summary figures always agree with each
    /// other and with what the machine actually transferred.
    private(set) var periodTotal: UInt64 = 0
    private(set) var periodReceived: UInt64 = 0
    private(set) var periodSent: UInt64 = 0

    /// Usage already written to disk for the selected period and scope.
    private var stored: [AppUsage] = []
    /// Sampled but not yet flushed, kept in minute buckets so a batch is written at the
    /// time it was observed rather than the time it happened to be committed.
    private var pending: [Date: [String: Counters]] = [:]

    private let collector = Collector()
    private var store: Store?
    private var tasks: [Task<Void, Never>] = []
    private var lastPrunedDay: Date?

    private enum Key {
        static let appsOnly = "filter.appsOnly"
        static let minimumBytes = "filter.minimumBytes"
    }

    init() {
        // Search is deliberately not restored — a forgotten query would look like an
        // empty list on next launch.
        filter = UsageFilter(
            appsOnly: UserDefaults.standard.bool(forKey: Key.appsOnly),
            minimumBytes: UInt64(UserDefaults.standard.integer(forKey: Key.minimumBytes))
        )
    }

    private static func persist(_ filter: UsageFilter) {
        UserDefaults.standard.set(filter.appsOnly, forKey: Key.appsOnly)
        UserDefaults.standard.set(Int(filter.minimumBytes), forKey: Key.minimumBytes)
    }

    var isLive: Bool { rate.total > 0 }

    /// An app's share of everything transferred this period.
    ///
    /// Measured against the period total rather than against the largest app: dividing
    /// by the leader made the top row read 100% by definition, which told you only that
    /// it was the top row, while everything below answered "compared to the biggest" —
    /// a question nobody was asking of a number sitting under a total.
    func share(of app: AppUsage) -> Double {
        guard periodTotal > 0 else { return 0 }
        return Double(app.total) / Double(periodTotal)
    }

    func start() {
        guard tasks.isEmpty else { return }

        tasks.append(
            Task { [weak self] in
                await self?.openStore()
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(for: Self.pollInterval)
                }
            }
        )

        tasks.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.flushInterval)
                    await self?.flush()
                }
            }
        )
    }

    /// Exports what is on screen — the current period and scope, after filtering, since
    /// that is what the user is looking at when they ask for it.
    func exportCSV(to url: URL) throws {
        try csv(from: apps).write(to: url, atomically: true, encoding: .utf8)
    }

    var suggestedExportName: String {
        let day = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "network-usage-\(period.rawValue)-\(scope.rawValue)-\(day).csv"
    }

    /// The app's sessions, newest first, measured on internet traffic: saved ones plus
    /// any the last week of minutes holds that aren't saved yet, including one in progress.
    func sessions(for key: String) async -> [AppSession] {
        guard let store else { return [] }
        let since = Date().addingTimeInterval(-7 * 86_400)

        do {
            let archived = try await store.archivedSessions(key: key)
            var byMinute = Dictionary(
                try await store.minuteSeries(key: key, scope: .internet, since: since).map { ($0.date, $0.bytes) },
                uniquingKeysWith: +
            )
            // Read after the awaits, so a flush that ran meanwhile isn't counted twice.
            for (bucket, batch) in pending {
                guard let counters = batch[key] else { continue }
                let (received, sent) = counters.bytes(for: .internet)
                byMinute[bucket, default: 0] += received + sent
            }
            let points = byMinute.map { UsagePoint(date: $0.key, bytes: $0.value) }.sorted { $0.date < $1.date }

            // The saved copy wins: the live one may have lost its head to pruning.
            let saved = Set(archived.map(\.end))
            let live = MonitorCore.sessions(from: points).filter { !saved.contains($0.end) }
            return (archived + live).sorted { $0.start > $1.start }
        } catch {
            errorMessage = "Could not read history: \(error)"
            return []
        }
    }

    /// Writes out whatever has been sampled but not yet committed. Quitting without
    /// this discards up to a flush interval of usage.
    func flushBeforeQuit() async {
        await flush()
    }

    // MARK: - Pipeline

    private func openStore() async {
        do {
            let store = try await Store()
            lastPrunedDay = Calendar.current.startOfDay(for: Date())
            try await store.prune()
            self.store = store
            await refresh()
        } catch {
            errorMessage = "History unavailable: \(error)"
        }
    }

    private func poll() async {
        let sample = await collector.sample()

        var tick = Counters.zero
        for counters in sample.values { tick += counters }
        let (received, sent) = tick.bytes(for: scope)

        let seconds = Double(Self.pollInterval.components.seconds)
        rate = Rate(received: Double(received) / seconds, sent: Double(sent) / seconds)
        rateHistory.append(rate)
        if rateHistory.count > Self.sparklineLength {
            rateHistory.removeFirst(rateHistory.count - Self.sparklineLength)
        }

        let bucket = Self.minuteBucket(Date())
        for (key, counters) in sample {
            pending[bucket, default: [:]][key, default: .zero] += counters
        }

        recomputeApps()
    }

    /// Floors to the minute so a flush lands in the bucket the traffic belongs to, not
    /// the one it was written in — otherwise traffic sampled at 23:59:50 would count
    /// toward the next day.
    private static func minuteBucket(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func recomputeApps() {
        var byKey = Dictionary(stored.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for batch in pending.values {
            for (key, counters) in batch {
                let (received, sent) = counters.bytes(for: scope)
                guard received + sent > 0 else { continue }
                let existing = byKey[key]
                byKey[key] = AppUsage(
                    key: key,
                    received: (existing?.received ?? 0) + received,
                    sent: (existing?.sent ?? 0) + sent
                )
            }
        }

        let everything = byKey.values.sorted { $0.total > $1.total }

        // The headline totals stay unfiltered on purpose: hiding daemons must not make
        // the machine look like it used less than it did.
        unfilteredCount = everything.count
        periodTotal = everything.reduce(0) { $0 + $1.total }
        periodReceived = everything.reduce(0) { $0 + $1.received }
        periodSent = everything.reduce(0) { $0 + $1.sent }

        apps = filter.apply(to: everything)
        topApps = Array(apps.prefix(Self.topAppCount))
        assignColorSlots()
    }

    /// Colors follow the app, not its position in the list: an app holds its slot for
    /// as long as it stays on screen, and only releases it when it drops out.
    private func assignColorSlots() {
        let keys = topApps.map(\.key)
        var slots = colorSlots.filter { keys.contains($0.key) }
        var used = Set(slots.values)

        for key in keys where slots[key] == nil {
            guard let free = (0..<Self.topAppCount).first(where: { !used.contains($0) }) else { break }
            slots[key] = free
            used.insert(free)
        }

        colorSlots = slots
    }

    private func flush() async {
        guard let store, !pending.isEmpty else { return }

        let batches = pending
        pending = [:]

        do {
            for (bucket, batch) in batches {
                try await store.flush(batch, at: bucket)
            }
            try await pruneIfDayChanged(store)
        } catch {
            // Keep the batches rather than lose the usage they represent.
            for (bucket, batch) in batches {
                for (key, counters) in batch {
                    pending[bucket, default: [:]][key, default: .zero] += counters
                }
            }
            errorMessage = "Could not save usage: \(error)"
            return
        }

        errorMessage = nil
        await refresh()
    }

    /// Retention has to be enforced while the app runs, not only at launch: as a login
    /// item this process can stay up for weeks, and the minute table grows all the while.
    private func pruneIfDayChanged(_ store: Store) async throws {
        let today = Calendar.current.startOfDay(for: Date())
        guard lastPrunedDay != today else { return }
        lastPrunedDay = today
        try await store.prune()
    }

    private func scheduleRefresh() {
        recomputeApps()
        Task { await refresh() }
    }

    private func refresh() async {
        guard let store else { return }
        let period = period
        let scope = scope

        do {
            let stored = try await store.usage(period: period, scope: scope)
            let totalSeries = try await store.totalSeries(period: period, scope: scope)

            // Another refresh may have been queued while those awaits were in flight;
            // its results are the current ones, so drop these rather than interleave
            // a chart and a list from different periods.
            guard period == self.period, scope == self.scope else { return }

            self.stored = stored
            self.totalSeries = totalSeries
            recomputeApps()

            let appSeries = try await store.appSeries(
                keys: topApps.map(\.key),
                period: period,
                scope: scope
            )
            guard period == self.period, scope == self.scope else { return }
            self.appSeries = appSeries
        } catch {
            errorMessage = "Could not read history: \(error)"
        }
    }
}
