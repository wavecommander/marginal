import Foundation
import GoogleDriveKit

/// Reads the Google Drive OAuth client this build was made with.
///
/// `GoogleDriveClientID` in `Info.plist` is filled from `GOOGLE_DRIVE_CLIENT_ID` in
/// `Config/Local.xcconfig`. It is empty, or the unexpanded `$(GOOGLE_DRIVE_CLIENT_ID)`, in every
/// build that is not set up; the app then shows Google Drive as "not set up in this build".
nonisolated enum GoogleDriveBuildConfiguration {
    static let infoKey = "GoogleDriveClientID"

    /// The OAuth configuration, or `nil` when the build has no valid iOS client ID.
    static func oauthConfiguration(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> GoogleOAuthConfiguration? {
        // `GoogleOAuthConfiguration` refuses empty values, placeholders and anything that is not
        // `<id>.apps.googleusercontent.com`.
        GoogleOAuthConfiguration(clientID: infoDictionary?[infoKey] as? String)
    }
}
