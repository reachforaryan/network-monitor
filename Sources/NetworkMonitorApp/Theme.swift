import AppKit
import MonitorCore
import SwiftUI

/// Chart and list colors.
///
/// Values come from a palette validated for colorblind separation and contrast
/// against this app's surfaces (`#ececec` light, `#1e1e1e` dark). Light-mode series
/// sit below 3:1 on purpose, which is why every colored mark here is paired with a
/// visible name and value rather than carrying meaning alone.
enum Theme {
    /// Categorical slots, in the order they must be assigned. Never reordered or
    /// cycled: the order is what keeps adjacent pairs distinguishable.
    static let series: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),  // blue
        dynamic(light: 0xEB6834, dark: 0xD95926),  // orange
        dynamic(light: 0x1BAF7A, dark: 0x199E70),  // aqua
        dynamic(light: 0xEDA100, dark: 0xC98500),  // yellow
        dynamic(light: 0xE87BA4, dark: 0xD55181),  // magenta
    ]

    /// Aggregate lines use ink, not a categorical hue, so "total" never reads as
    /// just another app.
    static let total = dynamic(light: 0x52514E, dark: 0xC3C2B7)
    static let grid = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)
    static let unassigned = Color.secondary

    static func color(slot: Int?) -> Color {
        guard let slot, series.indices.contains(slot) else { return unassigned }
        return series[slot]
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            }
        )
    }
}

extension NSColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// App icons, cached because `NSWorkspace` builds a fresh image per call and the
/// lists re-render every couple of seconds.
@MainActor
enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for usage: AppUsage) -> NSImage {
        if let cached = cache[usage.key] { return cached }

        let image =
            usage.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Background process")
            ?? NSImage()

        cache[usage.key] = image
        return image
    }
}
