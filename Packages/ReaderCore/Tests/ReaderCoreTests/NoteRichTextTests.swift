import Foundation
import Testing
@testable import ReaderCore

@Suite("NoteRichText")
struct NoteRichTextTests {
    @Test func emptyOrDefaultSpansEncodeAsNil() {
        #expect(NoteRichText(spans: []).encoded() == nil)
        let onlyDefault = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 5, attributes: .default)
        ])
        #expect(onlyDefault.spans.isEmpty)
        #expect(onlyDefault.encoded() == nil)
    }

    @Test func adjacentIdenticalSpansMergeAndRoundTrip() {
        let bold = NoteTextAttributes(isBold: true)
        let italic = NoteTextAttributes(isItalic: true)
        let rich = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 3, attributes: bold),
            NoteTextSpan(location: 3, length: 2, attributes: bold),
            NoteTextSpan(location: 6, length: 4, attributes: italic)
        ])
        #expect(rich.spans.count == 2)
        #expect(rich.spans[0] == NoteTextSpan(location: 0, length: 5, attributes: bold))
        #expect(rich.spans[1] == NoteTextSpan(location: 6, length: 4, attributes: italic))

        let data = rich.encoded()
        #expect(data != nil)
        #expect(NoteRichText.decoded(from: data) == rich)
    }

    @Test func clampingTruncatesAndDropsOutOfRangeSpans() {
        let rich = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 4, attributes: NoteTextAttributes(isBold: true)),
            NoteTextSpan(location: 3, length: 10, attributes: NoteTextAttributes(isUnderline: true)),
            NoteTextSpan(location: 15, length: 2, attributes: NoteTextAttributes(isStrikethrough: true))
        ])
        let clamped = rich.clamped(toUTF16Length: 6)
        #expect(clamped.spans.count == 2)
        #expect(clamped.spans[1].location == 3)
        #expect(clamped.spans[1].length == 3)
        #expect(rich.clamped(toUTF16Length: 0).spans.isEmpty)
    }

    @Test func noteJSONWithoutRichTextDataDecodesAsNil() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "bookID": "00000000-0000-0000-0000-000000000002",
          "target": "page:0",
          "text": "Legacy note",
          "hasInk": false,
          "createdAt": 0,
          "modifiedAt": 0
        }
        """
        let note = try JSONDecoder().decode(Note.self, from: Data(legacyJSON.utf8))
        #expect(note.text == "Legacy note")
        #expect(note.richTextData == nil)
    }

    @Test func markdownRendersInlineStylesAndKeepsSpacesOutsideMarkers() {
        let text = "Hello bold world\nSecond italic line"
        let rich = NoteRichText(spans: [
            NoteTextSpan(location: 6, length: 5, attributes: NoteTextAttributes(isBold: true)), // "bold "
            NoteTextSpan(location: 24, length: 6, attributes: NoteTextAttributes(isItalic: true, isStrikethrough: true))
        ]).encoded()
        let md = NoteRichText.markdown(for: text, richTextData: rich)
        #expect(md == "Hello **bold** world\nSecond ~~*italic*~~ line")
    }

    @Test func markdownOpensAndClosesMarkersOnlyAtStyleBoundaries() {
        let rich = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 2, attributes: NoteTextAttributes(isBold: true)),
            NoteTextSpan(location: 2, length: 2, attributes: NoteTextAttributes(isBold: true, isItalic: true))
        ]).encoded()
        #expect(NoteRichText.markdown(for: "abcd", richTextData: rich) == "**ab*cd***")
    }

    @Test func sliceKeepsSpansInsideTheRangeFromZero() {
        let rich = NoteRichText(spans: [
            NoteTextSpan(location: 2, length: 6, attributes: NoteTextAttributes(isBold: true))
        ])
        #expect(rich.slice(utf16Range: NSRange(location: 5, length: 10)).spans
                == [NoteTextSpan(location: 0, length: 3, attributes: NoteTextAttributes(isBold: true))])
    }

    /// Local bolds a word, remote rewrites the paragraph: remote's text wins, and local's offsets
    /// (into the old text) are not laid over it.
    @Test func threeWayMergeTakesFormattingOnlyFromTheSideWhoseTextWon() {
        let bookID = UUID()
        let noteID = UUID()
        let base = Note(id: noteID, bookID: bookID, target: .page(0), text: "Hello world")
        let localRich = NoteRichText(spans: [
            NoteTextSpan(location: 6, length: 5, attributes: NoteTextAttributes(isBold: true))
        ]).encoded()
        let local = Note(id: noteID, bookID: bookID, target: .page(0), text: "Hello world", richTextData: localRich)
        let remote = Note(id: noteID, bookID: bookID, target: .page(0), text: "Oh, Hello world")

        let book = Book(id: bookID, title: "B", fingerprint: "fp", fileName: "b.pdf", pageCount: 1, fileSize: 1)
        let merged = BookMerge.merge(local: BookArchive(book: book, notes: [local]),
                                     remote: BookArchive(book: book, notes: [remote]),
                                     base: BookArchive(book: book, notes: [base])).archive.notes[0]
        #expect(merged.text == "Oh, Hello world")
        #expect(merged.richTextData == nil)
    }

    @Test func threeWaySyncMergePreservesFormattingPerParagraph() {
        let bookID = UUID()
        let noteID = UUID()
        let base = Note(id: noteID, bookID: bookID, target: .page(0), text: "First\nSecond")
        let localRich = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 5, attributes: NoteTextAttributes(isBold: true))
        ]).encoded()
        let local = Note(id: noteID, bookID: bookID, target: .page(0),
                         text: "First\nSecond", richTextData: localRich)

        let remoteRich = NoteRichText(spans: [
            NoteTextSpan(location: 6, length: 6, attributes: NoteTextAttributes(isItalic: true, isUnderline: true))
        ]).encoded()
        let remote = Note(id: noteID, bookID: bookID, target: .page(0),
                          text: "First\nSecond", richTextData: remoteRich)

        let book = Book(id: bookID, title: "B", fingerprint: "fp", fileName: "b.pdf", pageCount: 1, fileSize: 1)
        let merged = BookMerge.merge(local: BookArchive(book: book, notes: [local]),
                                     remote: BookArchive(book: book, notes: [remote]),
                                     base: BookArchive(book: book, notes: [base])).archive.notes[0]
        #expect(merged.text == "First\nSecond")
        let decoded = NoteRichText.decoded(from: merged.richTextData)
        #expect(decoded?.spans == [
            NoteTextSpan(location: 0, length: 5, attributes: NoteTextAttributes(isBold: true)),
            NoteTextSpan(location: 6, length: 6, attributes: NoteTextAttributes(isItalic: true, isUnderline: true))
        ])
    }

    @Test func twoWayBookMergeRemapsFormattingAcrossAddedParagraphs() {
        let bookID = UUID()
        let localRich = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 5, attributes: NoteTextAttributes(isBold: true))
        ]).encoded()
        let local = Note(bookID: bookID, target: .page(0), text: "Alpha", richTextData: localRich)

        let incomingRich = NoteRichText(spans: [
            NoteTextSpan(location: 0, length: 4, attributes: NoteTextAttributes(isUnderline: true))
        ]).encoded()
        let incoming = Note(bookID: bookID, target: .page(0), text: "Beta", richTextData: incomingRich)

        let result = BookMerge.merge(local: BookArchive(book: Book(id: bookID, title: "B", fingerprint: "fp",
                                                                   fileName: "b.pdf", pageCount: 1, fileSize: 1),
                                                        notes: [local]),
                                     incoming: BookArchive(book: Book(id: bookID, title: "B", fingerprint: "fp",
                                                                      fileName: "b.pdf", pageCount: 1, fileSize: 1),
                                                           notes: [incoming]))
        let mergedNote = result.archive.notes[0]
        #expect(mergedNote.text == "Alpha\nBeta")
        let decoded = NoteRichText.decoded(from: mergedNote.richTextData)
        #expect(decoded?.spans == [
            NoteTextSpan(location: 0, length: 5, attributes: NoteTextAttributes(isBold: true)),
            NoteTextSpan(location: 6, length: 4, attributes: NoteTextAttributes(isUnderline: true))
        ])
    }
}
