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

    for (key, counters) in usage {
        #expect(!key.isEmpty)
        #expect(!counters.isZero, "zero-delta apps should be filtered out")
        // Holds only because sample() clamps: the two scopes are separate nettop runs
        // with separate baselines, so the raw deltas can disagree.
        #expect(counters.extIn <= counters.allIn, "external traffic is part of all traffic")
        #expect(counters.extOut <= counters.allOut)
    }
}
