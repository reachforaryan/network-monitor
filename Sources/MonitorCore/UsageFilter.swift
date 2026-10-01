import Foundation

/// Narrows the app list without touching what was recorded.
///
/// Kept separate from the views so the rules are testable, and applied in one place so
/// the compact list, the detail list and the chart's per-app lines always agree.
public struct UsageFilter: Sendable, Equatable {
    public var search: String
    /// Drops processes with no app bundle — the daemons (`mDNSResponder`, `syspolicyd`)
    /// that otherwise crowd real apps out of the top five.
    public var appsOnly: Bool
    public var minimumBytes: UInt64

    public static let none = UsageFilter()

    public init(search: String = "", appsOnly: Bool = false, minimumBytes: UInt64 = 0) {
        self.search = search
        self.appsOnly = appsOnly
        self.minimumBytes = minimumBytes
    }

    public var isActive: Bool { self != .none }

    public func apply(to apps: [AppUsage]) -> [AppUsage] {
        guard isActive else { return apps }

        let query = search.trimmingCharacters(in: .whitespaces).lowercased()

        return apps.filter { app in
            if appsOnly, app.bundlePath == nil { return false }
            if app.total < minimumBytes { return false }
            // Matched against the display name, not the path: searching "chrome"
            // shouldn't hit every app under /Users/chrome/.
            if !query.isEmpty, !app.displayName.lowercased().contains(query) { return false }
            return true
        }
    }
}
