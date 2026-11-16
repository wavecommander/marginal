import Foundation

/// What this build is: its version, and the git branch, commit and time it was built from.
/// Shown in Settings ▸ About.
///
/// The version comes from `CFBundleShortVersionString` and `CFBundleVersion`. The rest is the
/// `TactileTextsBuild` dictionary, which `scripts/stamp-build-info.sh` writes into the built
/// Info.plist on every build (the committed `App/Info.plist` never has it). Anything missing,
/// empty or malformed reads as `nil`, and Settings shows "Unknown" for it.
nonisolated struct BuildInfo: Equatable, Sendable {
    static let infoKey = "TactileTextsBuild"

    var version: String?
    var buildNumber: String?
    /// `nil` on a detached HEAD, or when the build had no git.
    var branch: String?
    /// The short commit hash.
    var commit: String?
    /// Whether the checkout had uncommitted changes (including untracked files) when it was built.
    var hasUncommittedChanges: Bool
    var builtAt: Date?

    static let current = BuildInfo.fromInfoDictionary()

    static func fromInfoDictionary(_ infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> BuildInfo {
        let stamp = infoDictionary?[infoKey] as? [String: Any]
        return BuildInfo(
            version: nonEmpty(infoDictionary?["CFBundleShortVersionString"]),
            buildNumber: nonEmpty(infoDictionary?["CFBundleVersion"]),
            branch: nonEmpty(stamp?["Branch"]),
            commit: nonEmpty(stamp?["Commit"]),
            hasUncommittedChanges: stamp?["Dirty"] as? Bool ?? false,
            builtAt: nonEmpty(stamp?["Time"]).flatMap { try? Date($0, strategy: .iso8601) }
        )
    }

    /// "0.1 (1)", or whichever half is known.
    var versionText: String? {
        switch (version, buildNumber) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): "(\(build))"
        case (nil, nil): nil
        }
    }

    /// One line for a bug report: "Tactile Texts 0.1 (1), build-v1 @ 1032119 (modified), built 2026-11-16T16:11:40Z".
    var summary: String {
        var parts = ["Tactile Texts \(versionText ?? "unknown version")"]
        var source = branch ?? "detached"
        if let commit { source += " @ \(commit)" }
        if hasUncommittedChanges { source += " (modified)" }
        if branch != nil || commit != nil { parts.append(source) }
        parts.append("built \(builtAt?.formatted(.iso8601) ?? "at an unknown time")")
        return parts.joined(separator: ", ")
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty, !string.hasPrefix("$(") else { return nil }
        return string
    }
}
