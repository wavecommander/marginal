import ReaderCore
import SwiftUI
import UIKit

/// The app's highlight palette: the one place the four highlight colours are defined. The
/// reader's page drawing, the edit-menu swatches, the notes panel's list and the Notebook all
/// read it (the Notebook through `NotebookHighlightStyle`, which forwards here).
///
/// - `pageFill` is what is laid on the PDF page (`HighlightAnnotation`). It is drawn with a
///   multiply blend, so black text stays black and the colour shows only on the paper; the alpha
///   matches the mockup (`<mark>` at 45% yellow, 35% for the others). PDF pages stay white in dark
///   mode (PDFKit does not invert them), so the page fill is the same in both appearances.
/// - `swatch` / `swatchBorder` are for lists, menus and the Notebook (the mockup's 14 pt chips).
///   They are dynamic colours: the fills are the same in both appearances, and the border is a
///   dark shade on light backgrounds and a light tint on dark ones, so the chip's edge stays
///   visible in dark mode.
nonisolated enum HighlightPalette {
    /// Display name ("Yellow"), used in menus and accessibility.
    static func name(_ color: HighlightColor) -> String {
        switch color {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        }
    }

    /// Chip fill: the mockup's swatches (#FFD60A, #34C759) and the Notebook's blue and pink.
    static func swatchRGB(_ color: HighlightColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch color {
        case .yellow: (1.0, 0.839, 0.039)
        case .green: (0.204, 0.780, 0.349)
        case .blue: (0.353, 0.678, 1.0)
        case .pink: (1.0, 0.420, 0.620)
        }
    }

    /// The colour laid on the page (with its alpha), drawn with a multiply blend.
    static func pageFill(_ color: HighlightColor) -> UIColor {
        let rgb = swatchRGB(color)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: pageAlpha(color))
    }

    /// Opacity of the page fill (the mockup's `<mark>` backgrounds).
    static func pageAlpha(_ color: HighlightColor) -> CGFloat {
        color == .yellow ? 0.45 : 0.35
    }

    /// Chip / list / menu swatch fill (same in light and dark).
    static func swatch(_ color: HighlightColor) -> UIColor {
        let rgb = swatchRGB(color)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// Chip border: a dark shade in light mode (the mockup's #8A7400, #1C6B31), a light tint in
    /// dark mode.
    static func swatchBorder(_ color: HighlightColor) -> UIColor {
        let light: UIColor
        let dark: UIColor
        switch color {
        case .yellow:
            light = UIColor(red: 0.541, green: 0.455, blue: 0.0, alpha: 1)
            dark = UIColor(red: 1.0, green: 0.902, blue: 0.502, alpha: 1)
        case .green:
            light = UIColor(red: 0.110, green: 0.420, blue: 0.192, alpha: 1)
            dark = UIColor(red: 0.494, green: 0.886, blue: 0.604, alpha: 1)
        case .blue:
            light = UIColor(red: 0.10, green: 0.35, blue: 0.65, alpha: 1)
            dark = UIColor(red: 0.651, green: 0.820, blue: 1.0, alpha: 1)
        case .pink:
            light = UIColor(red: 0.62, green: 0.15, blue: 0.33, alpha: 1)
            dark = UIColor(red: 1.0, green: 0.651, blue: 0.769, alpha: 1)
        }
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// SwiftUI forms of the swatch colours.
    static func swatchColor(_ color: HighlightColor) -> Color { Color(uiColor: swatch(color)) }
    static func swatchBorderColor(_ color: HighlightColor) -> Color { Color(uiColor: swatchBorder(color)) }

    /// A round swatch for menus: the fill with its border (and a check mark when `checked`),
    /// light and dark variants in one image asset.
    @MainActor
    static func menuImage(_ color: HighlightColor, checked: Bool = false, diameter: CGFloat = 20) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let fill = swatch(color)
        let border = swatchBorder(color)
        func render(_ traits: UITraitCollection) -> UIImage {
            let format = UIGraphicsImageRendererFormat(for: traits)
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let circle = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75))
                fill.resolvedColor(with: traits).setFill()
                circle.fill()
                border.resolvedColor(with: traits).setStroke()
                circle.lineWidth = 1
                circle.stroke()
                if checked {
                    let check = UIBezierPath()
                    check.move(to: CGPoint(x: diameter * 0.28, y: diameter * 0.52))
                    check.addLine(to: CGPoint(x: diameter * 0.44, y: diameter * 0.68))
                    check.addLine(to: CGPoint(x: diameter * 0.73, y: diameter * 0.34))
                    check.lineWidth = diameter * 0.11
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    UIColor.black.withAlphaComponent(0.8).setStroke()
                    check.stroke()
                }
            }.withRenderingMode(.alwaysOriginal)
        }
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let asset = UIImageAsset()
        asset.register(render(lightTraits), with: lightTraits)
        asset.register(render(darkTraits), with: darkTraits)
        return asset.image(with: UITraitCollection.current).withRenderingMode(.alwaysOriginal)
    }
}
