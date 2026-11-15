import Testing
@testable import Marginal

struct LaunchOptionsTests {
    @Test func parsesContract() {
        let options = LaunchOptions(arguments: [
            "app", "-resetState", "-importFixture", "/a.pdf", "-importFixture", "/b.pdf",
            "-openBook", "Small", "-openPage", "3", "-screen", "reader", "-inkAnyInput",
            "-markup", "-notesPanel", "section", "-alsoOpenWindow", "Large", "-selectionMenuProbe", "-bogus", "x",
            "-alsoOpenWindowPage", "9", "-seedNotebook", "-seedNotebookLateNote", "-notebookDebugWidth", "420",
        ])
        #expect(options.alsoOpenWindowPage == 9)
        #expect(options.seedNotebook && options.seedNotebookLateNote)
        #expect(options.notebookDebugWidth == 420)
        #expect(options.alsoOpenWindow == "Large")
        #expect(options.selectionMenuProbe)
        #expect(options.resetState)
        #expect(options.importFixtures.map(\.path) == ["/a.pdf", "/b.pdf"])
        #expect(options.openBook == "Small")
        #expect(options.openPage == 3)
        #expect(options.screen == .reader)
        #expect(options.inkAnyInput && options.markup)
        #expect(options.notesPanel == .section)
    }

    @Test func parsesAccent() {
        #expect(LaunchOptions(arguments: ["app", "-accent", "indigo"]).accent == .indigo)
        #expect(LaunchOptions(arguments: ["app", "-accent", "chartreuse"]).accent == nil)
        #expect(LaunchOptions(arguments: ["app", "-accent"]).accent == nil)
        #expect(LaunchOptions(arguments: ["app", "-accent", "teal", "-markup"]).markup)
    }

    @Test func parsesImportFlowSwitches() {
        let options = LaunchOptions(arguments: ["app", "-stubConverters", "-confirmConversions",
                                                "-stubConverterPageDelay", "40", "-importFixture", "/a.epub"])
        #expect(options.stubConverters && options.confirmConversions)
        #expect(options.stubConverterPageDelay == 40)
        #expect(options.importFixtures.map(\.path) == ["/a.epub"])
        #expect(LaunchOptions(arguments: ["app", "-stubConverterPageDelay", "soon"]).stubConverterPageDelay == nil)
        let plain = LaunchOptions(arguments: ["app"])
        #expect(!plain.stubConverters && !plain.confirmConversions)
    }

    @Test func defaultsAreEmpty() {
        #expect(LaunchOptions(arguments: ["app"]) == LaunchOptions())
    }
}
