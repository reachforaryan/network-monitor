import Foundation
import Testing

@testable import MonitorCore

private func makeStore() async throws -> (Store, URL) {
    let url = URL.temporaryDirectory.appending(path: "store-test-\(UUID().uuidString).db")
    return (try await Store(url: url), url)
}

@Test func flushThenReadReturnsTheStoredUsage() async throws {
    let (store, url) = try await makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try await store.flush([
        "/Applications/Safari.app": Counters(extIn: 500, extOut: 100, allIn: 500, allOut: 100),
        "postgres": Counters(extIn: 0, extOut: 0, allIn: 900, allOut: 900),
    ])

    let internetOnly = try await store.usage(period: .day, scope: .internet)
    #expect(internetOnly.count == 1, "loopback-only traffic must not show as internet usage")
    #expect(internetOnly[0].key == "/Applications/Safari.app")
    #expect(internetOnly[0].total == 600)

    // Biggest first, and local traffic appears once the scope widens.
    let everything = try await store.usage(period: .day, scope: .all)
    #expect(everything.map(\.key) == ["postgres", "/Applications/Safari.app"])
    #expect(everything[0].total == 1800)
}

@Test func repeatedFlushesAccumulateInTheSameBucket() async throws {
    let (store, url) = try await makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let moment = Date()
    for _ in 1...3 {
        try await store.flush(["app": Counters(extIn: 10, extOut: 5, allIn: 10, allOut: 5)], at: moment)
    }

    let usage = try await store.usage(period: .day, scope: .internet, now: moment)
    #expect(usage.count == 1)
    #expect(usage[0].received == 30)
    #expect(usage[0].sent == 15)
}

@Test func eachGrainGetsItsOwnBucketedCopy() async throws {
    let (store, url) = try await makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    // Two flushes an hour apart: separate minute and hour buckets, one shared day.
    let now = Date()
    let earlier = now.addingTimeInterval(-3600)
    try await store.flush(["app": Counters(extIn: 100, extOut: 0, allIn: 100, allOut: 0)], at: earlier)
    try await store.flush(["app": Counters(extIn: 300, extOut: 0, allIn: 300, allOut: 0)], at: now)

    // Day period reads day buckets, so both flushes collapse into one point.
    #expect(try await store.totalSeries(period: .month, scope: .internet, now: now).count == 1)

    let hourly = try await store.totalSeries(period: .week, scope: .internet, now: now)
    #expect(hourly.count == 2)
    #expect(hourly.map(\.bytes) == [100, 300], "points must come back in chronological order")
}

@Test func appSeriesCoversOnlyTheRequestedApps() async throws {
    let (store, url) = try await makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try await store.flush([
        "wanted": Counters(extIn: 42, extOut: 0, allIn: 42, allOut: 0),
        "ignored": Counters(extIn: 99, extOut: 0, allIn: 99, allOut: 0),
    ])

    let series = try await store.appSeries(keys: ["wanted"], period: .day, scope: .internet)
    #expect(series.keys.sorted() == ["wanted"])
    #expect(series["wanted"]?.map(\.bytes) == [42])
}

@Test func pruneDropsBucketsPastRetention() async throws {
    let (store, url) = try await makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let now = Date()
    let longAgo = now.addingTimeInterval(-30 * 24 * 3600)
    try await store.flush(["old": Counters(extIn: 1, extOut: 0, allIn: 1, allOut: 0)], at: longAgo)
    try await store.prune(now: now)

    // Minute buckets keep 7 days, day buckets keep 400, so only the fine grain goes.
    #expect(try await store.usage(period: .day, scope: .internet, now: longAgo).isEmpty)
    #expect(try await store.usage(period: .month, scope: .internet, now: longAgo).count == 1)
}

@Test func finishedSessionsSurvivePruningExactlyOnce() async throws {
    let (store, url) = try await makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let gaming = Counters(extIn: 1_000_000, extOut: 0, allIn: 1_000_000, allOut: 0)
    // Straddles the 7-day minute retention once `later` comes round.
    let start = Date(timeIntervalSince1970: 1_700_000_040)
    for minute in 0..<10 {
        try await store.flush(["game": gaming], at: start + TimeInterval(minute * 60))
    }
    // Still going at `now`, so not finished yet.
    let now = start + 3600
    try await store.flush(["game": gaming], at: now - 60)

    try await store.prune(now: now)
    #expect(try await store.archivedSessions(key: "game").map(\.bytes) == [10_000_000])

    // A week on, pruning has trimmed the head; re-archiving must not add a partial copy.
    let later = start + 7 * 86_400 + 300
    try await store.prune(now: later)
    try await store.prune(now: later + 86_400)

    let saved = try await store.archivedSessions(key: "game")
    #expect(saved.map(\.bytes) == [1_000_000, 10_000_000])
    #expect(saved.last?.duration == 600)
}
