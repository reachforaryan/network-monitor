import Darwin
import Foundation

/// Samples per-process network counters out of `nettop` and turns them into per-app
/// deltas since the previous sample.
///
/// Two snapshots are taken per tick — external-only and unfiltered — so the UI's
/// Internet/All-traffic switch is a pure read-side filter and historical rows never
/// silently mix scopes.
public actor Collector {
    public struct Row: Sendable, Equatable {
        public let pid: Int32
        public let name: String
        public let received: UInt64
        public let sent: UInt64

        public init(pid: Int32, name: String, received: UInt64, sent: UInt64) {
            self.pid = pid
            self.name = name
            self.received = received
            self.sent = sent
        }
    }

    private var lastExternal: [Int32: Row] = [:]
    private var lastAll: [Int32: Row] = [:]
    private var keyCache: [Int32: String] = [:]
    private var lastSampledAt: Date?

    public init() {}

    /// Traffic observed since the previous call, keyed by app bundle path (or process
    /// name for daemons). The first call returns nothing but establishes baselines.
    public func sample(now: Date = Date()) -> [String: Counters] {
        let externalRows = Self.parse(Self.runNettop(externalOnly: true))
        let allRows = Self.parse(Self.runNettop(externalOnly: false))

        let previousSample = lastSampledAt
        lastSampledAt = now

        /// A process launched since the last sample has produced *all* of its traffic
        /// inside the window we are measuring, so its whole counter belongs to us.
        func startedSinceLastSample(_ pid: Int32) -> Bool {
            guard let previousSample, let started = Self.startTime(pid: pid) else { return false }
            return started > previousSample
        }

        var usage: [String: Counters] = [:]

        for row in allRows {
            let previous = lastAll[row.pid]
            lastAll[row.pid] = row
            let isNew = previous == nil && startedSinceLastSample(row.pid)
            usage[key(for: row), default: .zero] += Counters(
                allIn: Self.delta(current: row.received, last: previous?.received, countsFromZero: isNew),
                allOut: Self.delta(current: row.sent, last: previous?.sent, countsFromZero: isNew)
            )
        }

        for row in externalRows {
            let previous = lastExternal[row.pid]
            lastExternal[row.pid] = row
            let isNew = previous == nil && startedSinceLastSample(row.pid)
            usage[key(for: row), default: .zero] += Counters(
                extIn: Self.delta(current: row.received, last: previous?.received, countsFromZero: isNew),
                extOut: Self.delta(current: row.sent, last: previous?.sent, countsFromZero: isNew)
            )
        }

        let livePIDs = Set(allRows.map(\.pid)).union(externalRows.map(\.pid))
        lastAll = lastAll.filter { livePIDs.contains($0.key) }
        lastExternal = lastExternal.filter { livePIDs.contains($0.key) }
        keyCache = keyCache.filter { livePIDs.contains($0.key) }

        return usage.filter { !$0.value.isZero }
    }

    private func key(for row: Row) -> String {
        if let cached = keyCache[row.pid] { return cached }
        let key = Self.groupKey(
            executablePath: Self.executablePath(pid: row.pid),
            processName: row.name
        )
        keyCache[row.pid] = key
        return key
    }

    // MARK: - Pure helpers

    /// nettop counters are cumulative since process start. For a pid we have not seen
    /// before, the whole counter only belongs to this window if the process itself is
    /// newer than our last sample — otherwise it is history we must not claim.
    ///
    /// ponytail: a process that both starts and exits between two samples is still
    /// invisible. Catching those needs event-driven accounting (NetworkExtension), not
    /// polling; the 2s window keeps the loss small.
    static func delta(current: UInt64, last: UInt64?, countsFromZero: Bool = false) -> UInt64 {
        guard let last else { return countsFromZero ? current : 0 }
        // A drop means pid reuse or a counter reset, so `current` is all new traffic.
        return current >= last ? current - last : current
    }

    /// Process start time via libproc. No entitlement needed.
    static func startTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // PROC_PIDTBSDINFO (3) isn't exposed to Swift.
        guard proc_pidinfo(pid, 3, 0, &info, size) == size else { return nil }
        return Date(
            timeIntervalSince1970: Double(info.pbi_start_tvsec)
                + Double(info.pbi_start_tvusec) / 1_000_000
        )
    }

    /// Parses `nettop -P -L 1 -J bytes_in,bytes_out -x` output, whose rows look like
    /// `Google Chrome.12345,8192,4096,`. Rows that don't fit are skipped rather than
    /// trusted, since nettop can emit placeholders for processes it can't inspect.
    static func parse(_ output: String) -> [Row] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { return nil }

            // Process names may contain dots, so the pid is after the *last* one.
            let identifier = fields[0]
            guard let dot = identifier.lastIndex(of: "."),
                  let pid = Int32(identifier[identifier.index(after: dot)...]),
                  let received = UInt64(fields[1]),
                  let sent = UInt64(fields[2])
            else { return nil }

            return Row(
                pid: pid,
                name: String(identifier[..<dot]),
                received: received,
                sent: sent
            )
        }
    }

    /// Groups a process under the outermost app bundle in its path, which rolls helper
    /// processes up into their parent app because a helper's own bundle is nested
    /// inside it.
    static func groupKey(executablePath: String?, processName: String) -> String {
        guard let executablePath, !executablePath.isEmpty else { return processName }

        var bundlePath = ""
        for component in executablePath.split(separator: "/") {
            bundlePath += "/" + component
            if component.hasSuffix(".app") { return bundlePath }
        }

        // Unbundled daemon: its real filename beats nettop's 16-char truncated name.
        return (executablePath as NSString).lastPathComponent
    }

    static func executablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE isn't exposed to Swift; it is 4 * MAXPATHLEN.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(PATH_MAX))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func runNettop(externalOnly: Bool) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments =
            ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x"]
            + (externalOnly ? ["-t", "external"] : [])

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        // Drain before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
