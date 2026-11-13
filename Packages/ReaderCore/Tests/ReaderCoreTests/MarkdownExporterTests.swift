import Foundation
import Testing
@testable import ReaderCore

@Suite("MarkdownExporter")
struct MarkdownExporterTests {
    let book = SeededBook()

    static let golden = """
    # Linear Algebra

    ## Front matter

    **Page 4**

    Front note

    > Preface quote (p. 4)

    ## Ch1 Vectors

    Chapter summary

    ### 1.1 Addition

    **Page 13**

    Remember: v + w

    - commutative

    ![Handwritten note](images/note-12.png)

    > Top line (p. 13)

    > Lower line (p. 13)

    ## Ch2 Matrices

    **Page 46**

    Matrix note

    ### 2.1 Products

    ![Handwritten note](<images/note 121.png>)

    **Page 56**

    > Product rule text (p. 56)

    ## Unfiled notes

    ### Old heading

    Lost thought

    **Page 151**

    Out of range

    """

    func imagePath(_ note: Note) -> String? {
        guard note.hasInk else { return nil }
        return note.id == uuid(121) ? "images/note 121.png" : "images/note-12.png"
    }

    @Test func matchesGoldenOutput() {
        let markdown = MarkdownExporter.export(book.notebook(), bookTitle: " Linear\nAlgebra ", imagePath: imagePath)
        #expect(markdown == Self.golden)
    }

    @Test func isDeterministicAndCallsTheHookOncePerNoteInOrder() {
        var calls: [UUID] = []
        let first = MarkdownExporter.export(book.notebook(), bookTitle: "Linear Algebra") { note in
            calls.append(note.id)
            return imagePath(note)
        }
        #expect(calls == [uuid(3), uuid(101), uuid(12), uuid(45), uuid(121), uuid(199), uuid(150)])
        // Same input in a different order gives the same bytes.
        let shuffled = NotebookBuilder.build(outline: book.outline, notes: book.notes.reversed(),
                                             highlights: book.highlights.reversed(), bookmarks: book.bookmarks.reversed())
        #expect(MarkdownExporter.export(shuffled, bookTitle: "Linear Algebra", imagePath: imagePath) == first)
    }

    @Test func inkOnlyNoteWithoutImageAndDeepHeadingLevels() {
        let outline = Outline(pdfEntries: (1...7).map { e("L\($0)", $0, 0) }, pageCount: 1)
        let deepest = outline.titled("L7")
        let note = Note(id: uuid(1), bookID: bookA, target: .heading(deepest.anchor), hasInk: true, createdAt: fixedDate)
        let markdown = MarkdownExporter.export(NotebookBuilder.build(outline: outline, notes: [note], highlights: []),
                                               bookTitle: "Deep")
        #expect(markdown == """
        # Deep

        ## L1

        ### L2

        #### L3

        ##### L4

        ###### L5

        ###### L6

        ###### L7

        _Handwritten note_

        """)
    }

    @Test func emptyNotebookIsJustTheTitle() {
        let markdown = MarkdownExporter.export(NotebookBuilder.build(outline: .empty, notes: [], highlights: []), bookTitle: "Empty")
        #expect(markdown == "# Empty\n")
    }
}
