import CoreGraphics
import Foundation
import ReaderCore
import ReaderStore
@testable import Marginal

/// Fakes and fixtures for the text-recognition tests (S2).
@MainActor
enum TextRecognitionTestSupport {
    static let phrase = "The quiet heron measures tidewater."
    /// Zero-based page of the phrase in `scanned.pdf`.
    static let phrasePage = 16
    /// Vision's accurate box for the phrase's line in the simulator (findings, question 8).
    static let phraseBox = CGRect(x: 71, y: 692, width: 163, height: 12)

    /// An ephemeral store holding `scanned.pdf` (30 pages: a typed cover, then 29 scans).
    static func scannedFixture() throws -> SearchTestSupport.Fixture {
        try SearchTestSupport.makeFixture("scanned.pdf", pages: 30)
    }

    /// An engine on fakes: no app-state observation, no pause between pages unless asked.
    static func makeEngine(_ store: LibraryStore, recognizer: any PageRecognizing = FakePageRecognizer(),
                           conditions: FakeRecognitionConditions = FakeRecognitionConditions(),
                           readerPages: @escaping @MainActor (UUID) -> [Int] = { _ in [] },
                           pause: Duration = .zero) -> TextRecognitionEngine {
        TextRecognitionEngine(store: store, recognizer: recognizer, conditions: conditions, readerPages: readerPages,
                              pauseBetweenPages: pause, observesApplicationState: false)
    }

    /// The stored state, read off the main actor.
    static func state(_ store: LibraryStore, _ bookID: UUID) async -> RecognitionState? {
        (try? await store.recognitionState(bookID: bookID)) ?? nil
    }

    static func recognisedIndices(_ store: LibraryStore, _ bookID: UUID) async -> [Int] {
        (try? await store.recognisedPageIndices(bookID: bookID)) ?? []
    }

    /// Polls an async condition every 20 ms until it holds or `timeout` seconds pass.
    static func waitUntil(timeout: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// A recogniser that reads every page as two fixed words, optionally slowly.
nonisolated struct FakePageRecognizer: PageRecognizing {
    var delay: TimeInterval = 0

    func recognise(_ image: CGImage) throws -> [[NormalisedWord]] {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return [[NormalisedWord(text: "fake", box: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.02)),
                 NormalisedWord(text: "words", box: CGRect(x: 0.25, y: 0.5, width: 0.12, height: 0.02))]]
    }
}

/// Low Power Mode and thermal pressure the test sets.
@MainActor
final class FakeRecognitionConditions: RecognitionConditionsMonitoring {
    var onChange: (@MainActor () -> Void)?
    var isLowPowerModeEnabled = false {
        didSet { onChange?() }
    }
    var isUnderThermalPressure = false {
        didSet { onChange?() }
    }

    init(lowPower: Bool = false, thermal: Bool = false) {
        isLowPowerModeEnabled = lowPower
        isUnderThermalPressure = thermal
    }
}
