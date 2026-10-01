import Foundation
import Testing

@testable import MonitorCore

@Test func parseSkipsHeaderAndMalformedRows() {
    let output = """
    ,bytes_in,bytes_out,
    apsd.388,5559,12204,
    com.apple.WebKit.1024,10,20,
    truncated
    notanumber.55,abc,1,
    """

    let rows = Collector.parse(output)

    #expect(rows.count == 2)
    #expect(rows[0] == Collector.Row(pid: 388, name: "apsd", received: 5559, sent: 12204))
    // Dotted process names keep their dots; only the trailing pid is split off.
    #expect(rows[1] == Collector.Row(pid: 1024, name: "com.apple.WebKit", received: 10, sent: 20))
}

@Test func deltaIgnoresTheFirstSighting() {
    #expect(Collector.delta(current: 9_999_999, last: nil) == 0)
}

@Test func deltaCountsGrowthBetweenSamples() {
    #expect(Collector.delta(current: 500, last: 200) == 300)
    #expect(Collector.delta(current: 200, last: 200) == 0)
}

@Test func deltaIgnoresACounterThatGoesBackwards() {
    // nettop re-states totals as sockets close; that is not 40 bytes of new traffic,
    // and counting `current` here is what turned a 54-byte drop into a 98MB spike.
    #expect(Collector.delta(current: 40, last: 10_000) == 0)
}

@Test func deltaClaimsTheWholeCounterWhenThePidWasReused() {
    // Same pid, process newer than our last sample: none of the counter is ours yet.
    #expect(Collector.delta(current: 40, last: 10_000, isFreshProcess: true) == 40)
}

@Test func groupKeyRollsHelpersUpIntoTheParentApp() {
    let helper =
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

    #expect(
        Collector.groupKey(executablePath: helper, processName: "Google Chrome H")
            == "/Applications/Google Chrome.app"
    )
}

@Test func groupKeyPrefersTheRealFilenameForDaemons() {
    // nettop truncates process names to 16 chars; the path does not.
    #expect(
        Collector.groupKey(executablePath: "/usr/libexec/mdns_responder_x", processName: "mdns_responder_")
            == "mdns_responder_x"
    )
}

@Test func groupKeyFallsBackToProcessNameWithoutAPath() {
    #expect(Collector.groupKey(executablePath: nil, processName: "syslogd") == "syslogd")
}

@Test func displayNameStripsTheBundleSuffix() {
    let app = AppUsage(key: "/Applications/Google Chrome.app", received: 1, sent: 2)
    #expect(app.displayName == "Google Chrome")
    #expect(app.bundlePath == "/Applications/Google Chrome.app")

    let daemon = AppUsage(key: "syslogd", received: 1, sent: 2)
    #expect(daemon.displayName == "syslogd")
    #expect(daemon.bundlePath == nil)
}

@Test func deltaCountsTheWholeCounterForAProcessNewerThanTheLastSample() {
    // All of a just-launched process's traffic happened inside our window.
    #expect(Collector.delta(current: 25_000_000, last: nil, isFreshProcess: true) == 25_000_000)
}

@Test func startTimeResolvesForALiveProcess() throws {
    let started = try #require(Collector.startTime(pid: ProcessInfo.processInfo.processIdentifier))
    #expect(started <= Date())
}
