import ReaderCore
import SwiftUI

/// The map of the whole book above the Notebook's feed (design: "Notebook map"): the book's
/// top-level headings as segments, a mark at the page of every item the feed shows for the
/// current type filter and search (notes in the accent, highlights in their colour, handwriting
/// in grey), and a box around the pages the feed has on screen.
///
/// Touching or dragging along the strip shows the nearest item ("p. 181 · Highlight" and its
/// heading) and letting go scrolls the feed to it; a pointer hovering does the same without
/// scrolling. VoiceOver reads a summary, and swiping up or down moves from item to item.
struct NotebookMapStrip: View {
    let map: NotebookMap
    /// The pages the feed has on screen, if known.
    let inView: ClosedRange<Int>?
    /// Scroll the feed to this item.
    let choose: (NotebookMap.Mark) -> Void

    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.colorScheme) private var colorScheme
    /// The item under the finger or pointer (its callout shows).
    @State private var pointed: NotebookMap.Mark?
    @State private var isTouching = false
    /// VoiceOver's position among the marks.
    @State private var accessibilityIndex: Int?

    /// `UserDefaults` key: the reader hid the map (the Notebook's Hide Map button).
    static let hiddenKey = "notebook.mapHidden"
    static let barHeight: CGFloat = 28
    private static let markHeight: CGFloat = 38
    private static let markWidth: CGFloat = 4

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    segments(width: width)
                    inViewBox(width: width)
                    marks(width: width)
                }
                .frame(width: width, height: Self.barHeight, alignment: .topLeading)
                .overlay(alignment: .topLeading) { callout(width: width) }
                .contentShape(Rectangle().inset(by: -10))
                .gesture(touch(width: width))
                .onContinuousHover { phase in
                    guard !isTouching else { return }
                    switch phase {
                    case .active(let location): pointed = map.nearestMark(to: location.x / max(width, 1))
                    case .ended: pointed = nil
                    }
                }
            }
            .frame(height: Self.barHeight)
            labels
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the book")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Swipe up or down to move from item to item")
        .accessibilityAdjustableAction { direction in moveAccessibility(direction) }
        .accessibilityIdentifier(NotebookAccessibilityID.map)
    }

    // MARK: Drawing

    /// The segment the box starts in is tinted, so the current chapter stands out.
    private var currentSegmentID: String? {
        inView.flatMap { map.segment(containing: $0.lowerBound)?.id }
    }

    private func segments(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(map.segments.enumerated()), id: \.element.id) { index, segment in
                let span = map.span(of: segment.pages)
                Rectangle()
                    .fill(segment.id == currentSegmentID ? accentTheme.accent.opacity(0.18)
                                                          : Color(uiColor: index.isMultiple(of: 2) ? .systemGray5 : .systemGray6))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(uiColor: .systemBackground)).frame(width: 2)
                    }
                    .frame(width: max((span.upperBound - span.lowerBound) * width, 0))
            }
        }
        .frame(height: Self.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func inViewBox(width: CGFloat) -> some View {
        if let inView {
            let span = map.span(of: inView)
            let boxWidth = max((span.upperBound - span.lowerBound) * width + 8, 14)
            let x = min(max(span.lowerBound * width - 4, 0), max(width - boxWidth, 0))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accentTheme.accent.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(accentTheme.accent, lineWidth: 2)
                }
                .frame(width: boxWidth, height: Self.barHeight + 18)
                .offset(x: x, y: -9)
                .animation(.snappy(duration: 0.2), value: inView)
                .allowsHitTesting(false)
        }
    }

    private func marks(width: CGFloat) -> some View {
        let outline = Color(uiColor: .systemBackground)
        let marks = map.marks
        let accent = accentTheme.accent
        return Canvas { context, size in
            for mark in marks {
                let x = map.position(ofPage: mark.pageIndex) * size.width
                let rect = CGRect(x: x - Self.markWidth / 2, y: (size.height - Self.markHeight) / 2,
                                  width: Self.markWidth, height: Self.markHeight)
                let path = Path(roundedRect: rect, cornerRadius: Self.markWidth / 2)
                context.stroke(path, with: .color(outline), lineWidth: 3)
                context.fill(path, with: .color(Self.color(of: mark.kind, accent: accent)))
            }
        }
        .frame(width: width, height: Self.barHeight)
        .allowsHitTesting(false)
    }

    static func color(of kind: NotebookMap.Kind, accent: Color) -> Color {
        switch kind {
        case .sectionNote, .pageNote: accent
        case .highlight(let color): NotebookHighlightStyle.border(color)
        case .handwriting: Color(uiColor: .secondaryLabel)
        }
    }

    @ViewBuilder
    private func callout(width: CGFloat) -> some View {
        if let pointed {
            let x = map.position(ofPage: pointed.pageIndex) * width
            VStack(alignment: .leading, spacing: 1) {
                Text("\(PageNumbering.label(forPageIndex: pointed.pageIndex)) · \(pointed.kind.title)")
                    .font(.footnote.weight(.semibold))
                if !pointed.sectionTitle.isEmpty {
                    Text(pointed.sectionTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .fixedSize()
            // Centred over the item, kept inside the strip.
            .alignmentGuide(.leading) { -min(max(x - $0.width / 2, 0), max(width - $0.width, 0)) }
            .alignmentGuide(.top) { $0.height + 12 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The segments' short labels ("5"), where a segment is wide enough for one.
    private var labels: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(map.segments) { segment in
                    let span = map.span(of: segment.pages)
                    let segmentWidth = max((span.upperBound - span.lowerBound) * geometry.size.width, 0)
                    Text(segmentWidth >= 18 ? segment.shortLabel ?? "" : "")
                        .font(.caption2.weight(segment.id == currentSegmentID ? .bold : .medium))
                        .foregroundStyle(segment.id == currentSegmentID ? accentTheme.accent : .secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: segmentWidth)
                }
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    // MARK: Touch

    private func touch(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isTouching = true
                pointed = map.nearestMark(to: value.location.x / max(width, 1))
            }
            .onEnded { value in
                isTouching = false
                if let mark = map.nearestMark(to: value.location.x / max(width, 1)) { choose(mark) }
                pointed = nil
            }
    }

    // MARK: VoiceOver

    private var accessibilityValue: String {
        if let accessibilityIndex, map.marks.indices.contains(accessibilityIndex) {
            let mark = map.marks[accessibilityIndex]
            return [PageNumbering.label(forPageIndex: mark.pageIndex), mark.kind.title, mark.sectionTitle]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }
        let count = map.marks.count
        let items = "\(count) \(count == 1 ? "item" : "items")"
        if let busiest = map.busiestSegment, !busiest.title.isEmpty, map.segments.count > 1 {
            return "\(items), most in \(busiest.title)"
        }
        return items
    }

    private func moveAccessibility(_ direction: AccessibilityAdjustmentDirection) {
        guard !map.marks.isEmpty else { return }
        let current = accessibilityIndex ?? -1
        let next: Int
        switch direction {
        case .increment: next = min(current + 1, map.marks.count - 1)
        case .decrement: next = max(current - 1, 0)
        @unknown default: return
        }
        accessibilityIndex = next
        choose(map.marks[next])
    }
}
