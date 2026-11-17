import SwiftUI
import UIKit

/// The reader's choice of accent colour (Settings ▸ Appearance). A fixed list of hand-checked
/// presets, not a free picker: each preset is a quad of accent, accent tint and on-accent colours
/// in both appearances, and `DesignSystemTests` checks every one against the app's backgrounds.
///
/// Stored in `UserDefaults` under `storageKey` (views use `@AppStorage`). A missing or unknown
/// value reads as `.raspberry`, which matches the `AccentColor` asset (the launch-frame tint).
nonisolated enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case raspberry, coral, indigo, viridian, aubergine, onyx

    static let storageKey = "settings.accent"
    static let `default` = AccentChoice.raspberry

    var id: String { rawValue }

    /// The stored value, falling back to the default when it is missing or unknown. Graphite,
    /// which Onyx replaced, reads as Onyx; the retired Teal and Tobacco read as the default.
    init(storedValue: String?) {
        self = storedValue.flatMap { $0 == "graphite" ? .onyx : AccentChoice(rawValue: $0) } ?? .default
    }

    /// The choice stored in `defaults`.
    static func stored(in defaults: UserDefaults = .standard) -> AccentChoice {
        AccentChoice(storedValue: defaults.string(forKey: storageKey))
    }

    var displayName: String { rawValue.capitalized }

    /// (light, dark) hex pairs.
    struct Quad: Sendable {
        var accent: (light: UInt32, dark: UInt32)
        var tint: (light: UInt32, dark: UInt32)
        var onAccent: (light: UInt32, dark: UInt32)
    }

    var quad: Quad {
        switch self {
        case .raspberry:
            Quad(accent: (0x9C3656, 0xF4A3BE), tint: (0xF5E0E8, 0x46222F), onAccent: (0xFFFFFF, 0x3A0F1F))
        case .coral:
            Quad(accent: (0x953E23, 0xF4B39E), tint: (0xF7E4DE, 0x3D221A), onAccent: (0xFFFFFF, 0x2D130B))
        case .indigo:
            Quad(accent: (0x3A52AF, 0xB4C0F4), tint: (0xE0E4F5, 0x1F2747), onAccent: (0xFFFFFF, 0x0E142A))
        case .viridian:
            Quad(accent: (0x266450, 0x7AD3B5), tint: (0xE1F4EE, 0x21362F), onAccent: (0xFFFFFF, 0x0F2920))
        case .aubergine:
            Quad(accent: (0x6E469C, 0xD2B8EE), tint: (0xEAE3F2, 0x2A1E39), onAccent: (0xFFFFFF, 0x1B1127))
        case .onyx:
            // Black in Light Mode; near-white in Dark Mode, where black would vanish.
            Quad(accent: (0x000000, 0xEDEDED), tint: (0xE4E4E4, 0x363636), onAccent: (0xFFFFFF, 0x0D0D0D))
        }
    }

    var theme: AccentTheme { AccentTheme(choice: self) }
}

/// The colours derived from an `AccentChoice`, placed in the environment (`\.accentTheme`) at
/// every window's root (`AccentRoot`). Feature code reads these instead of `Color.accentColor`
/// or the `OnAccent` asset, which cannot change at run time.
nonisolated struct AccentTheme: Equatable, Sendable {
    let choice: AccentChoice

    /// Controls, selection, links, progress.
    var accent: Color { Color(uiColor: uiAccent) }
    /// Fill behind accent text (tonal buttons, selected rows).
    var tint: Color { Palette.dynamic(light: choice.quad.tint.light, dark: choice.quad.tint.dark) }
    /// Text or icon on a solid accent fill.
    var onAccent: Color { Palette.dynamic(light: choice.quad.onAccent.light, dark: choice.quad.onAccent.dark) }

    /// The accent for UIKit (`UIWindow.tintColor`).
    var uiAccent: UIColor { Palette.uiColor(light: choice.quad.accent.light, dark: choice.quad.accent.dark) }

    static let `default` = AccentTheme(choice: .default)
}

extension EnvironmentValues {
    @Entry var accentTheme = AccentTheme.default
}

/// Applies the stored accent to a window: the environment theme, the SwiftUI tint, and the
/// window's `UIWindow.tintColor` (UIKit surfaces such as PDFKit selection handles, menus, alerts
/// and the PencilKit tool picker ignore the SwiftUI tint). Updates live when the choice changes.
struct AccentRoot: ViewModifier {
    let scene: UIWindowScene?
    @Environment(\.launchOptions) private var launchOptions
    @AppStorage(AccentChoice.storageKey) private var storedAccent = AccentChoice.default.rawValue

    private var theme: AccentTheme { AccentChoice(storedValue: storedAccent).theme }

    func body(content: Content) -> some View {
        content
            .environment(\.accentTheme, theme)
            .tint(theme.accent)
            #if DEBUG
            .background {
                if launchOptions.exposeAccent {
                    AccentProbe(choice: theme.choice).frame(width: 1, height: 1)
                }
            }
            #endif
            .onChange(of: storedAccent, initial: true) { applyToWindows() }
            .onChange(of: scene) { applyToWindows() }
            // Windows the scene adds later (alerts, the tool picker's host) start untinted.
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeVisibleNotification)) { note in
                if let window = note.object as? UIWindow, window.windowScene === scene {
                    window.tintColor = theme.uiAccent
                }
            }
    }

    private func applyToWindows() {
        guard let scene else { return }
        let colour = theme.uiAccent
        for window in scene.windows { window.tintColor = colour }
    }
}

extension View {
    /// See `AccentRoot`.
    func accentRoot(scene: UIWindowScene?) -> some View { modifier(AccentRoot(scene: scene)) }
}

#if DEBUG
/// Test hook (`-exposeAccent`): an element per window, `settings.accentProbe`, whose value is
/// read live: `theme=<preset> window=<preset|other>`, the environment's choice and the preset
/// matching this window's `UIWindow.tintColor`. Never created in normal runs, and not part of a
/// release build.
private struct AccentProbe: UIViewRepresentable {
    let choice: AccentChoice

    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) { view.choice = choice }

    final class ProbeView: UIView {
        var choice = AccentChoice.default

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            // A button trait keeps XCUITest queries fast.
            accessibilityTraits = .button
            accessibilityLabel = "Accent state"
            accessibilityIdentifier = "settings.accentProbe"
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var accessibilityValue: String? {
            get { "theme=\(choice.rawValue) window=\(windowPreset)" }
            set {}
        }

        private var windowPreset: String {
            guard let tint = window?.tintColor else { return "none" }
            let traits = UITraitCollection(userInterfaceStyle: .light)
            let resolved = Self.hex(tint.resolvedColor(with: traits))
            let match = AccentChoice.allCases.first { $0.quad.accent.light == resolved }
            return match?.rawValue ?? "other"
        }

        private static func hex(_ colour: UIColor) -> UInt32 {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.getRed(&r, green: &g, blue: &b, alpha: &a)
            func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
            return byte(r) << 16 | byte(g) << 8 | byte(b)
        }
    }
}
#endif

/// Toolbar glyphs in the label colour (design, "Toolbar glyphs"). On iPadOS 26 and later the
/// Liquid Glass capsule already marks a bar item as a button, so only a screen's one main action
/// keeps the accent (it does not use this modifier); the Library's Import uses it, by the owner's
/// choice. Filled glyphs that show state are plain too.
/// Earlier systems have no capsule, and bar items keep the accent there. The one availability
/// check for toolbar colour.
struct ToolbarGlyphTint: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tint(Color.primary)
        } else {
            content
        }
    }
}

extension View {
    /// See `ToolbarGlyphTint`.
    func toolbarGlyph() -> some View {
        modifier(ToolbarGlyphTint())
    }
}
