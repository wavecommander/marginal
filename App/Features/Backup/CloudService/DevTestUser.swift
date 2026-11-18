#if DEBUG
import Foundation
import Observation

/// Debug builds with dev sign-in only (`BACKUP_SERVICE_DEV_SIGNIN`): the named test user the `dev`
/// Worker's test issuer signs in as. The name is the identity: every debug build and every
/// simulator signing in with the same name (and the same Worker secret) reaches the same
/// account, so two simulators can sync with each other; another name is another account.
///
/// The name comes from the build (`BACKUP_SERVICE_DEV_USER`, else `dev`), and can be changed on
/// the signed-out Tactile Texts Cloud page without rebuilding. That choice is kept in
/// `UserDefaults`; `-resetState` clears it. See `Backend/backup-worker/README.md`, "Testing sync
/// in development without Apple, Google or the App Store".
@MainActor @Observable
final class DevTestUser {
    static let defaultsKey = "software.tactile.texts.cloud-backup.dev-test-user"
    /// Where an earlier debug build kept a random subject per install (no longer used).
    static let legacySubjectKey = "software.tactile.texts.cloud-backup.dev-test-subject"
    /// The name when the build sets none.
    static let fallbackName = "dev"
    nonisolated static let maxLength = 64

    /// The build's name (`BACKUP_SERVICE_DEV_USER`, normalized), or `dev`.
    let buildName: String
    /// The name chosen on this device, or `nil` for the build's.
    private(set) var chosenName: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(buildName: String?, defaults: UserDefaults = .standard) {
        self.buildName = buildName.flatMap(Self.normalized) ?? Self.fallbackName
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey).flatMap(Self.normalized)
        chosenName = stored == self.buildName ? nil : stored
    }

    /// The name signing in now.
    var name: String { chosenName ?? buildName }
    /// The ID token's `sub` for that name. Same name, same subject.
    var subject: String { Self.subject(for: name) }

    /// Signs in as `text` (normalized) from now on; empty, unusable or the build's own name goes
    /// back to the build's.
    func setName(_ text: String) {
        let name = Self.normalized(text)
        chosenName = name == buildName ? nil : name
        if let chosenName {
            defaults.set(chosenName, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// `-resetState`: back to the build's name.
    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: legacySubjectKey)
    }

    static func subject(for name: String) -> String { "dev-user:\(name)" }

    /// The name as it signs in: trimmed, lower-cased (so `Dev` and `dev` are one user), runs of
    /// spaces as one `-`, only letters, digits and `. _ - @` kept, at most `maxLength`
    /// characters. `nil` when nothing is left.
    nonisolated static func normalized(_ raw: String) -> String? {
        let words = raw.lowercased().split(whereSeparator: { $0.isWhitespace })
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-@")
        let name = String(words.joined(separator: "-").filter { allowed.contains($0) }.prefix(maxLength))
        return name.isEmpty ? nil : name
    }
}
#endif
