import Foundation
import ReaderBackup
import Testing
@testable import Marginal

/// Files handed to the app from outside: which flow a file starts, and whether the app may
/// consume it. (That Files lists the app under "Open With" and delivers the file is the system's
/// part, checked by hand: see docs/DEVICE_CHECKLIST.md.)
@MainActor
struct IncomingFileTests {
    @Test func theAppDeclaresItOpensDocumentsInPlace() {
        // Without this, Files shows "No Apps Available" under Open With for a backup file and
        // leaves the app out of a PDF's Open With list.
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool == true)
    }

    @Test func theAppOwnsTheBackupTypeAndAcceptsPDFs() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let handled = Dictionary(types.flatMap { type in
            ((type["LSItemContentTypes"] as? [String]) ?? []).map { ($0, type["LSHandlerRank"] as? String) }
        }, uniquingKeysWith: { first, _ in first })
        #expect(handled[BackupFormat.typeIdentifier] == "Owner")
        #expect(handled["com.adobe.pdf"] == "Alternate")
    }

    @Test func aBackupFileStartsRestoreAndEverythingElseGoesToTheImporter() {
        let backup = URL(fileURLWithPath: "/private/var/mobile/File Provider Storage/2026-11-15T14-54-01Z iPad.ttbackup")
        let upperCase = URL(fileURLWithPath: "/tmp/OLD.TTBACKUP")
        #expect(IncomingDocumentHandler.isBackup(backup))
        #expect(IncomingDocumentHandler.isBackup(upperCase))
        // A backup is a ZIP by content: it is recognised by name first, so it never reaches the
        // importer, which would take a ZIP for a comic archive.
        for name in ["Linear Algebra.pdf", "Middlemarch.epub", "Comic.cbz", "Pages.zip", "notes.txt"] {
            #expect(!IncomingDocumentHandler.isBackup(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func onlyAnInboxCopyIsTheAppsToConsume() {
        // The share sheet copies the file into the app's Inbox; Open With hands over the reader's
        // own file where it is, which must never be removed.
        let inbox = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Documents/Inbox/book.pdf")
        let inPlace = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/Y/File Provider Storage/book.pdf")
        #expect(IncomingDocumentHandler.isInInbox(inbox))
        #expect(!IncomingDocumentHandler.isInInbox(inPlace))
    }
}
