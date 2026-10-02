import Foundation
import Testing

@testable import MonitorCore

private let base = Date(timeIntervalSince1970: 1_700_000_040)

private func minute(_ n: Int, _ bytes: UInt64) -> UsagePoint {
    UsagePoint(date: base + TimeInterval(n * 60), bytes: bytes)
}

@Test func minutesGroupIntoSessionsSplitByIdleGaps() {
    let points = [
        minute(0, 1_000_000),
        minute(1, 1_000_000),
        minute(4, 2_000_000),  // 3-minute gap: same session
        minute(10, 500),       // background trickle: idle, must not bridge
        minute(15, 3_000_000), // 11 minutes after the last active minute: new session
    ]

    let result = sessions(from: points)
    #expect(result.map(\.start) == [base + 900, base])
    #expect(result.map(\.end) == [base + 960, base + 300])
    #expect(result.map(\.bytes) == [3_000_000, 4_000_000])
}

@Test func quietMinutesInsideASessionCountTowardIt() {
    let result = sessions(from: [minute(0, 1_000_000), minute(1, 500), minute(2, 1_000_000)])
    #expect(result.count == 1)
    #expect(result[0].bytes == 2_000_500)
    #expect(result[0].points.count == 3)
    #expect(result[0].peakRate == 1_000_000.0 / 60)
}
