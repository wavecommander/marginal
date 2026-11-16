import SwiftUI

/// Spacing, shape and size tokens. A 4-pt grid.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let huge: CGFloat = 48
}

enum Radius {
    /// Badges, small chips.
    static let small: CGFloat = 6
    /// Buttons, fields, rows.
    static let control: CGFloat = 12
    /// Cards and panels.
    static let card: CGFloat = 20
    /// Spine side of a book cover (outer side uses `cover`).
    static let spine: CGFloat = 3
    static let cover: CGFloat = 8
}

enum Size {
    /// Minimum touch target.
    static let touch: CGFloat = 44
    /// A note page's fixed logical width (see DESIGN.md "Note page").
    static let notePageWidth: CGFloat = 320
    static let coverAspect: CGFloat = 1.32
    static let progressTrack: CGFloat = 4
}

/// Elevation is shadow-light on purpose: paper stacks, it doesn't float.
enum Elevation {
    case flat, card, floating

    var radius: CGFloat { switch self { case .flat: 0; case .card: 6; case .floating: 18 } }
    var y: CGFloat { switch self { case .flat: 0; case .card: 2; case .floating: 8 } }
    var opacity: Double { switch self { case .flat: 0; case .card: 0.10; case .floating: 0.18 } }
}

extension View {
    func elevation(_ e: Elevation) -> some View {
        shadow(color: .black.opacity(e.opacity), radius: e.radius, y: e.y)
    }

    /// Card surface: paper stock with a hairline edge.
    func cardSurface(_ fill: Color = Palette.surface, radius: CGFloat = Radius.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.hairline))
    }
}
