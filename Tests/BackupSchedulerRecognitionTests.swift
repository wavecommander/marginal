import Foundation
import ReaderBackup
import ReaderCore
import Testing
@testable import TactileTexts

/// S2: recognised text and recognition state are derived from the PDF and never backed up, so
/// their hub events (`StoreChange.affectsBackup == false`) never make an automatic backup due;
/// a real change still does.
@MainActor
struct BackupSchedulerRecognitionTests {
    @Test func recognitionEventsDoNotMakeABackupDueButARealChangeDoes() async throws {
        let rig = try await SchedulerRig()
        defer { rig.tearDown() }
        #expect(await rig.scheduler.runIfDue(.sceneActivated) == .succeeded)
        let success = try #require(rig.service.lastSuccessfulBackup(destinationID: rig.destination.id))
        // A day later, so only "no changes" can stop a run.
        rig.clock.now = success.addingTimeInterval(BackupDueRule.interval + 60)
        let book = try #require(try rig.store.books.allBooks().first).id

        // Recognition progress: a page, then the state. Nothing is recorded or waited for.
        let changeAt = rig.settings.lastChangeAt
        rig.store.hub.post(.recognisedTextChanged(bookID: book, pageIndex: 3), origin: nil)
        rig.store.hub.post(.recognitionStateChanged(bookID: book), origin: ChangeOrigin(label: "text recognition"))
        rig.store.hub.post(.recognisedTextChanged(bookID: book, pageIndex: nil), origin: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.sleeper.waiting == 0, "no change is being coalesced")
        rig.scheduler.flushPendingChange()
        #expect(rig.settings.lastChangeAt == changeAt)
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .notDue(.noChanges))
        #expect(try await rig.snapshots().count == 1)

        // A real change (page ink) still makes it due.
        rig.store.hub.post(.pageInkChanged(bookID: book, pageIndex: 0), origin: nil)
        #expect(await BackupTestSupport.waitUntil { rig.sleeper.waiting == 1 })
        rig.scheduler.flushPendingChange()
        #expect(rig.settings.lastChangeAt == rig.clock.now)
        #expect(await rig.scheduler.runIfDue(.foregroundCheck) == .succeeded)
        #expect(try await rig.snapshots().count == 2)
    }
}
