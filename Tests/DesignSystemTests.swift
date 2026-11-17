import SwiftUI
import UIKit
import Testing
@testable import TactileTexts

@MainActor
struct DesignSystemTests {
    private func resolve(_ c: Color, dark: Bool) -> UIColor {
        UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
    }

    private func luminance(_ c: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func f(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        let l1 = luminance(resolve(a, dark: dark)), l2 = luminance(resolve(b, dark: dark))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test func textMeetsAA() {
        for dark in [false, true] {
            for bg in [Palette.paper, Palette.surface, Palette.surfaceRaised] {
                for fg in [Palette.ink, Palette.inkSecondary, Palette.inkTertiary, Palette.margin] {
                    #expect(contrast(fg, bg, dark: dark) >= 4.5, "dark=\(dark)")
                }
            }
            #expect(contrast(Palette.margin, Palette.marginTint, dark: dark) >= 4.5)
        }
    }

    /// Backgrounds accent text sits on: the app's surfaces and the system ones the Library,
    /// lists and sheets use.
    private let accentBackgrounds: [Color] = [
        Palette.paper, Palette.surface, Palette.surfaceRaised,
        Color(uiColor: .systemBackground), Color(uiColor: .systemGroupedBackground),
        Color(uiColor: .secondarySystemGroupedBackground), Color(uiColor: .secondarySystemBackground),
    ]

    /// `fg` at `alpha` composited over `bg`, in one appearance.
    private func composite(_ fg: Color, alpha: Double, over bg: Color, dark: Bool) -> Color {
        let f = resolve(fg, dark: dark), b = resolve(bg, dark: dark)
        var fr: CGFloat = 0, fgr: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bgr: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        f.getRed(&fr, green: &fgr, blue: &fb, alpha: &fa)
        b.getRed(&br, green: &bgr, blue: &bb, alpha: &ba)
        let a = CGFloat(alpha)
        return Color(uiColor: UIColor(red: fr * a + br * (1 - a), green: fgr * a + bgr * (1 - a),
                                      blue: fb * a + bb * (1 - a), alpha: 1))
    }

    @Test(arguments: AccentChoice.allCases)
    func accentPresetMeetsAA(_ choice: AccentChoice) {
        let theme = choice.theme
        for dark in [false, true] {
            for bg in accentBackgrounds {
                #expect(contrast(theme.accent, bg, dark: dark) >= 4.5, "\(choice) on background, dark=\(dark)")
                // Selected rows: accent text on a 14–15% accent fill.
                let fill = composite(theme.accent, alpha: 0.15, over: bg, dark: dark)
                #expect(contrast(theme.accent, fill, dark: dark) >= 4.5, "\(choice) on selection fill, dark=\(dark)")
            }
            #expect(contrast(theme.onAccent, theme.accent, dark: dark) >= 4.5, "\(choice) onAccent, dark=\(dark)")
            #expect(contrast(theme.accent, theme.tint, dark: dark) >= 4.5, "\(choice) on tint, dark=\(dark)")
        }
    }

    @Test func raspberryMatchesTheAccentAsset() {
        // The asset is the launch-frame tint, before SwiftUI mounts; the default must match it.
        let asset = Color("AccentColor")
        for dark in [false, true] {
            #expect(contrast(AccentChoice.default.theme.accent, asset, dark: dark) < 1.01, "dark=\(dark)")
        }
    }

    @Test func accentChoiceRoundTripsAndFallsBack() {
        for choice in AccentChoice.allCases {
            #expect(AccentChoice(storedValue: choice.rawValue) == choice)
        }
        #expect(AccentChoice(storedValue: nil) == .raspberry)
        #expect(AccentChoice(storedValue: "chartreuse") == .raspberry)
        #expect(AccentChoice(storedValue: "") == .raspberry)

        let defaults = UserDefaults(suiteName: "DesignSystemTests.accent")!
        defer { defaults.removePersistentDomain(forName: "DesignSystemTests.accent") }
        #expect(AccentChoice.stored(in: defaults) == .raspberry)
        defaults.set(AccentChoice.onyx.rawValue, forKey: AccentChoice.storageKey)
        #expect(AccentChoice.stored(in: defaults) == .onyx)
        // Retired presets: Graphite became Onyx; Teal and Tobacco fall back to the default.
        defaults.set("graphite", forKey: AccentChoice.storageKey)
        #expect(AccentChoice.stored(in: defaults) == .onyx)
        for retired in ["teal", "tobacco"] {
            defaults.set(retired, forKey: AccentChoice.storageKey)
            #expect(AccentChoice.stored(in: defaults) == .raspberry)
        }
        defaults.set("bogus", forKey: AccentChoice.storageKey)
        #expect(AccentChoice.stored(in: defaults) == .raspberry)
    }

    @Test func clothCarriesWhiteType() {
        for hex in Palette.clothHex {
            #expect(contrast(.white, Color(hex: hex), dark: false) >= 4.5, "\(String(hex, radix: 16))")
        }
    }

    @Test func clothIndexIsStable() {
        #expect(BookCover.clothIndex(for: "Real Analysis") == BookCover.clothIndex(for: "Real Analysis"))
        #expect(BookCover.clothIndex(for: "x") < Palette.cloth.count)
    }
}
