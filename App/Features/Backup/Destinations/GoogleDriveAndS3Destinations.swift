import Foundation
import GoogleDriveKit
import ReaderBackup
import S3Kit

/// The cloud backup destinations this build offers, made once by the composition root.
///
/// - Google Drive is always offered; when the build has no OAuth client ID it reports itself
///   unavailable ("not set up in this build") and `googleDriveAccount.state` is `.notSetUp`.
/// - The S3-compatible bucket is offered only when the build is configured for one.
@MainActor
struct CloudBackupDestinations {
    /// The Google connection the Backup screen shows (sign in, sign out, state).
    let googleDriveAccount: GoogleDriveAccount
    let googleDrive: GoogleDriveBackupDestination
    /// `nil` unless the build names a bucket and its keys.
    let s3: S3BackupDestination?

    /// The destinations to offer, Google Drive first.
    var all: [any BackupDestination] {
        var destinations: [any BackupDestination] = [googleDrive]
        if let s3 { destinations.append(s3) }
        return destinations
    }

    /// Reads the build's configuration from `infoDictionary` and makes the destinations.
    ///
    /// - Parameters:
    ///   - tokenStore: where the Google sign-in is kept (the Keychain by default).
    ///   - webAuthentication: shows Google's sign-in page (`ASWebAuthenticationSession` by default).
    ///   - urlSession: every network request of both destinations.
    static func make(infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
                     tokenStore: any GoogleTokenStore = GoogleDriveKeychainTokenStore(),
                     webAuthentication: (any GoogleDriveWebAuthenticating)? = nil,
                     urlSession: URLSession = .shared) -> CloudBackupDestinations {
        let auth = GoogleDriveBuildConfiguration.oauthConfiguration(infoDictionary: infoDictionary).map {
            GoogleAuthSession(configuration: $0, tokenStore: tokenStore, urlSession: urlSession)
        }
        let account = GoogleDriveAccount(auth: auth, webAuthentication: webAuthentication)
        let s3 = S3BackupConfiguration.fromInfoDictionary(infoDictionary).map {
            S3BackupDestination(configuration: $0, urlSession: urlSession)
        }
        return CloudBackupDestinations(googleDriveAccount: account,
                                       googleDrive: GoogleDriveBackupDestination(account: account, urlSession: urlSession),
                                       s3: s3)
    }
}
