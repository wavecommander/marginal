import ReaderCore
import SwiftUI
import UIKit

/// A small in-memory cache of decoded cover images, keyed by file path. Covers are files in the
/// book's directory (`Books/<id>/cover.jpg`), decoded off the main thread the first time a cell
/// appears and kept while memory allows.
@MainActor
final class CoverCache {
    static let shared = CoverCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    func cached(at url: URL) -> UIImage? { cache.object(forKey: url.path as NSString) }

    /// The decoded cover, or `nil` if the file is missing or unreadable.
    func image(at url: URL) async -> UIImage? {
        if let cached = cached(at: url) { return cached }
        guard let image = await Self.decode(url) else { return nil }
        cache.setObject(image, forKey: url.path as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    func remove(at url: URL) { cache.removeObject(forKey: url.path as NSString) }

    @concurrent
    nonisolated private static func decode(_ url: URL) async -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }
}

/// The cover of a book: its stored thumbnail of page one, or a coloured placeholder showing the
/// title (the mockup's cover) while it loads or when there is none. Fills the proposed size.
struct BookCoverView: View {
    let book: Book
    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?

    private static let palette: [Color] = [
        Color(red: 0.12, green: 0.23, blue: 0.37), Color(red: 0.48, green: 0.18, blue: 0.18),
        Color(red: 0.18, green: 0.36, blue: 0.31), Color(red: 0.36, green: 0.25, blue: 0.55),
        Color(red: 0.54, green: 0.29, blue: 0.07), Color(red: 0.06, green: 0.37, blue: 0.42),
        Color(red: 0.53, green: 0.21, blue: 0.34), Color(red: 0.25, green: 0.31, blue: 0.55),
    ]

    var body: some View {
        let url = environment.importService.coverURL(for: book)
        ZStack {
            if let image = image ?? CoverCache.shared.cached(at: url) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .task(id: book.id) {
            if let loaded = await CoverCache.shared.image(at: url) {
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Self.palette[LibraryLogic.paletteIndex(for: book.fingerprint, count: Self.palette.count)]
            .overlay(alignment: .topLeading) {
                Text(book.title)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .padding(12)
            }
    }
}

extension View {
    /// The book-cover shape: square-ish on the spine side, rounder on the outer edge, with a
    /// soft shadow and a hairline so white pages stay visible on a white background.
    func bookCoverStyle(cornerRadius: CGFloat = 8) -> some View {
        self
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                              bottomTrailingRadius: cornerRadius, topTrailingRadius: cornerRadius))
            .overlay {
                UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                       bottomTrailingRadius: cornerRadius, topTrailingRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}
