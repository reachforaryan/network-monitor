import Foundation

/// Byte counters split by interface scope. `all` includes loopback and unbound sockets,
/// `ext` only external interfaces, so local-only traffic is `all - ext`.
public struct Counters: Sendable, Equatable {
    public var extIn: UInt64
    public var extOut: UInt64
    public var allIn: UInt64
    public var allOut: UInt64

    public static let zero = Counters()

    public init(extIn: UInt64 = 0, extOut: UInt64 = 0, allIn: UInt64 = 0, allOut: UInt64 = 0) {
        self.extIn = extIn
        self.extOut = extOut
        self.allIn = allIn
        self.allOut = allOut
    }

    public var isZero: Bool { self == .zero }

    public func bytes(for scope: Scope) -> (received: UInt64, sent: UInt64) {
        switch scope {
        case .internet: (extIn, extOut)
        case .all: (allIn, allOut)
        }
    }

    public static func += (lhs: inout Counters, rhs: Counters) {
        lhs.extIn += rhs.extIn
        lhs.extOut += rhs.extOut
        lhs.allIn += rhs.allIn
        lhs.allOut += rhs.allOut
    }
}

public enum Scope: String, CaseIterable, Sendable {
    case internet
    case all

    public var label: String {
        switch self {
        case .internet: "Internet"
        case .all: "All traffic"
        }
    }
}

/// Time bucket size. Each maps to its own table so a period can be queried at the
/// resolution its chart actually draws.
public enum Grain: Sendable {
    case minute
    case hour
    case day
}

public enum Period: String, CaseIterable, Sendable {
    case day
    case week
    case month

    public var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    /// Chart resolution: a day of minutes, a week of hours, a month of days all land
    /// in the same few-hundred-points range.
    public var grain: Grain {
        switch self {
        case .day: .minute
        case .week: .hour
        case .month: .day
        }
    }

    /// Calendar-aligned start, so "Week" means this week rather than the last 7 days.
    public func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .day: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        case .month: calendar.dateInterval(of: .month, for: now)?.start ?? now
        }
    }
}

/// One app's usage over some period. `key` is an app bundle path, or a bare process
/// name for daemons that have no bundle.
public struct AppUsage: Sendable, Identifiable, Equatable {
    public let key: String
    public let received: UInt64
    public let sent: UInt64

    public init(key: String, received: UInt64, sent: UInt64) {
        self.key = key
        self.received = received
        self.sent = sent
    }

    public var id: String { key }
    public var total: UInt64 { received + sent }

    public var displayName: String {
        guard key.hasSuffix(".app") else { return key }
        return (key as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Bundle path for icon lookup, or nil for daemons.
    public var bundlePath: String? { key.hasSuffix(".app") ? key : nil }
}

/// One point on the usage line graph.
public struct UsagePoint: Sendable, Identifiable, Equatable {
    public let date: Date
    public let bytes: UInt64

    public init(date: Date, bytes: UInt64) {
        self.date = date
        self.bytes = bytes
    }

    public var id: Date { date }
}

public func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

public func formatRate(_ bytesPerSecond: Double) -> String {
    formatBytes(UInt64(max(0, bytesPerSecond))) + "/s"
}
