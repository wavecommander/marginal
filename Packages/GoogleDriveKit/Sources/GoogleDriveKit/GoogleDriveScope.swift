import Foundation

/// The one OAuth scope the app asks for: per-file access to the files the app itself creates.
/// The app cannot see anything else in the reader's Drive.
public enum GoogleDriveScope {
    public static let driveFile = "https://www.googleapis.com/auth/drive.file"
}
