import Foundation
import Testing
@testable import TactileTexts

/// `BackupServiceConfiguration`: reading `BACKUP_SERVICE_HOST` and `BACKUP_PRODUCT_IDS` from the
/// Info.plist.
struct BackupCloudServiceConfigurationTests {
    static let productID = "software.tactile.texts.backup.standard"

    static func info(host: Any?, ids: Any?) -> [String: Any] {
        var values: [String: Any] = [:]
        values["Host"] = host
        values["ProductIDs"] = ids
        return ["BackupService": values]
    }

    @Test func unsetMeansNoService() {
        #expect(BackupServiceConfiguration.fromInfoDictionary(nil) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary([:]) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(["BackupService": "nope"]) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: "", ids: "")) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: "  ", ids: " , ")) == nil)
        // Either alone is not enough.
        #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: "backup.example.com", ids: "")) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: "", ids: Self.productID)) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: nil, ids: Self.productID)) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: 7, ids: Self.productID)) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: "backup.example.com", ids: 7)) == nil)
        // This build: both settings empty.
        #expect(BackupServiceConfiguration.fromInfoDictionary() == nil)
        let built = Bundle.main.infoDictionary?["BackupService"] as? [String: Any]
        #expect(built?["Host"] as? String == "")
        #expect(built?["ProductIDs"] as? String == "")
    }

    @Test func unexpandedPlaceholdersCountAsUnset() {
        #expect(BackupServiceConfiguration.fromInfoDictionary(
            Self.info(host: "$(BACKUP_SERVICE_HOST)", ids: "$(BACKUP_PRODUCT_IDS)")) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(
            Self.info(host: "$(BACKUP_SERVICE_HOST)", ids: Self.productID)) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(
            Self.info(host: "backup.example.com", ids: "$(BACKUP_PRODUCT_IDS)")) == nil)
        #expect(BackupServiceConfiguration.fromInfoDictionary(
            Self.info(host: "backup.example.com", ids: "\(Self.productID),$(OTHER)")) == nil)
    }

    @Test func loopbackHostsUsePlainHTTP() throws {
        for (host, url) in [("localhost:8787", "http://localhost:8787"), ("127.0.0.1:8787", "http://127.0.0.1:8787"),
                            ("[::1]:8787", "http://[::1]:8787"), ("localhost", "http://localhost"),
                            ("LOCALHOST:9000", "http://LOCALHOST:9000")] {
            let configuration = try #require(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: host, ids: Self.productID)), "\(host)")
            #expect(configuration.baseURL.absoluteString == url)
            #expect(configuration.isLoopback)
        }
        let local = try #require(BackupServiceConfiguration(host: "localhost:8787", productIDs: Self.productID))
        #expect(local.host == "localhost" && local.port == 8787)
    }

    @Test func otherHostsUseHTTPS() throws {
        for (host, url) in [("backup.tactile.software", "https://backup.tactile.software"),
                            (" backup-worker.example.workers.dev ", "https://backup-worker.example.workers.dev"),
                            ("staging.example.com:8443", "https://staging.example.com:8443"),
                            ("localhost.example.com", "https://localhost.example.com"),
                            ("192.168.1.10:8787", "https://192.168.1.10:8787")] {
            let configuration = try #require(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: host, ids: Self.productID)), "\(host)")
            #expect(configuration.baseURL.absoluteString == url)
            #expect(!configuration.isLoopback)
        }
    }

    @Test func malformedHostsAreRefused() {
        for host in ["https://backup.example.com", "http://localhost:8787", "backup.example.com/v1", "backup example.com",
                     "user@backup.example.com", "backup.example.com:0", "backup.example.com:99999", "backup.example.com:http",
                     "::1", "[::2]:8787", "[::1", ".example.com", "example..com", "backup.example.com?x=1", "bäckup.example.com"] {
            #expect(BackupServiceConfiguration.fromInfoDictionary(Self.info(host: host, ids: Self.productID)) == nil, "\(host)")
        }
    }

    @Test func productIDListParsing() throws {
        let one = try #require(BackupServiceConfiguration(host: "backup.example.com", productIDs: Self.productID))
        #expect(one.productIDs == [Self.productID])
        let several = try #require(BackupServiceConfiguration(
            host: "backup.example.com", productIDs: " a.monthly , b.yearly,,a.monthly, c_family-2 ,"))
        #expect(several.productIDs == ["a.monthly", "b.yearly", "c_family-2"])
        #expect(BackupServiceConfiguration.parseProductIDs("") == [])
        #expect(BackupServiceConfiguration.parseProductIDs(",,") == [])
        // An unusable entry voids the list rather than selling a different set.
        #expect(BackupServiceConfiguration.parseProductIDs("a.monthly, b yearly") == [])
        #expect(BackupServiceConfiguration.parseProductIDs("a.monthly;b.yearly") == [])
        #expect(BackupServiceConfiguration.parseProductIDs("a.mönthly") == [])
    }

    @Test func descriptionShowsWhereAndWhat() throws {
        let configuration = try #require(BackupServiceConfiguration(host: "localhost:8787", productIDs: "a.monthly,b.yearly"))
        #expect("\(configuration)" == "BackupServiceConfiguration(http://localhost:8787, products: a.monthly, b.yearly)")
    }

    @Test func theSignInSettingsAreReadAndTheDevSecretNeverDescribed() throws {
        let secret = "DEV-SIGNIN-SECRET-must-not-leak-0123456789"
        let configuration = try #require(BackupServiceConfiguration.fromInfoDictionary(["BackupService": [
            "Host": "localhost:8787", "ProductIDs": "a.monthly", "AppleSignIn": "YES",
            "GoogleClientID": "1-abc.apps.googleusercontent.com", "DevSignIn": secret,
        ]]))
        #expect(configuration.signInWithApple)
        #expect(configuration.googleClientID == "1-abc.apps.googleusercontent.com")
        #expect(configuration.devSignInSecret == secret, "debug builds read it")
        #expect(!"\(configuration)".contains(secret) && !String(reflecting: configuration).contains(secret))
        #expect("\(configuration)".contains("Sign in with Apple, Sign in with Google"))
        let empty = try #require(BackupServiceConfiguration.fromInfoDictionary(["BackupService": [
            "Host": "localhost:8787", "ProductIDs": "a.monthly", "AppleSignIn": "$(SIGN_IN_WITH_APPLE)",
            "GoogleClientID": "", "DevSignIn": "$(BACKUP_SERVICE_DEV_SIGNIN)",
        ]]))
        #expect(!empty.signInWithApple && empty.googleClientID == nil && empty.devSignInSecret == nil)
    }
}
