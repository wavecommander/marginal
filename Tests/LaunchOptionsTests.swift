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

    @Test func parsesHardwareKeyboard() {
        #expect(LaunchOptions(arguments: ["app"]).hardwareKeyboard == nil)
        #expect(LaunchOptions(arguments: ["app", "-hardwareKeyboard", "yes"]).hardwareKeyboard == true)
        #expect(LaunchOptions(arguments: ["app", "-hardwareKeyboard", "no"]).hardwareKeyboard == false)
        #expect(LaunchOptions(arguments: ["app", "-hardwareKeyboard", "maybe"]).hardwareKeyboard == nil)
        let next = LaunchOptions(arguments: ["app", "-hardwareKeyboard", "no", "-markup"])
        #expect(next.hardwareKeyboard == false && next.markup)
    }

    @Test func parsesAccent() {
        #expect(LaunchOptions(arguments: ["app", "-accent", "indigo"]).accent == .indigo)
        #expect(LaunchOptions(arguments: ["app", "-accent", "chartreuse"]).accent == nil)
        #expect(LaunchOptions(arguments: ["app", "-accent"]).accent == nil)
        #expect(LaunchOptions(arguments: ["app", "-accent", "teal", "-markup"]).markup)
    }

    @Test func parsesBackupFolder() {
        let options = LaunchOptions(arguments: ["app", "-backupFolder", "/tmp/Backups Test", "-markup"])
        #expect(options.backupFolder?.path == "/tmp/Backups Test")
        #expect(options.markup)
        #expect(LaunchOptions(arguments: ["app", "-backupFolder"]).backupFolder == nil)
        #expect(LaunchOptions(arguments: ["app", "-backupFolder", "relative/path"]).backupFolder == nil)
        #expect(LaunchOptions().backupFolder == nil)
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
        #expect(LaunchOptions(arguments: ["app"], environment: ["HOME": "/"]) == LaunchOptions())
    }

    /// The switches that used to be read where they were used (process arguments, the
    /// environment, the arguments domain of `UserDefaults`).
    @Test func parsesProbesSeedsAndDebugSwitches() {
        let options = LaunchOptions(arguments: [
            "app", "-perfProbe", "-perfAutoScroll", "-sidebarDebugStats", "-sidebarAutoScroll",
            "-seedSidebar", "-seedSidebarHeadings", "-searchPageDelayMs", "60", "-pageInkDebug", "-markup",
        ])
        #expect(options.perfProbe && options.perfAutoScroll)
        #expect(options.sidebarDebugStats && options.sidebarAutoScroll)
        #expect(options.seedSidebar && options.seedSidebarHeadings)
        #expect(options.searchPageDelayMs == 60)
        #expect(options.pageInkDebug && options.markup)

        let plain = LaunchOptions(arguments: ["app"])
        #expect(!plain.perfProbe && !plain.perfAutoScroll && !plain.sidebarDebugStats && !plain.sidebarAutoScroll)
        #expect(!plain.seedSidebar && !plain.seedSidebarHeadings && !plain.pageInkDebug)
        #expect(plain.searchPageDelayMs == nil)
        #expect(LaunchOptions(arguments: ["app", "-searchPageDelayMs", "-5"]).searchPageDelayMs == nil)
        #expect(LaunchOptions(arguments: ["app", "-searchPageDelayMs", "soon", "-markup"]).markup)
        #expect(LaunchOptions(arguments: ["app", "-searchPageDelayMs"]).searchPageDelayMs == nil)
    }

    @Test func pageInkDebugAlsoComesFromTheEnvironment() {
        #expect(LaunchOptions(arguments: ["app"], environment: ["PAGE_INK_DEBUG": "1"]).pageInkDebug)
        #expect(LaunchOptions(arguments: ["app"], environment: ["PAGE_INK_DEBUG": ""]).pageInkDebug)
        #expect(!LaunchOptions(arguments: ["app"], environment: ["OTHER": "1"]).pageInkDebug)
    }
}
