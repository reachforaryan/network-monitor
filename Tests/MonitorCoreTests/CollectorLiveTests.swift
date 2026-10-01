import Testing

@testable import MonitorCore

/// Exercises the real `nettop` → parse → path-grouping chain. The unit tests cover the
/// logic on synthetic input; this catches the output format or flags changing underfoot.
@Test func samplingTheSystemProducesUsableAppKeys() async throws {
    let collector = Collector()

    // First sample only establishes baselines, by design.
    #expect(await collector.sample().isEmpty)

    try await Task.sleep(for: .seconds(2))
    let usage = await collector.sample()

    // Note: external usage is a subset of all usage only for the cumulative counters,
    // not for a single window's delta. The two scopes keep separate baselines, so a pid
    // first seen in one list and already established in the other can briefly report
    // more external than total. It evens out across buckets.
    for (key, counters) in usage {
        #expect(!key.isEmpty)
        #expect(!counters.isZero, "zero-delta apps should be filtered out")
    }
}
