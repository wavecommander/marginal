import Foundation
import Testing
@testable import Marginal

/// `BuildInfo`: reading the version and the `MarginalBuild` stamp (`scripts/stamp-build-info.sh`)
/// from the Info.plist, for Settings ▸ About.
struct BuildInfoTests {
    static func info(branch: Any? = "build-v1", commit: Any? = "1032119", dirty: Any? = false,
                     time: Any? = "2026-11-16T16:11:40Z") -> [String: Any] {
        var stamp: [String: Any] = [:]
        stamp["Branch"] = branch
        stamp["Commit"] = commit
        stamp["Dirty"] = dirty
        stamp["Time"] = time
        return ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "1", "MarginalBuild": stamp]
    }

    @Test func readsACompleteStamp() {
        let build = BuildInfo.fromInfoDictionary(Self.info())
        #expect(build.versionText == "0.1 (1)")
        #expect(build.branch == "build-v1")
        #expect(build.commit == "1032119")
        #expect(!build.hasUncommittedChanges)
        #expect(build.builtAt == Date(timeIntervalSince1970: 1_794_845_500))
        #expect(build.summary == "Tactile Texts 0.1 (1), build-v1 @ 1032119, built 2026-11-16T16:11:40Z")
    }

    @Test func noStampMeansUnknown() {
        for dictionary: [String: Any]? in [nil, [:], ["MarginalBuild": "nope"]] {
            let build = BuildInfo.fromInfoDictionary(dictionary)
            #expect(build.branch == nil)
            #expect(build.commit == nil)
            #expect(build.builtAt == nil)
            #expect(!build.hasUncommittedChanges)
        }
        #expect(BuildInfo.fromInfoDictionary(nil).versionText == nil)
        #expect(BuildInfo.fromInfoDictionary(nil).summary == "Tactile Texts unknown version, built at an unknown time")
    }

    @Test func emptyMalformedAndUnexpandedValuesAreNil() {
        let build = BuildInfo.fromInfoDictionary(Self.info(branch: "  ", commit: 7, dirty: "yes", time: "yesterday"))
        #expect(build.branch == nil)
        #expect(build.commit == nil)
        #expect(!build.hasUncommittedChanges)
        #expect(build.builtAt == nil)
        var unexpanded = Self.info()
        unexpanded["CFBundleVersion"] = "$(CURRENT_PROJECT_VERSION)"
        #expect(BuildInfo.fromInfoDictionary(unexpanded).versionText == "0.1")
    }

    @Test func detachedHeadKeepsTheCommit() {
        let build = BuildInfo.fromInfoDictionary(Self.info(branch: "", dirty: true))
        #expect(build.branch == nil)
        #expect(build.commit == "1032119")
        #expect(build.hasUncommittedChanges)
        #expect(build.summary == "Tactile Texts 0.1 (1), detached @ 1032119 (modified), built 2026-11-16T16:11:40Z")
    }

    /// This build was stamped: `scripts/test.sh` builds from a git checkout.
    @Test func thisBuildIsStamped() {
        let build = BuildInfo.current
        #expect(build.versionText != nil)
        #expect(build.commit != nil)
        #expect(build.builtAt != nil)
    }
}
