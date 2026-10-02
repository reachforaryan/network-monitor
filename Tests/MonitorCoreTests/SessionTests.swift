import Foundation
import Testing

@testable import MonitorCore

@Test func minutesGroupIntoSessionsSplitByIdleGaps() {
    let base = Date(timeIntervalSince1970: 1_700_000_040)
    func minute(_ n: Int, _ bytes: UInt64) -> UsagePoint {
        UsagePoint(date: base + TimeInterval(n * 60), bytes: bytes)
    }

    let points = [
        minute(0, 1_000_000),
        minute(1, 1_000_000),
        minute(4, 2_000_000),  // 3-minute gap: same session
        minute(10, 500),       // background trickle: idle, must not bridge
        minute(15, 3_000_000), // 11 minutes after the last active minute: new session
    ]

    let result = sessions(from: points)
    #expect(result == [
        AppSession(start: base + 900, end: base + 960, bytes: 3_000_000),
        AppSession(start: base, end: base + 300, bytes: 4_000_000),
    ])
}
