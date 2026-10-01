import Testing

@testable import MonitorCore

@Test func csvStartsWithAHeaderAndEndsWithANewline() {
    let output = csv(from: [])
    #expect(output == "app,path,received_bytes,sent_bytes,total_bytes\n")
}

@Test func csvWritesRawByteCountsNotFormattedSizes() {
    let output = csv(from: [AppUsage(key: "/Applications/Slack.app", received: 2_048, sent: 512)])
    #expect(output.contains("Slack,/Applications/Slack.app,2048,512,2560"))
}

@Test func csvQuotesNamesContainingSeparators() {
    // Without quoting this would shift every later column by one.
    let comma = csv(from: [AppUsage(key: "/Applications/Adobe, Inc.app", received: 1, sent: 2)])
    #expect(comma.contains("\"Adobe, Inc\""))

    let quote = csv(from: [AppUsage(key: #"/Applications/He said "hi".app"#, received: 1, sent: 2)])
    #expect(quote.contains(#""He said ""hi""""#))
}

@Test func csvLeavesThePathEmptyForUnbundledProcesses() {
    let output = csv(from: [AppUsage(key: "mDNSResponder", received: 10, sent: 20)])
    #expect(output.contains("mDNSResponder,,10,20,30"))
}
