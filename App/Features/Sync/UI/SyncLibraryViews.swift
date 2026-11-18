import ReaderCore
import SwiftUI

// What sync adds to the Library and the reader: a synced book's PDF download state in place of
// "PDF missing", a quiet mark on a book that is not yet up to date, and the reader's
// downloading state for a synced book opened without its PDF.

/// The badge on the cover of a synced book whose PDF is not on this device (in place of
/// `PDFMissingBadge`).
struct SyncPDFDownloadBadge: View {
    let badge: SyncPDFBadge

    var body: some View {
        HStack(spacing: Space.xs) {
            if badge == .downloading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: badge.systemImage)
            }
            Text(badge.text)
        }
        .font(Typeface.meta)
        .foregroundStyle(Palette.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.text)
        .accessibilityValue(badge.identifierValue)
    }
}

/// The small mark on a book that is not yet up to date after the last round. Quiet: an icon in a
/// small circle, no text; the reason is in the book's context menu and in VoiceOver.
struct SyncBookStateMark: View {
    let state: SyncBookState

    var body: some View {
        Image(systemName: state.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.isFailure ? Color.orange : Color.secondary)
            .padding(Space.xs)
            .background(.regularMaterial, in: Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.title)
            .accessibilityValue(state.reason)
    }
}

/// The book's sync state in its context menu: the heading and why (no action; it syncs on its own).
struct SyncBookStateMenuSection: View {
    let state: SyncBookState

    var body: some View {
        Section(state.title) {
            Text(state.reason)
        }
    }
}

// MARK: - Reader

/// The reader's state for a synced book opened without its PDF: it downloads first, with
/// progress (indeterminate: the account's download reports none) and Cancel; a failure says why
/// with Try Again; after Cancel, Download PDF. Once the PDF is in place the reader opens the book
/// (`ReaderUnavailableView` watches for it).
struct SyncPDFReaderDownloadView: View {
    let book: Book
    let pdfs: SyncPDFDownloads

    @Environment(WindowContext.self) private var window
    @Environment(\.accentTheme) private var accentTheme
    @State private var cancelled = false

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "icloud.and.arrow.down")
                // On the title, not the whole view: a container's identifier replaces its buttons'.
                .accessibilityIdentifier(AccessibilityID.Sync.readerDownload)
        } description: {
            Text(message)
        } actions: {
            switch pdfs.states[book.id] {
            case .waiting?, .downloading?:
                ProgressView()
                    .accessibilityHidden(true)
                Button(String(localized: "Cancel", comment: "Reader: stops downloading a synced book's PDF.")) {
                    cancelled = true
                    pdfs.cancel(book.id)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.Sync.readerDownloadCancel)
            case .failed?, nil:
                Button(pdfs.states[book.id] == nil
                       ? String(localized: "Download PDF", comment: "Reader: downloads a synced book's PDF.")
                       : String(localized: "Try Again", comment: "Reader: downloads a synced book's PDF again after a failure.")) {
                    cancelled = false
                    pdfs.requestNow(book.id)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(accentTheme.onAccent)
                .accessibilityIdentifier(AccessibilityID.Sync.readerDownloadRetry)
                Button("Open Notebook") { window.openNotebook(bookID: book.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(AccessibilityID.Reader.missingPDFNotebook)
            }
        }
        .task(id: book.id) {
            // Opening the book is asking for it.
            if !cancelled, pdfs.states[book.id] == nil { pdfs.requestNow(book.id) }
        }
    }

    private var title: String {
        switch pdfs.states[book.id] {
        case .failed?: String(localized: "Couldn’t Download the PDF", comment: "Reader: title when a synced book's PDF failed to download.")
        case nil: String(localized: "PDF Not Downloaded", comment: "Reader: title for a synced book whose PDF is not on this device, after Cancel.")
        default: String(localized: "Downloading the PDF…", comment: "Reader: title while a synced book's PDF downloads.")
        }
    }

    private var message: String {
        switch pdfs.states[book.id] {
        case .failed(let reason)?:
            String(localized: "\(reason) Your notes, highlights and ink are on this device, and the Notebook works without the PDF.",
                   comment: "Reader: message when a synced book's PDF failed to download. The argument is the reason, a sentence.")
        case nil:
            String(localized: "This book’s PDF is in Tactile Texts Cloud but not on this device yet. Your notes, highlights and ink are here, and the Notebook works without it.",
                   comment: "Reader: message for a synced book whose PDF is not on this device, after Cancel.")
        default:
            String(localized: "This book came from your other devices. Its PDF is downloading from Tactile Texts Cloud and opens when it’s here.",
                   comment: "Reader: message while a synced book's PDF downloads.")
        }
    }
}
