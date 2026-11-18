import ReaderCore
import ReaderSync
import SwiftUI

// Bringing a book back (C5): Recently Deleted, reached from the Sync section of the Tactile
// Texts Cloud page, and Earlier Versions, from a synced book's context menu in the Library.

/// The Sync section's row that opens Recently Deleted.
struct SyncRecentlyDeletedLink: View {
    let sync: SyncController

    var body: some View {
        NavigationLink {
            SyncRecentlyDeletedView(sync: sync)
        } label: {
            Label(SyncRecoveryText.recentlyDeletedTitle, systemImage: "trash")
        }
        .accessibilityIdentifier(AccessibilityID.Sync.recentlyDeletedOpen)
    }
}

/// The account's deleted books from the last 30 days: title, when and on which device, days
/// left, and Restore with a confirmation. Empty state when there are none.
struct SyncRecentlyDeletedView: View {
    let sync: SyncController

    @State private var books: [SyncDeletedBook]?
    @State private var loadError: String?
    @State private var confirming: SyncDeletedBook?
    @State private var restoring: String?
    @State private var failure: String?
    @State private var notice: String?

    var body: some View {
        List {
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let books, !books.isEmpty {
                Section {
                    ForEach(books) { book in row(book) }
                } footer: {
                    Text(SyncRecoveryText.recentlyDeletedFooter)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.Sync.recentlyDeletedList)
        .overlay { overlay }
        .navigationTitle(SyncRecoveryText.recentlyDeletedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(confirming.map { SyncRecoveryText.restoreTitle($0.title) } ?? "", isPresented: confirmBinding,
               presenting: confirming) { book in
            Button("Cancel", role: .cancel) {}
            Button(SyncRecoveryText.restoreButton) { restore(book) }
                .accessibilityIdentifier(AccessibilityID.Sync.recentlyDeletedConfirm)
        } message: { _ in
            Text(SyncRecoveryText.restoreMessage())
        }
        .alert(String(localized: "Couldn’t Restore", comment: "Recently Deleted: title when a restore failed."),
               isPresented: failureBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let loadError, books == nil {
            ContentUnavailableView {
                Label(SyncRecoveryText.loadFailedTitle, systemImage: "exclamationmark.icloud")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if books == nil {
            ProgressView()
        } else if books?.isEmpty == true, notice == nil {
            ContentUnavailableView {
                Label(SyncRecoveryText.emptyTitle, systemImage: "trash")
                    .accessibilityIdentifier(AccessibilityID.Sync.recentlyDeletedEmpty)
            } description: {
                Text(SyncRecoveryText.emptyMessage)
            }
        }
    }

    private func row(_ book: SyncDeletedBook) -> some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(book.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(SyncRecoveryText.deletedLine(book, thisDeviceID: sync.service.deviceID()))
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                Text(SyncRecoveryText.daysLeft(book.daysLeft(now: Date())))
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Sync.recentlyDeletedRow(book.title))
            Spacer(minLength: Space.s)
            if restoring == book.bookKey {
                ProgressView()
            } else {
                Button(SyncRecoveryText.restoreButton) { confirming = book }
                    .buttonStyle(.bordered)
                    .disabled(restoring != nil)
                    .accessibilityIdentifier(AccessibilityID.Sync.recentlyDeletedRestore(book.title))
            }
        }
    }

    private func load() async {
        do {
            books = try await sync.service.recentlyDeleted()
            loadError = nil
        } catch {
            if books == nil { loadError = SyncService.message(for: error) }
        }
    }

    private func restore(_ book: SyncDeletedBook) {
        restoring = book.bookKey
        Task {
            defer { restoring = nil }
            do {
                try await sync.restoreDeleted(book)
                notice = SyncRecoveryText.restoredNotice(book.title)
                books?.removeAll { $0.bookKey == book.bookKey }
            } catch {
                failure = SyncService.message(for: error)
            }
            await load()
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }
}

/// A synced book's earlier versions (newest first: when, on which device, what it held), and
/// restoring one after a confirmation that says what will change and that it reaches the other
/// devices.
struct SyncEarlierVersionsSheet: View {
    let sync: SyncController
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @State private var versions: [SyncBookVersion]?
    @State private var current: SyncContentSummary?
    @State private var loadError: String?
    @State private var confirming: SyncBookVersion?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let versions, !versions.isEmpty {
                    Section {
                        ForEach(versions) { version in row(version) }
                    } footer: {
                        Text(SyncRecoveryText.earlierVersionsFooter)
                    }
                }
            }
            .overlay { overlay }
            .navigationTitle(SyncRecoveryText.earlierVersionsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.Sync.earlierVersionsDone)
                }
            }
            .task { await load() }
            .alert(confirming.map(SyncRecoveryText.restoreVersionTitle) ?? "", isPresented: confirmBinding,
                   presenting: confirming) { version in
                Button("Cancel", role: .cancel) {}
                Button(SyncRecoveryText.restoreVersionButton) { restore(version) }
                    .accessibilityIdentifier(AccessibilityID.Sync.earlierVersionConfirm)
            } message: { version in
                Text(SyncRecoveryText.restoreVersionMessage(title: book.title, current: current ?? .empty,
                                                            restored: version.summary ?? .empty))
            }
            .alert(String(localized: "Couldn’t Restore", comment: "Earlier Versions: title when a restore failed."),
                   isPresented: failureBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
        .accessibilityIdentifier(AccessibilityID.Sync.earlierVersionsSheet)
        .interactiveDismissDisabled(working)
    }

    @ViewBuilder
    private var overlay: some View {
        if let loadError, versions == nil {
            ContentUnavailableView {
                Label(SyncRecoveryText.loadFailedTitle, systemImage: "exclamationmark.icloud")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if versions == nil || working {
            ProgressView()
        } else if versions?.isEmpty == true {
            ContentUnavailableView {
                Label(SyncRecoveryText.noVersionsTitle, systemImage: "clock.arrow.circlepath")
                    .accessibilityIdentifier(AccessibilityID.Sync.earlierVersionsEmpty)
            } description: {
                Text(SyncRecoveryText.noVersionsMessage)
            }
        }
    }

    private func row(_ version: SyncBookVersion) -> some View {
        Button {
            confirming = version
        } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(SyncRecoveryText.versionLine(version, thisDeviceID: sync.service.deviceID()))
                    .font(.body)
                    .foregroundStyle(Palette.ink)
                Text(version.summary.map(SyncRecoveryText.summary) ?? SyncRecoveryText.versionGone)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(version.summary == nil || working)
        .accessibilityIdentifier(AccessibilityID.Sync.earlierVersion(version.version))
    }

    private func load() async {
        do {
            current = await sync.service.currentSummary(bookID: book.id)
            versions = try await sync.service.versions(bookID: book.id)
            loadError = nil
        } catch {
            if versions == nil { loadError = SyncService.message(for: error) }
        }
    }

    private func restore(_ version: SyncBookVersion) {
        working = true
        Task {
            defer { working = false }
            do {
                try await sync.restore(version, bookID: book.id)
                dismiss()
            } catch {
                failure = SyncService.message(for: error)
            }
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }
}

extension SyncContentSummary {
    nonisolated static let empty = SyncContentSummary(notes: 0, highlights: 0, bookmarks: 0, headings: 0, inkedPages: 0)
}
