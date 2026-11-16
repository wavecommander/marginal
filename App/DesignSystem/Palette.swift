import ReaderCore
import SwiftUI
import UIKit

/// Marginal's colour tokens: "paper and ink".
///
/// Light is warm paper under dark ink; dark is a warm charcoal "night paper" (never pure black,
/// never cold grey). Every token is a dynamic colour, so views never branch on colour scheme.
/// Use these names, never raw hex, in feature code.
enum Palette {
    // MARK: Surfaces (back to front)

    /// Window background: the desk the book sits on.
    static let paper = dynamic(light: 0xF6F2EA, dark: 0x181612)
    /// Cards, sidebars, inspector.
    static let surface = dynamic(light: 0xFFFCF6, dark: 0x221F19)
    /// Popovers, sheets, floating controls.
    static let surfaceRaised = dynamic(light: 0xFFFFFF, dark: 0x2D2A22)
    /// Text fields, progress tracks, wells.
    static let sunken = dynamic(light: 0xECE6DA, dark: 0x120F0C)
    /// The page itself in dark mode stays white: PDFs are print. This is the note page.
    static let notePage = dynamic(light: 0xFFFEFB, dark: 0x26231C)

    // MARK: Text

    static let ink = dynamic(light: 0x1D1B16, dark: 0xEFE9DC)
    static let inkSecondary = dynamic(light: 0x5C574B, dark: 0xB0A999)
    /// Captions and placeholders. Still meets 4.5:1 on `paper`.
    static let inkTertiary = dynamic(light: 0x716B5F, dark: 0x9A9384)

    // MARK: Lines

    static let hairline = dynamic(light: 0x1D1B16, dark: 0xEFE9DC, lightAlpha: 0.12, darkAlpha: 0.14)

    // MARK: Brand

    // The accent (accent, tint, on-accent) is the reader's choice: read `\.accentTheme` from
    // the environment (`AccentChoice`, `AccentTheme` in Accent.swift), never a static colour.

    /// Margin red: the colour of marginalia. Note badges, "has a note" markers, destructive
    /// confirmations. Used sparingly so it always means "you wrote something here".
    static let margin = dynamic(light: 0xB03A2A, dark: 0xF28B75)
    static let marginTint = dynamic(light: 0xF8E3DE, dark: 0x4A2A24)

    // MARK: Highlighters

    /// Swatch colour of each highlight colour. The values, and the page fill's opacity, are
    /// defined once in `HighlightPalette`; this only forwards there.
    static func highlight(_ colour: HighlightColor) -> Color { HighlightPalette.swatchColor(colour) }

    // MARK: Cloth (book covers)

    /// Muted bookcloth shades. White type passes 4.5:1 on every one.
    static let cloth: [Color] = clothHex.map { Color(hex: $0) }
    static let clothHex: [UInt32] = [
        0x24396B, // indigo
        0x7A2E2E, // oxblood
        0x2F5D50, // viridian
        0x5B3F8C, // aubergine
        0x8A4A12, // tobacco
        0x2B2B2E, // graphite
        0x0F5F6A, // teal
        0x863557, // mulberry
        0x5C5220, // olive
        0x444B57, // slate
    ]

    // MARK: Helpers

    nonisolated static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(uiColor: uiColor(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    nonisolated static func uiColor(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        }
    }
}

extension Color {
    nonisolated init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
