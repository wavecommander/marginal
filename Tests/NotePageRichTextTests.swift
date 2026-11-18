import Foundation
import ReaderCore
import ReaderStore
import Testing
import UIKit
@testable import TactileTexts

@MainActor
struct NotePageRichTextTests {
    @Test func formattingControlsMutateSelectionAndPersistThroughStore() async throws {
        let (store, book) = try NotePageTestSupport.makeStore()
        let model = NotePageModel(store: store, bookID: book.id, target: .page(0),
                                  origin: ChangeOrigin(label: "test"), autosaveDelay: .milliseconds(20))
        let editor = NotePageEditorView(session: nil)
        editor.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        editor.model = model
        await model.load()

        editor.textView.text = "Hello rich world"
        editor.textViewDidChange(editor.textView)

        // Apply Bold + Underline to "rich" (UTF-16 range 6..<10).
        editor.textView.selectedRange = NSRange(location: 6, length: 4)
        editor.toggleBold()
        editor.toggleUnderline()
        #expect(editor.currentFormattingAttributes.isBold)
        #expect(editor.currentFormattingAttributes.isUnderline)

        // Apply Italic + Strikethrough to "world" (UTF-16 range 11..<16).
        editor.textView.selectedRange = NSRange(location: 11, length: 5)
        editor.toggleItalic()
        editor.toggleStrikethrough()
        #expect(editor.currentFormattingAttributes.isItalic)
        #expect(editor.currentFormattingAttributes.isStrikethrough)

        await model.flush()

        // Reload in a fresh model and editor.
        let reloaded = NotePageModel(store: store, bookID: book.id, target: .page(0),
                                     origin: ChangeOrigin(label: "test2"))
        await reloaded.load()
        #expect(reloaded.text == "Hello rich world")
        #expect(reloaded.richTextData != nil)

        let editor2 = NotePageEditorView(session: nil)
        editor2.frame = CGRect(x: 0, y: 0, width: 320, height: 500)
        editor2.model = reloaded
        await reloaded.load()

        editor2.textView.selectedRange = NSRange(location: 6, length: 4)
        #expect(editor2.currentFormattingAttributes.isBold)
        #expect(editor2.currentFormattingAttributes.isUnderline)

        editor2.textView.selectedRange = NSRange(location: 11, length: 5)
        #expect(editor2.currentFormattingAttributes.isItalic)
        #expect(editor2.currentFormattingAttributes.isStrikethrough)

        // Clear formatting on "world" and verify plain-text parts stay default.
        editor2.clearFormatting()
        #expect(editor2.currentFormattingAttributes == .default)
        await reloaded.flush()

        let snapshot = NotePageRenderer.snapshot(of: reloaded)
        #expect(snapshot.richTextData == reloaded.richTextData)
    }

    @Test func typingAttributesUpdateWhenSelectionIsEmpty() async throws {
        let (store, book) = try NotePageTestSupport.makeStore()
        let model = NotePageModel(store: store, bookID: book.id, target: .page(1),
                                  origin: ChangeOrigin(label: "test"))
        let editor = NotePageEditorView(session: nil)
        editor.model = model
        await model.load()

        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.toggleUnderline()
        editor.toggleStrikethrough()
        #expect(editor.currentFormattingAttributes.isUnderline)
        #expect(editor.currentFormattingAttributes.isStrikethrough)

        editor.clearFormatting()
        #expect(editor.currentFormattingAttributes == .default)
    }

    @Test func swiftUIAttributedTextTrimsAndShiftsFormattingOffsets() {
        let richData = NoteRichText(spans: [
            NoteTextSpan(location: 2, length: 4, attributes: NoteTextAttributes(isBold: true, isUnderline: true)),
            NoteTextSpan(location: 7, length: 4, attributes: NoteTextAttributes(isStrikethrough: true))
        ]).encoded()
        let note = Note(bookID: UUID(), target: .page(0), text: "\n Bold text\n", richTextData: richData)
        let attr = NotePageStyle.swiftUIAttributedText(for: note)
        #expect(String(attr.characters) == "Bold text")
        let runs = Array(attr.runs)
        #expect(runs.count == 3)
        #expect(runs[0].underlineStyle == .single)
        #expect(runs[2].strikethroughStyle == .single)
    }
}
