import ReaderCore
import SwiftUI

// MARK: Buttons

/// Tactile Texts' two button weights. System controls (toolbars, menus, segmented pickers) stay
/// system; these are for in-content actions like Resume and Import PDF.
struct TactileTextsButtonStyle: ButtonStyle {
    enum Kind { case primary, tonal }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accentTheme) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.control)
            .foregroundStyle(kind == .primary ? accent.onAccent : accent.accent)
            .padding(.horizontal, Space.l)
            .frame(minHeight: Size.touch)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(kind == .primary ? accent.accent : accent.tint)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

extension ButtonStyle where Self == TactileTextsButtonStyle {
    static var tactilePrimary: TactileTextsButtonStyle { .init(kind: .primary) }
    static var tactileTonal: TactileTextsButtonStyle { .init(kind: .tonal) }
}

// MARK: Progress

/// Reading progress: a thin ink line on a sunken track.
struct ReadingProgress: View {
    var fraction: Double
    var height: CGFloat = Size.progressTrack
    @Environment(\.accentTheme) private var accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.sunken)
                Capsule().fill(accent.accent)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(fraction <= 0 ? "Not started" : "\(Int((fraction * 100).rounded())) percent read")
    }
}

// MARK: Book cover

/// A cloth-bound cover drawn from the title when the PDF has no usable thumbnail.
/// The cloth colour is a stable function of the title so a book never changes colour.
struct BookCover: View {
    var title: String
    var subtitle: String?
    var thumbnail: Image?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let thumbnail {
                thumbnail.resizable().scaledToFill()
            } else {
                cloth
            }
        }
        .aspectRatio(1 / Size.coverAspect, contentMode: .fit)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: Radius.spine, bottomLeadingRadius: Radius.spine,
            bottomTrailingRadius: Radius.cover, topTrailingRadius: Radius.cover, style: .continuous))
        .overlay(alignment: .leading) { // spine crease
            LinearGradient(colors: [.black.opacity(0.28), .black.opacity(0.0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 10)
                .allowsHitTesting(false)
        }
        .elevation(.card)
        .accessibilityHidden(true)
    }

    private var cloth: some View {
        let colour = Palette.cloth[Self.clothIndex(for: title)]
        return ZStack(alignment: .topLeading) {
            colour
            VStack(alignment: .leading, spacing: Space.xs) {
                Rectangle().fill(.white.opacity(0.55)).frame(width: 22, height: 2) // gilt rule
                Text(title)
                    .font(.system(.headline, design: .serif, weight: .semibold))
                    .lineLimit(4)
                if let subtitle {
                    Text(subtitle).font(.system(.caption, design: .serif)).opacity(0.8).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.leading, Space.l).padding(.trailing, Space.m).padding(.vertical, Space.l)
        }
    }

    /// Stable across launches (unlike `hashValue`).
    static func clothIndex(for title: String) -> Int {
        let sum = title.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return Int(sum % UInt64(Palette.cloth.count))
    }
}

// MARK: Markers

/// Margin-red marker that says "there is a note here". `count` nil draws a plain dot.
struct NoteBadge: View {
    var count: Int?

    var body: some View {
        Group {
            if let count {
                Text("\(count)")
                    .font(Typeface.numeric)
                    .foregroundStyle(Palette.margin)
                    .padding(.horizontal, Space.s - 1).padding(.vertical, Space.xxs)
                    .background(Palette.marginTint, in: Capsule())
            } else {
                Circle().fill(Palette.margin).frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel(count.map { "\($0) notes" } ?? "Has a note")
    }
}

/// A highlighter swatch for the edit-menu colour choice and Notebook filter.
struct HighlightSwatch: View {
    var colour: HighlightColor
    var isSelected = false

    var body: some View {
        Circle()
            .fill(HighlightPalette.swatchColor(colour))
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(Palette.ink.opacity(0.18)))
            .overlay {
                if isSelected {
                    Circle().strokeBorder(Palette.ink, lineWidth: 2).padding(-4)
                }
            }
            .frame(width: Size.touch, height: Size.touch)
            .accessibilityLabel(HighlightPalette.name(colour))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Text as it looks once highlighted on a page (for Notebook rows and previews).
struct HighlightedText: View {
    var text: String
    var colour: HighlightColor

    var body: some View {
        Text(text)
            .font(Typeface.notePage)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.xs)
            .background(HighlightPalette.swatchColor(colour).opacity(HighlightPalette.pageAlpha(colour)),
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// Ruled lines for the note page, aligned to `Typeface.notePageLineHeight`.
struct NoteRules: View {
    var body: some View {
        Canvas { ctx, size in
            var y = Typeface.notePageLineHeight
            while y < size.height {
                var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y))
                ctx.stroke(p, with: .color(Palette.hairline), lineWidth: 0.5)
                y += Typeface.notePageLineHeight
            }
            // Margin line, in margin red.
            var m = Path(); m.move(to: .init(x: 28, y: 0)); m.addLine(to: .init(x: 28, y: size.height))
            ctx.stroke(m, with: .color(Palette.margin.opacity(0.35)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
