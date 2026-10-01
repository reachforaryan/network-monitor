import AppKit
import CoreText
import MonitorCore
import SwiftUI

/// Dark-only terminal styling: pure black ground, uppercase monospace, hard edges.
/// There is deliberately no light variant — the look depends on the black.
enum DS {
    // MARK: - Palette

    static let ground = Color(rgb: 0x000000)
    static let panel = Color(rgb: 0x121212)
    static let border = Color(rgb: 0x262626)
    static let ink = Color(rgb: 0xFFFFFF)
    static let inkSecondary = Color(rgb: 0x8A8A8A)
    static let inkMuted = Color(rgb: 0x4A4A4A)
    static let live = Color(rgb: 0x0CA30C)

    /// Chart series, validated for colorblind separation and >= 3:1 contrast against
    /// this exact black ground. Assigned in this order, never cycled.
    static let series: [Color] = [
        Color(rgb: 0x3987E5),  // blue
        Color(rgb: 0xD95926),  // orange
        Color(rgb: 0x199E70),  // aqua
        Color(rgb: 0xC98500),  // yellow
        Color(rgb: 0xD55181),  // magenta
    ]

    static let grid = Color(rgb: 0x1A1A1A)

    static func seriesColor(slot: Int?) -> Color {
        guard let slot, series.indices.contains(slot) else { return inkMuted }
        return series[slot]
    }

    // MARK: - Type

    /// Wide squarish face for headings — this is what carries the look.
    static func display(_ size: CGFloat) -> Font {
        .custom("Martian Mono", fixedSize: size)
    }

    /// Narrower face for data and lists, where density matters.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", fixedSize: size).weight(weight)
    }

    /// Bundled fonts aren't visible to the font system until registered.
    static func registerFonts() {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil)
        else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}

extension Color {
    fileprivate init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Components

/// `// SECTION_LABEL`
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text("// \(text.uppercased())")
            .font(DS.mono(9, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(DS.inkSecondary)
    }
}

/// Segmented selector. The active option inverts to a solid block, as in the reference.
struct TabRow<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    let badge: (Value) -> Int?
    @Binding var selection: Value

    init(
        options: [Value],
        selection: Binding<Value>,
        badge: @escaping (Value) -> Int? = { _ in nil },
        label: @escaping (Value) -> String
    ) {
        self.options = options
        self._selection = selection
        self.badge = badge
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isActive = option == selection
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 4) {
                        if !isActive {
                            Text("✦").font(DS.mono(7)).foregroundStyle(DS.inkMuted)
                        }
                        Text(label(option).uppercased())
                        if let count = badge(option) {
                            Text("[\(count)]")
                                .foregroundStyle(isActive ? DS.ground.opacity(0.6) : DS.inkMuted)
                        }
                    }
                    .font(DS.mono(9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(isActive ? DS.ground : DS.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isActive ? DS.ink : DS.panel)
                    .overlay(Rectangle().strokeBorder(isActive ? .clear : DS.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// `[ LABEL ]`
struct BracketButton: View {
    let title: String
    var icon: String?
    var emphasized = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 8))
                }
                Text("[ \(title.uppercased()) ]")
            }
            .font(DS.mono(9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(emphasized ? DS.ground : DS.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(emphasized ? DS.ink : DS.panel)
            .overlay(Rectangle().strokeBorder(emphasized ? .clear : DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The diagonally hatched meter from the reference: slanted bars, lit up to `fraction`.
struct HatchedBar: View {
    var fraction: Double
    var height: CGFloat = 10
    var tint: Color = DS.ink

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            let barWidth: CGFloat = 3
            let slant = size.height * 0.4
            let filledWidth = size.width * CGFloat(min(max(fraction, 0), 1))

            var x: CGFloat = 0
            while x < size.width {
                let bar = Path { path in
                    path.move(to: CGPoint(x: x + slant, y: 0))
                    path.addLine(to: CGPoint(x: x + slant + barWidth, y: 0))
                    path.addLine(to: CGPoint(x: x + barWidth, y: size.height))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    path.closeSubpath()
                }
                context.fill(bar, with: .color(x + barWidth <= filledWidth ? tint : DS.border))
                x += step
            }
        }
        .frame(height: height)
    }
}

/// The measure line that closes the reference's panels.
struct TickRuler: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 7
            var x: CGFloat = 0
            var index = 0
            while x < size.width {
                let tall = index.isMultiple(of: 4)
                let line = Path { path in
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x, y: tall ? 0 : size.height * 0.5))
                }
                context.stroke(line, with: .color(DS.inkMuted), lineWidth: 1)
                x += spacing
                index += 1
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Bordered container used for every grouped block.
struct Panel<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.panel)
            .overlay(Rectangle().strokeBorder(DS.border, lineWidth: 1))
    }
}

/// Square bordered tile holding an app icon, matching the reference's list rows.
struct IconTile: View {
    let app: AppUsage
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            if let icon = AppIcon.image(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size * 0.62, height: size * 0.62)
            } else {
                // Unbundled daemon: a symbol, drawn in ink. An NSImage symbol here would
                // render as a black template on a black tile.
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(DS.inkSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(DS.ground)
        .overlay(Rectangle().strokeBorder(DS.border, lineWidth: 1))
    }
}

/// App icons, cached because `NSWorkspace` builds a fresh image per call and the lists
/// re-render every couple of seconds. Nil for processes with no bundle.
@MainActor
enum AppIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for usage: AppUsage) -> NSImage? {
        guard let bundlePath = usage.bundlePath else { return nil }
        if let cached = cache[usage.key] { return cached }

        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        cache[usage.key] = icon
        return icon
    }
}
