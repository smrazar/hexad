import AppKit

/// The values. One number is chosen per app — `accentHue` — and everything else is shared.
/// See ~/Developer/design-language.md §2.
///
/// The accent family is authored in OKLCH so a hover state is one perceptual step darker
/// regardless of hue. The grey ramp is authored as hex, because those were tuned by eye
/// against real windows and round-tripping them only introduces drift.
enum Palette {

    /// hexad's one colour: amber.
    static let accentHue: Double = 70

    // MARK: - Ink

    struct Ink: Equatable {
        let r: Double, g: Double, b: Double, a: Double
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        func alpha(_ value: Double) -> Ink { Ink(r: r, g: g, b: b, a: value) }
    }

    // MARK: - Authoring

    /// OKLCH to sRGB. Lightness 0…1, chroma, hue in degrees.
    static func oklch(_ lightness: Double, _ chroma: Double, _ hueDegrees: Double,
                      alpha: Double = 1) -> Ink {
        let h = hueDegrees * .pi / 180
        let a = chroma * cos(h)
        let bb = chroma * sin(h)

        let l_ = lightness + 0.3963377774 * a + 0.2158037573 * bb
        let m_ = lightness - 0.1055613458 * a - 0.0638541728 * bb
        let s_ = lightness - 0.0894841775 * a - 1.2914855480 * bb

        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_

        let lr =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        return Ink(r: gammaEncode(lr), g: gammaEncode(lg), b: gammaEncode(lb), a: alpha)
    }

    private static func gammaEncode(_ c: Double) -> Double {
        let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return min(max(v, 0), 1)
    }

    /// Hex, for the grey ramp only.
    static func hex(_ value: UInt32, alpha: Double = 1) -> Ink {
        Ink(r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255,
            a: alpha)
    }

    // MARK: - Light

    enum Light {
        static let bg = hex(0xFDFDFD)
        static let surface = hex(0xFFFFFF)
        static let surfaceSecondary = hex(0xF3F4F5)
        static let surfaceHover = hex(0xEDEEF0)
        static let border = hex(0x000000, alpha: 0.10)
        static let borderStrong = hex(0x000000, alpha: 0.16)
        static let textPrimary = hex(0x28292B)
        static let textSecondary = hex(0x5F6164)
        static let textTertiary = hex(0x8A8C8F)

        static let accent = oklch(0.580, 0.190, accentHue)
        static let accentHover = oklch(0.540, 0.195, accentHue)
        static var accentSoft: Ink { accent.alpha(0.14) }
        /// Amber is a light accent, so the label on it is a dark ink — not white.
        /// design-language.md §2: a pale accent takes dark ink, a saturated dark one takes white.
        static let onAccent = oklch(0.200, 0.040, accentHue)
    }

    // MARK: - Dark

    enum Dark {
        static let bg = hex(0x1E1F21)
        static let surface = hex(0x28292C)
        static let surfaceSecondary = hex(0x333438)
        static let surfaceHover = hex(0x3B3C40)
        static let border = hex(0xFFFFFF, alpha: 0.12)
        static let borderStrong = hex(0xFFFFFF, alpha: 0.20)
        static let textPrimary = hex(0xF0F1F2)
        static let textSecondary = hex(0xA7A9AD)
        static let textTertiary = hex(0x7E8085)

        static let accent = oklch(0.720, 0.155, accentHue)
        static let accentHover = oklch(0.760, 0.150, accentHue)
        static var accentSoft: Ink { accent.alpha(0.18) }
        static let onAccent = oklch(0.200, 0.040, accentHue)
    }

    // MARK: - The AppKit bridge
    //
    // Always build NSColor and bridge outward. NSColor(someSwiftUIColor) resolves against the
    // current SwiftUI environment and paints solid black from plain AppKit code — it has cost
    // time in more than one app. design-language.md §2.

    enum NS {
        static func dynamic(_ light: Ink, _ dark: Ink) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? dark.nsColor : light.nsColor
            }
        }

        static var bg: NSColor { dynamic(Light.bg, Dark.bg) }
        static var surface: NSColor { dynamic(Light.surface, Dark.surface) }
        static var surfaceSecondary: NSColor { dynamic(Light.surfaceSecondary, Dark.surfaceSecondary) }
        static var surfaceHover: NSColor { dynamic(Light.surfaceHover, Dark.surfaceHover) }
        static var border: NSColor { dynamic(Light.border, Dark.border) }
        static var borderStrong: NSColor { dynamic(Light.borderStrong, Dark.borderStrong) }
        static var textPrimary: NSColor { dynamic(Light.textPrimary, Dark.textPrimary) }
        static var textSecondary: NSColor { dynamic(Light.textSecondary, Dark.textSecondary) }
        static var textTertiary: NSColor { dynamic(Light.textTertiary, Dark.textTertiary) }
        /// A toggle's knob, white in both modes. It rides either on the accent or on a
        /// strong-bordered track, and a knob that follows the grey ramp disappears into the
        /// dark track exactly when it most needs to say "off".
        static var knob: NSColor { dynamic(Light.surface, Light.surface) }

        static var accent: NSColor { dynamic(Light.accent, Dark.accent) }
        static var accentHover: NSColor { dynamic(Light.accentHover, Dark.accentHover) }
        static var accentSoft: NSColor { dynamic(Light.accentSoft, Dark.accentSoft) }
        static var onAccent: NSColor { dynamic(Light.onAccent, Dark.onAccent) }
    }
}
