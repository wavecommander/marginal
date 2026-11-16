import ReaderCore
import SwiftUI

/// Living reference for the design system. Open the preview; nothing here ships in a screen.
struct DesignSystemGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                Text("Tactile Texts").font(Typeface.largeTitle)
                    .foregroundStyle(Palette.ink)

                section("Surfaces") {
                    HStack(spacing: Space.m) {
                        chip("paper", Palette.paper); chip("surface", Palette.surface)
                        chip("raised", Palette.surfaceRaised); chip("sunken", Palette.sunken)
                    }
                }
                section("Ink and brand") {
                    HStack(spacing: Space.m) {
                        chip("ink", Palette.ink, fg: Palette.paper)
                        chip("margin", Palette.margin, fg: Palette.paper)
                        chip("margin tint", Palette.marginTint)
                    }
                }
                section("Accent presets") {
                    ForEach(AccentChoice.allCases) { choice in
                        HStack(spacing: Space.m) {
                            Text(choice.displayName).font(Typeface.caption).frame(width: 80, alignment: .leading)
                            chip("accent", choice.theme.accent, fg: choice.theme.onAccent)
                            chip("tint", choice.theme.tint, fg: choice.theme.accent)
                            AccentPreview().environment(\.accentTheme, choice.theme).tint(choice.theme.accent)
                        }
                    }
                }
                section("Highlighters") {
                    HStack(spacing: Space.s) {
                        ForEach(HighlightColor.allCases, id: \.self) { HighlightSwatch(colour: $0, isSelected: $0 == .yellow) }
                    }
                    HighlightedText(text: "The characteristic polynomial", colour: .yellow)
                }
                section("Type") {
                    Text("5.2 The Characteristic Equation").font(Typeface.title)
                    Text("Eigenvalues and Eigenvectors").font(Typeface.outline)
                    Text("Interface text is system sans, Dynamic Type aware.").font(Typeface.body)
                    Text("Page 312 of 742 · 20 notes").font(Typeface.caption).foregroundStyle(Palette.inkSecondary)
                    Text("Continue reading").sectionLabelStyle()
                }
                section("Controls") {
                    HStack {
                        Button("Resume") {}.buttonStyle(.tactilePrimary)
                        Button("Open Notebook") {}.buttonStyle(.tactileTonal)
                        Button("Disabled") {}.buttonStyle(.tactilePrimary).disabled(true)
                    }
                    HStack { NoteBadge(count: nil); NoteBadge(count: 3) }
                    ReadingProgress(fraction: 0.42).frame(width: 240)
                }
                section("Book covers") {
                    HStack(alignment: .top, spacing: Space.l) {
                        ForEach(["Linear Algebra", "Organic Chemistry", "Thermodynamics", "Signals and Systems", "Real Analysis"], id: \.self) {
                            BookCover(title: $0, subtitle: "A First Course").frame(width: 110)
                        }
                    }
                }
                section("Note page") {
                    ZStack(alignment: .topLeading) {
                        Palette.notePage
                        NoteRules()
                        Text("The eigenvalues are the roots of det(A − λI) = 0. Check against the trace.")
                            .font(Typeface.notePage).lineSpacing(Typeface.notePageLineHeight - Typeface.notePageSize * 1.2)
                            .foregroundStyle(Palette.ink)
                            .padding(.leading, 36).padding(.trailing, Space.m).padding(.top, 4)
                    }
                    .frame(width: Size.notePageWidth, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .elevation(.card)
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.paper)
    }

    private func section(_ name: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(name).sectionLabelStyle()
            content()
        }
    }

    private func chip(_ name: String, _ fill: Color, fg: Color = Palette.ink) -> some View {
        Text(name).font(Typeface.meta).foregroundStyle(fg)
            .frame(width: 96, height: 64)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline))
    }
}

#Preview("Light") { DesignSystemGallery() }
#Preview("Dark") { DesignSystemGallery().preferredColorScheme(.dark) }
