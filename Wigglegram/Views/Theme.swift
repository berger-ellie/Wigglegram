import SwiftUI

/// Visual tokens for the Wigglegram "SHARP WIGGLES" look.
///
/// The Figma mock uses two commercial typefaces (BN Hightide for the
/// display title, OT Bulb Monoline for UI labels) that we can't ship.
/// `Theme.titleFont` and `Theme.labelFont` walk a fallback chain of
/// faces the user might have installed, then degrade to the closest
/// matching system font. Swap in a licensed face later by prepending
/// the postscript name to the arrays in `firstAvailableFont(_:…)`.
enum Theme {
    // MARK: - Colors

    /// Canvas background from the Figma (#080808).
    static let background = Color(red: 0x08 / 255.0, green: 0x08 / 255.0, blue: 0x08 / 255.0)

    /// Frame stroke / title text.
    static let chrome = Color.white

    /// Slider label color — Figma uses "grays/gray-5" (#E5E5EA).
    static let label = Color(red: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xEA / 255.0)

    /// Slider thumb color — Figma "grays/gray-6" (#F2F2F7).
    static let thumb = Color(red: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF7 / 255.0)

    /// Slider track (dim).
    static let track = Color(white: 0.35)

    /// EXPORT button fill — Figma "accents/red" (#FF383C).
    static let exportRed = Color(red: 0xFF / 255.0, green: 0x38 / 255.0, blue: 0x3C / 255.0)

    /// EXPORT button label — Figma (#890000).
    static let exportLabel = Color(red: 0x89 / 255.0, green: 0x00 / 255.0, blue: 0x00 / 255.0)

    // MARK: - Geometry

    static let frameCornerRadius: CGFloat = 28
    static let frameStroke: CGFloat = 4
    static let exportCornerRadius: CGFloat = 15

    // MARK: - Fonts

    /// Big display title. Falls through installed geometric heavies
    /// before settling on the system black face.
    static func titleFont(size: CGFloat) -> Font {
        firstAvailableFont(
            ["BN Hightide", "Futura-Bold", "AvenirNext-Heavy", "Impact"],
            size: size,
            systemFallback: .system(size: size, weight: .black, design: .default)
        )
    }

    /// Slider labels and numeric readouts. Monospaced stand-in for
    /// OT Bulb Monoline.
    static func labelFont(size: CGFloat) -> Font {
        firstAvailableFont(
            ["OT Bulb Monoline", "IBMPlexMono-Medium", "Menlo-Bold"],
            size: size,
            systemFallback: .system(size: size, weight: .medium, design: .monospaced)
        )
    }

    /// EXPORT button label font.
    static func exportFont(size: CGFloat) -> Font {
        firstAvailableFont(
            ["BN Hightide", "Futura-Bold", "AvenirNext-Heavy"],
            size: size,
            systemFallback: .system(size: size, weight: .black, design: .default)
        )
    }

    private static func firstAvailableFont(
        _ postScriptNames: [String],
        size: CGFloat,
        systemFallback: Font
    ) -> Font {
        #if canImport(AppKit)
        for name in postScriptNames {
            if NSFont(name: name, size: size) != nil {
                return Font.custom(name, size: size)
            }
        }
        #endif
        return systemFallback
    }
}

/// The six-stripe rainbow chip that sits in the Figma's top-right.
/// Drawn entirely in SwiftUI so we don't ship an asset.
struct RainbowChip: View {
    var width: CGFloat = 273
    var height: CGFloat = 78

    // Figma stripes, read off the screenshot: blue, green, yellow, white, orange, red.
    private let stripes: [Color] = [
        Color(red: 0x1F / 255.0, green: 0x7A / 255.0, blue: 0xE8 / 255.0),
        Color(red: 0x2B / 255.0, green: 0xA2 / 255.0, blue: 0x4E / 255.0),
        Color(red: 0xFF / 255.0, green: 0xD5 / 255.0, blue: 0x2E / 255.0),
        Color.white,
        Color(red: 0xFF / 255.0, green: 0x9A / 255.0, blue: 0x1F / 255.0),
        Color(red: 0xFF / 255.0, green: 0x38 / 255.0, blue: 0x3C / 255.0)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stripes.enumerated()), id: \.offset) { _, color in
                Rectangle()
                    .fill(color)
            }
        }
        .frame(width: width, height: height)
        .background(Color.white)
        .clipShape(Rectangle())
    }
}

#Preview {
    VStack(spacing: 20) {
        Text("SHARP WIGGLES")
            .font(Theme.titleFont(size: 72))
            .foregroundStyle(Theme.chrome)
        Text("FRAME DISTANCE")
            .font(Theme.labelFont(size: 18))
            .foregroundStyle(Theme.label)
        RainbowChip()
    }
    .padding(40)
    .background(Theme.background)
}
