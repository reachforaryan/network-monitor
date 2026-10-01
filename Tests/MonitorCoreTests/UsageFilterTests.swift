import Testing

@testable import MonitorCore

private let apps = [
    AppUsage(key: "/Applications/Google Chrome.app", received: 5_000_000, sent: 1_000_000),
    AppUsage(key: "/Applications/Slack.app", received: 2_000, sent: 1_000),
    AppUsage(key: "mDNSResponder", received: 900, sent: 100),
    AppUsage(key: "/Users/me/Apps/chrome-helper-tool.app", received: 50, sent: 50),
]

@Test func noFilterIsAPassthrough() {
    #expect(UsageFilter.none.apply(to: apps).count == apps.count)
    #expect(!UsageFilter.none.isActive)
}

@Test func appsOnlyDropsUnbundledProcesses() {
    let kept = UsageFilter(appsOnly: true).apply(to: apps)
    #expect(!kept.contains { $0.key == "mDNSResponder" })
    #expect(kept.count == 3)
}

@Test func searchIsCaseInsensitiveAndIgnoresThePath() {
    #expect(UsageFilter(search: "CHROME").apply(to: apps).count == 2)
    // "users" appears in /Users/me/Apps/... but in no display name.
    #expect(UsageFilter(search: "users").apply(to: apps).isEmpty)
    // Surrounding whitespace shouldn't defeat a match.
    #expect(UsageFilter(search: "  slack ").apply(to: apps).count == 1)
}

@Test func thresholdComparesTheCombinedTotalAndIsInclusive() {
    let slackTotal: UInt64 = 3_000
    #expect(UsageFilter(minimumBytes: slackTotal).apply(to: apps).count == 2)
    #expect(UsageFilter(minimumBytes: slackTotal + 1).apply(to: apps).count == 1)
}

@Test func filtersCompose() {
    let kept = UsageFilter(search: "chrome", appsOnly: true, minimumBytes: 1_000_000)
        .apply(to: apps)
    #expect(kept.map(\.key) == ["/Applications/Google Chrome.app"])
}
