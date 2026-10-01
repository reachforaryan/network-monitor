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

    private(set) var rate = Rate()
    private(set) var rateHistory: [Rate] = []
    private(set) var totalSeries: [UsagePoint] = []
    private(set) var appSeries: [String: [UsagePoint]] = [:]
    private(set) var errorMessage: String?

    /// Usage already written to disk for the selected period and scope.
    private var stored: [AppUsage] = []
    /// Sampled but not yet flushed, so displayed totals stay live between flushes.
    private var pending: [String: Counters] = [:]

    private let collector = Collector()
    private var store: Store?
    private var tasks: [Task<Void, Never>] = []

    /// Full list for the selected period, biggest first.
    var apps: [AppUsage] {
        var byKey = Dictionary(stored.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for (key, counters) in pending {
            let (received, sent) = counters.bytes(for: scope)
            guard received + sent > 0 else { continue }
            let existing = byKey[key]
            byKey[key] = AppUsage(
                key: key,
                received: (existing?.received ?? 0) + received,
                sent: (existing?.sent ?? 0) + sent
            )
        }

        return byKey.values.sorted { $0.total > $1.total }
    }

    var topApps: [AppUsage] { Array(apps.prefix(Self.topAppCount)) }

    var periodTotal: UInt64 { apps.reduce(0) { $0 + $1.total } }

    var isLive: Bool { rate.total > 0 }

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

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    // MARK: - Pipeline

    private func openStore() async {
        do {
            let store = try await Store()
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

        for (key, counters) in sample {
            pending[key, default: .zero] += counters
        }
    }

    private func flush() async {
        guard let store, !pending.isEmpty else { return }

        let batch = pending
        pending = [:]

        do {
            try await store.flush(batch)
        } catch {
            // Keep the batch rather than lose the usage it represents.
            for (key, counters) in batch {
                pending[key, default: .zero] += counters
            }
            errorMessage = "Could not save usage: \(error)"
            return
        }

        errorMessage = nil
        await refresh()
    }

    private func scheduleRefresh() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard let store else { return }
        let period = period
        let scope = scope

        do {
            stored = try await store.usage(period: period, scope: scope)
            totalSeries = try await store.totalSeries(period: period, scope: scope)
            appSeries = try await store.appSeries(
                keys: topApps.map(\.key),
                period: period,
                scope: scope
            )
        } catch {
            errorMessage = "Could not read history: \(error)"
        }
    }
}
