import Foundation

/// Renders usage rows as RFC 4180 CSV.
///
/// Quoting is not optional here: app names legitimately contain commas, quotes and
/// non-ASCII characters, and an unquoted one silently shifts every later column.
public func csv(from apps: [AppUsage]) -> String {
    var lines = ["app,path,received_bytes,sent_bytes,total_bytes"]

    for app in apps {
        lines.append(
            [
                field(app.displayName),
                field(app.bundlePath ?? ""),
                String(app.received),
                String(app.sent),
                String(app.total),
            ]
            .joined(separator: ",")
        )
    }

    return lines.joined(separator: "\n") + "\n"
}

private func field(_ value: String) -> String {
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
        return value
    }
    // A literal quote is escaped by doubling it.
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
