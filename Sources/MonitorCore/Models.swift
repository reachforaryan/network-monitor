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

    /// External traffic is by definition part of all traffic, but the two scopes come
    /// from two sequential nettop runs: a process that exits between them lands in one
    /// snapshot and not the other, which would otherwise let "All traffic" report less
    /// than "Internet" and make the number drop when the scope picker is flipped.
    var clampedToExternal: Counters {
        Counters(extIn: extIn, extOut: extOut, allIn: max(allIn, extIn), allOut: max(allOut, extOut))
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
    // ByteCountFormatter spells zero as "Zero KB", which reads badly on an axis.
    guard bytes > 0 else { return "0 KB" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

/// `bits` speaks the units ISPs and streaming apps quote ("45 Mbps"), decimal as they are.
public func formatRate(_ bytesPerSecond: Double, bits: Bool = false) -> String {
    guard bits else { return formatBytes(UInt64(max(0, bytesPerSecond))) + "/s" }

    let value = max(0, bytesPerSecond) * 8
    let (scale, unit): (Double, String) =
        switch value {
        case 999.95e6...: (1e9, "Gbps")
        case 999.95e3..<999.95e6: (1e6, "Mbps")
        default: (1e3, "Kbps")
        }
    return String(format: "%.1f %@", value / scale, unit)
}

/// A rate in exactly four characters, for the menu bar.
///
/// The menu bar re-lays out whenever its label changes width, so a varying-width
/// readout makes everything to its left twitch every two seconds. Fixed width plus
/// monospaced digits keeps it still. Kilobytes is the smallest unit — below that the
/// caller shows nothing at all.
public func compactRate(_ bytesPerSecond: Double) -> String {
    let bytes = max(0, bytesPerSecond)

    // Thresholds sit just below the round number so a value that *rounds* up to 1000
    // promotes to the next unit instead of printing a fourth digit.
    let unit: (scale: Double, suffix: String) =
        switch bytes {
        case 999.5e6...: (1e9, "G")
        case 999.5e3..<999.5e6: (1e6, "M")
        default: (1e3, "K")
        }

    let value = bytes / unit.scale
    // Likewise 9.99 must not print as "10.0", which is one character too many.
    let digits = value < 9.95 ? String(format: "%.1f", value) : String(Int(value.rounded()))

    return String(repeating: " ", count: max(0, 3 - digits.count)) + digits + unit.suffix
}

/// One stretch of continuous use by an app, e.g. an evening of cloud gaming.
public struct AppSession: Sendable, Identifiable, Equatable {
    public let start: Date
    public let end: Date
    /// Every recorded minute from start to end, quiet ones inside the session included.
    public let points: [UsagePoint]

    public init(points: [UsagePoint]) {
        precondition(!points.isEmpty, "a session has at least one active minute")
        self.points = points
        start = points[0].date
        end = points[points.count - 1].date + 60
    }

    /// A finished session's end never moves — later traffic starts a new session, and
    /// pruning only trims its head — so the end, not the start, identifies it.
    public var id: Date { end }
    public var bytes: UInt64 { points.reduce(0) { $0 + $1.bytes } }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Bytes per second over the whole session.
    public var averageRate: Double { Double(bytes) / duration }
    /// Bytes per second in the busiest minute.
    public var peakRate: Double { Double(points.map(\.bytes).max() ?? 0) / 60 }
}

/// Silence longer than this ends a session.
public let sessionGap: TimeInterval = 5 * 60

/// Groups an app's minute buckets (oldest first) into sessions, newest first.
///
/// Minutes below `minimumBytes` count as idle, so a launcher's background trickle
/// doesn't glue two sessions together — but quiet minutes *inside* a session still
/// count toward its total.
// ponytail: fixed 5-min gap and 100 KB/min idle floor; make them per-app settings if
// some app's sessions split or merge wrongly.
public func sessions(
    from points: [UsagePoint],
    gap: TimeInterval = sessionGap,
    minimumBytes: UInt64 = 100_000
) -> [AppSession] {
    var result: [AppSession] = []
    var current: [UsagePoint] = []
    var quiet: [UsagePoint] = []

    for point in points {
        guard point.bytes >= minimumBytes else {
            if !current.isEmpty { quiet.append(point) }
            continue
        }
        if let last = current.last, point.date.timeIntervalSince(last.date) <= gap {
            current += quiet
        } else if !current.isEmpty {
            result.append(AppSession(points: current))
            current = []
        }
        quiet = []
        current.append(point)
    }
    if !current.isEmpty { result.append(AppSession(points: current)) }
    return result.reversed()
}
