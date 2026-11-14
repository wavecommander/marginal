import ReaderCore
import UIKit

/// The two highlight menus: the colour choices in the text-selection edit menu, and the menu a
/// tap on a highlight opens.
///
/// Verified on the iOS 27.2 simulator: the horizontal edit menu shows menu elements by title
/// and ignores `preferredElementSize`, and four inline "… Highlight" items pushed the system's
/// Copy into the overflow page. So the selection menu adds one **"Highlight" submenu** (one
/// item in the bar) whose page lists the four colours; the system items keep their place.
@MainActor
enum HighlightMenus {
    /// Title of the selection menu's submenu.
    static let highlightTitle = "Highlight"

    /// Identifier of a colour action in the selection menu (`highlight.make.yellow`).
    static func makeActionID(_ color: HighlightColor) -> UIAction.Identifier {
        UIAction.Identifier("highlight.make.\(color.rawValue)")
    }

    /// The selection menu's entry: a "Highlight" submenu with the four colours. Each colour
    /// action's title, which is also its accessibility label, names the colour ("Yellow"); its
    /// swatch image is shown where the system shows menu images (asked for on iPadOS 27).
    static func selectionMenu(choose: @escaping @MainActor (HighlightColor) -> Void) -> UIMenu {
        let actions = HighlightColor.allCases.map { color in
            let action = UIAction(title: HighlightPalette.name(color), image: HighlightPalette.menuImage(color),
                                  identifier: makeActionID(color)) { _ in choose(color) }
            preferImageVisible(action)
            return action
        }
        return UIMenu(title: highlightTitle, image: UIImage(systemName: "highlighter"),
                      identifier: UIMenu.Identifier("highlight.make"), children: actions)
    }

    /// The tap menu: the four colours, then Copy and Delete. The current colour is marked by
    /// a check in its title ("\u{2713} Yellow") and swatch, and by its `state` (the horizontal edit
    /// menu does not draw `state`); choosing it does nothing.
    static func tapMenu(for highlight: Highlight, controller: HighlightController) -> UIMenu {
        let id = highlight.id
        let colours = HighlightColor.allCases.map { color in
            let current = color == highlight.color
            let action = UIAction(title: colorTitle(color, isCurrent: current),
                                  image: HighlightPalette.menuImage(color, checked: current),
                                  identifier: UIAction.Identifier("highlight.recolor.\(color.rawValue)")) { [weak controller] _ in
                controller?.recolor(highlightID: id, to: color)
            }
            action.state = current ? .on : .off
            preferImageVisible(action)
            return action
        }
        let colourGroup = UIMenu(title: "", options: .displayInline, children: colours)
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc"),
                            identifier: UIAction.Identifier("highlight.copy")) { [weak controller] _ in
            controller?.copyText(highlightID: id)
        }
        let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"),
                              identifier: UIAction.Identifier("highlight.delete"),
                              attributes: .destructive) { [weak controller] _ in
            controller?.delete(highlightID: id)
        }
        return UIMenu(title: "", children: [colourGroup, copy, delete])
    }

    /// Title of a colour in the tap menu (a check mark before the current one).
    static func colorTitle(_ color: HighlightColor, isCurrent: Bool) -> String {
        isCurrent ? "\u{2713} \(HighlightPalette.name(color))" : HighlightPalette.name(color)
    }

    /// Asks for the swatch to be shown next to the title (iPadOS 27's
    /// `preferredImageVisibility`; earlier systems decide themselves).
    private static func preferImageVisible(_ element: UIMenuElement) {
        if #available(iOS 27.0, *) {
            element.preferredImageVisibility = .visible
        }
    }
}

/// Presents the tap menu with a `UIEditMenuInteraction` on the PDF view (added once per view),
/// anchored at the tapped line of the highlight. Presenting an edit menu does not change the
/// first responder, so it leaves the reader's mode, the tool picker and text fields alone.
@MainActor
final class HighlightMenuPresenter: NSObject, UIEditMenuInteractionDelegate {
    weak var controller: HighlightController?
    private weak var interactionView: UIView?
    private var interaction: UIEditMenuInteraction?
    private(set) var highlightID: UUID?
    private var anchorLine: Int?
    /// Between the menu's will-present and will-dismiss callbacks.
    private(set) var isMenuVisible = false

    func present(for highlight: Highlight, in view: UIView, at point: CGPoint) {
        let interaction = interaction(for: view)
        highlightID = highlight.id
        anchorLine = lineIndex(of: highlight, near: point, in: view)
        let configuration = UIEditMenuConfiguration(identifier: "highlight.\(highlight.id.uuidString)", sourcePoint: point)
        interaction.presentEditMenu(with: configuration)
    }

    private func interaction(for view: UIView) -> UIEditMenuInteraction {
        if let interaction, interactionView === view { return interaction }
        if let interaction, let old = interactionView { old.removeInteraction(interaction) }
        let made = UIEditMenuInteraction(delegate: self)
        view.addInteraction(made)
        interaction = made
        interactionView = view
        return made
    }

    /// The line of the highlight nearest the tap (the menu points at it).
    private func lineIndex(of highlight: Highlight, near point: CGPoint, in view: UIView) -> Int? {
        guard let controller else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for index in highlight.rects.indices {
            guard let frame = controller.viewFrame(of: highlight, line: index) else { continue }
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    private var currentHighlight: Highlight? {
        guard let controller, let highlightID, let session = controller.sessionForMenus else { return nil }
        return try? session.store.highlights.highlight(id: highlightID)
    }

    // MARK: UIEditMenuInteractionDelegate

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let controller, let highlight = currentHighlight else { return nil }
        return HighlightMenus.tapMenu(for: highlight, controller: controller)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let controller, let highlight = currentHighlight,
              let frame = controller.viewFrame(of: highlight, line: anchorLine) else { return .null }
        return frame
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        isMenuVisible = true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        isMenuVisible = false
    }
}
