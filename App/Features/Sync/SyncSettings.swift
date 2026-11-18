import Foundation
import Observation

/// When the PDFs of synced books are downloaded (owner decision 5, `docs/CLOUD_SYNC_PLAN.md`).
nonisolated enum SyncPDFPolicy: String, CaseIterable, Identifiable, Sendable {
    /// After a round, on a network that is neither expensive (cellular, a hotspot) nor
    /// constrained (Low Data Mode). The default.
    case automaticOnWiFi
    /// Only when the reader opens the book (or asks for it).
    case onOpen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automaticOnWiFi:
            String(localized: "Automatically on Wi‑Fi", comment: "Tactile Texts Cloud ▸ Sync ▸ Download PDFs: picker option.")
        case .onOpen:
            String(localized: "Only when I open a book", comment: "Tactile Texts Cloud ▸ Sync ▸ Download PDFs: picker option.")
        }
    }
}

/// The Sync preferences, kept in `UserDefaults` beside the app's other preferences (no schema or
/// backup format change): the Sync switch **per account** (`sync.enabled.<account>`), off until
/// the reader turns it on, and the Download PDFs choice for this device. One instance per app
/// (`SyncController`), observed by every window, so the switch shows the same in each.
///
/// The switch reads as off while nobody is signed in (`accountID == nil`); the stored value for
/// each account is kept, so signing back in to the same account resumes with the switch as it
/// was, and another account starts off.
@Observable
@MainActor
final class SyncSettings {
    nonisolated enum Key {
        static let enabledPrefix = "sync.enabled."
        static let pdfPolicy = "sync.pdfPolicy"
        static func enabled(account: String) -> String { enabledPrefix + account }
    }

    /// The signed-in account sync uses (`SyncAccountProvider.currentAccountID()`), or `nil`.
    private(set) var accountID: String?
    /// The switch for `accountID`, as stored.
    private var storedEnabled = false

    /// Whether sync runs for the signed-in account: the Sync switch. Always `false` signed out;
    /// setting it then does nothing.
    var isEnabled: Bool {
        get { accountID != nil && storedEnabled }
        set {
            guard let accountID else { return }
            storedEnabled = newValue
            defaults.set(newValue, forKey: Key.enabled(account: accountID))
        }
    }

    /// When synced books' PDFs are downloaded. Automatic on Wi‑Fi by default.
    var pdfPolicy: SyncPDFPolicy {
        didSet { defaults.set(pdfPolicy.rawValue, forKey: Key.pdfPolicy) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pdfPolicy = defaults.string(forKey: Key.pdfPolicy).flatMap(SyncPDFPolicy.init(rawValue:)) ?? .automaticOnWiFi
    }

    /// The sign-in changed: show (and run) the switch of `accountID`.
    func setAccount(_ accountID: String?) {
        self.accountID = accountID
        storedEnabled = accountID.map { defaults.bool(forKey: Key.enabled(account: $0)) } ?? false
    }

    /// Forgets every account's switch and the PDF choice (`-resetState`).
    static func reset(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Key.enabledPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Key.pdfPolicy)
    }
}
