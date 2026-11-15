import SwiftUI

/// The first-launch welcome sheet (mockup "Onboarding · welcome sheet"): the app's name, three
/// things worth knowing, and two ways out. Swiping it down is the same as "Not now".
struct WelcomeSheet: View {
    @Environment(\.accentTheme) private var accentTheme
    let openGuide: () -> Void
    let notNow: () -> Void

    private struct Point: Identifiable {
        let systemImage: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        var id: String { systemImage }
    }

    private let points = [
        Point(systemImage: "note.text", title: "A note on every page and every heading",
              detail: "Write about the page you\u{2019}re on, or about the whole section it sits in."),
        Point(systemImage: "pencil.tip.crop.circle", title: "Pencil writes, finger scrolls",
              detail: "Tap Markup, then write on the page or on a note. Your finger keeps scrolling."),
        Point(systemImage: "lock.doc", title: "Your PDFs stay untouched",
              detail: "Ink and notes are kept beside the book, so the file itself is never changed."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(accentTheme.onAccent)
                        .frame(width: 76, height: 76)
                        .background(accentTheme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Welcome to Tactile Texts")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(AccessibilityID.Onboarding.welcomeTitle)
                    Text("A reader for big textbooks, with room to write.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(points) { point in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: point.systemImage)
                                    .font(.title)
                                    .foregroundStyle(accentTheme.accent)
                                    .frame(width: 44)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(point.title).font(.headline)
                                    Text(point.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 36)
                }
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The actions stay put below the scrolling content, so both are reachable at the
            // largest text sizes.
            VStack(spacing: 6) {
                Button(action: openGuide) {
                    Text("Open the Quick Guide")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(accentTheme.onAccent)
                .accessibilityIdentifier(AccessibilityID.Onboarding.welcomeOpenGuide)
                Text("Six short pages")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Not now", action: notNow)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.Onboarding.welcomeNotNow)
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        WelcomeSheet(openGuide: {}, notNow: {})
    }
}
