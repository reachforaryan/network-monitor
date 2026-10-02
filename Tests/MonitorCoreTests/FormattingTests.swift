import Testing

@testable import MonitorCore

@Test func compactRateIsAlwaysFourCharactersWide() {
    // Any change in width makes the whole menu bar shift, so this is the point of it.
    let samples: [Double] = [
        0, 1, 999, 1_000, 9_999, 150_000, 999_000, 999_600, 1_200_000,
        15_000_000, 999_999_999, 2_400_000_000,
    ]
    for sample in samples {
        #expect(compactRate(sample).count == 4, "\(sample) formatted as \(compactRate(sample))")
    }
}

@Test func compactRatePicksAUnitPerMagnitude() {
    #expect(compactRate(150_000) == "150K")
    #expect(compactRate(2_400_000) == "2.4M")
    #expect(compactRate(15_000_000) == " 15M")
    #expect(compactRate(2_400_000_000) == "2.4G")
    // Rounds up into the next unit rather than printing a fourth digit.
    #expect(compactRate(999_600) == "1.0M")
    #expect(compactRate(0) == "0.0K")
}

@Test func zeroBytesReadsAsZeroNotAsWords() {
    // ByteCountFormatter spells this "Zero KB", which reads badly on an axis.
    #expect(formatBytes(0) == "0 KB")
}

@Test func ratesInBitsUseDecimalNetworkUnits() {
    #expect(formatRate(5_625_000, bits: true) == "45.0 Mbps")
    #expect(formatRate(1_000, bits: true) == "8.0 Kbps")
    #expect(formatRate(200_000_000, bits: true) == "1.6 Gbps")
}
