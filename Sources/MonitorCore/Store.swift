import Foundation
import SQLite3

public enum StoreError: Error {
    case sqlite(String)
}

/// Usage history in SQLite, bucketed at three resolutions so each period can be read
/// at the grain its chart draws.
///
/// Every flush writes all three grains at once rather than rolling coarser buckets up
/// later: the batches are tiny, and it keeps hour/day boundaries on Calendar (correct
/// across time zones and DST) instead of in SQL date arithmetic.
public actor Store {
    /// The connection is only ever used from this actor (or `deinit`, after the last
    /// reference is gone), so hand-waving `OpaquePointer`'s non-Sendability is safe.
    private struct Connection: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private nonisolated let connection: Connection
    private nonisolated var db: OpaquePointer { connection.pointer }
    private let calendar: Calendar

    private static let retention: [Grain: Int] = [.minute: 7, .hour: 400, .day: 400]

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "NetworkMonitor", directoryHint: .isDirectory)
            .appending(path: "history.db")
    }

    // `async` so the initializer is actor-isolated and can run the schema statements.
    public init(url: URL = Store.defaultURL, calendar: Calendar = .current) async throws {
        self.calendar = calendar

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let pointer else {
            // sqlite3_open allocates a handle even when it fails.
            sqlite3_close(pointer)
            throw StoreError.sqlite("could not open \(url.path)")
        }
        connection = Connection(pointer: pointer)

        // Small frequent writes: WAL avoids blocking readers, NORMAL avoids an fsync
        // per flush. Losing the last few seconds of usage on a crash is acceptable.
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")

        for grain in Grain.allCases {
            try exec(
                """
                CREATE TABLE IF NOT EXISTS \(grain.table) (
                    bucket  INTEGER NOT NULL,
                    app_key TEXT    NOT NULL,
                    ext_in  INTEGER NOT NULL,
                    ext_out INTEGER NOT NULL,
                    all_in  INTEGER NOT NULL,
                    all_out INTEGER NOT NULL,
                    PRIMARY KEY (bucket, app_key)
                ) WITHOUT ROWID
                """
            )
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writing

    public func flush(_ usage: [String: Counters], at date: Date = Date()) throws {
        guard !usage.isEmpty else { return }

        try exec("BEGIN")
        do {
            for grain in Grain.allCases {
                let bucket = self.bucket(date, grain: grain)
                let statement = try prepare(
                    """
                    INSERT INTO \(grain.table)
                        (bucket, app_key, ext_in, ext_out, all_in, all_out)
                        VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(bucket, app_key) DO UPDATE SET
                        ext_in  = ext_in  + excluded.ext_in,
                        ext_out = ext_out + excluded.ext_out,
                        all_in  = all_in  + excluded.all_in,
                        all_out = all_out + excluded.all_out
                    """
                )
                defer { sqlite3_finalize(statement) }

                for (key, counters) in usage {
                    sqlite3_bind_int64(statement, 1, bucket)
                    sqlite3_bind_text(statement, 2, key, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(statement, 3, Int64(clamping: counters.extIn))
                    sqlite3_bind_int64(statement, 4, Int64(clamping: counters.extOut))
                    sqlite3_bind_int64(statement, 5, Int64(clamping: counters.allIn))
                    sqlite3_bind_int64(statement, 6, Int64(clamping: counters.allOut))

                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw StoreError.sqlite(lastErrorMessage)
                    }
                    sqlite3_reset(statement)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Drops buckets past their retention. Cheap enough to run at launch only.
    public func prune(now: Date = Date()) throws {
        for (grain, days) in Self.retention {
            guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { continue }
            try exec("DELETE FROM \(grain.table) WHERE bucket < \(bucket(cutoff, grain: grain))")
        }
    }

    // MARK: - Reading

    /// Every app with traffic in the period, biggest first. Serves the period total,
    /// the compact view's top 5, and the detail window's full list from one query.
    public func usage(period: Period, scope: Scope, now: Date = Date()) throws -> [AppUsage] {
        let (received, sent) = scope.columns
        let statement = try prepare(
            """
            SELECT app_key, SUM(\(received)), SUM(\(sent))
              FROM \(period.grain.table)
             WHERE bucket >= ?
             GROUP BY app_key
             HAVING SUM(\(received)) + SUM(\(sent)) > 0
             ORDER BY SUM(\(received)) + SUM(\(sent)) DESC
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, periodStart(period, now: now))

        var result: [AppUsage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                AppUsage(
                    key: String(cString: sqlite3_column_text(statement, 0)),
                    received: UInt64(clamping: sqlite3_column_int64(statement, 1)),
                    sent: UInt64(clamping: sqlite3_column_int64(statement, 2))
                )
            )
        }
        return result
    }

    /// Combined throughput per bucket — the bold line on the chart.
    public func totalSeries(period: Period, scope: Scope, now: Date = Date()) throws -> [UsagePoint] {
        let (received, sent) = scope.columns
        let statement = try prepare(
            """
            SELECT bucket, SUM(\(received)) + SUM(\(sent))
              FROM \(period.grain.table)
             WHERE bucket >= ?
             GROUP BY bucket
             ORDER BY bucket
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, periodStart(period, now: now))

        var points: [UsagePoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(
                UsagePoint(
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    bytes: UInt64(clamping: sqlite3_column_int64(statement, 1))
                )
            )
        }
        return points
    }

    /// Per-bucket throughput for specific apps — the thin per-app lines.
    public func appSeries(
        keys: [String],
        period: Period,
        scope: Scope,
        now: Date = Date()
    ) throws -> [String: [UsagePoint]] {
        guard !keys.isEmpty else { return [:] }
        let (received, sent) = scope.columns
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")

        let statement = try prepare(
            """
            SELECT app_key, bucket, SUM(\(received)) + SUM(\(sent))
              FROM \(period.grain.table)
             WHERE bucket >= ? AND app_key IN (\(placeholders))
             GROUP BY app_key, bucket
             ORDER BY bucket
            """
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, periodStart(period, now: now))
        for (offset, key) in keys.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 2), key, -1, SQLITE_TRANSIENT)
        }

        var series: [String: [UsagePoint]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(statement, 0))
            series[key, default: []].append(
                UsagePoint(
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                    bytes: UInt64(clamping: sqlite3_column_int64(statement, 2))
                )
            )
        }
        return series
    }

    /// One app's minute buckets since `since`, oldest first — the raw material for sessions.
    public func minuteSeries(key: String, scope: Scope, since: Date) throws -> [UsagePoint] {
        let (received, sent) = scope.columns
        let statement = try prepare(
            """
            SELECT bucket, \(received) + \(sent)
              FROM \(Grain.minute.table)
             WHERE app_key = ? AND bucket >= ?
             ORDER BY bucket
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, bucket(since, grain: .minute))

        var points: [UsagePoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(
                UsagePoint(
                    date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    bytes: UInt64(clamping: sqlite3_column_int64(statement, 1))
                )
            )
        }
        return points
    }

    // MARK: - Internals

    func bucket(_ date: Date, grain: Grain) -> Int64 {
        switch grain {
        case .minute:
            // Minutes always align to the epoch; hours and days may not, so those go
            // through Calendar to respect the local zone.
            Int64(date.timeIntervalSince1970) / 60 * 60
        case .hour:
            Int64(calendar.dateInterval(of: .hour, for: date)?.start.timeIntervalSince1970 ?? 0)
        case .day:
            Int64(calendar.startOfDay(for: date).timeIntervalSince1970)
        }
    }

    private func periodStart(_ period: Period, now: Date) -> Int64 {
        bucket(period.start(now: now, calendar: calendar), grain: period.grain)
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite("\(lastErrorMessage) — in: \(sql)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StoreError.sqlite("\(lastErrorMessage) — in: \(sql)")
        }
        return statement
    }
}

// SQLite must copy bound strings: Swift's temporary UTF-8 buffer dies before step().
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Grain: CaseIterable {
    public static let allCases: [Grain] = [.minute, .hour, .day]

    var table: String {
        switch self {
        case .minute: "usage_minute"
        case .hour: "usage_hour"
        case .day: "usage_day"
        }
    }
}

extension Scope {
    /// Column pair to read for this scope. Fixed identifiers, never user input.
    var columns: (received: String, sent: String) {
        switch self {
        case .internet: ("ext_in", "ext_out")
        case .all: ("all_in", "all_out")
        }
    }
}
