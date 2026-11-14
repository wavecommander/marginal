import SwiftUI
import UIKit
import Testing
@testable import Marginal

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
                for fg in [Palette.ink, Palette.inkSecondary, Palette.inkTertiary, Palette.accent, Palette.margin] {
                    #expect(contrast(fg, bg, dark: dark) >= 4.5, "dark=\(dark)")
                }
            }
            #expect(contrast(Palette.onAccent, Palette.accent, dark: dark) >= 4.5)
            #expect(contrast(Palette.accent, Palette.accentTint, dark: dark) >= 4.5)
            #expect(contrast(Palette.margin, Palette.marginTint, dark: dark) >= 4.5)
        }
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
