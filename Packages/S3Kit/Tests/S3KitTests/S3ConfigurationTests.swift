import Testing
@testable import S3Kit

struct S3ConfigurationTests {
    @Test func anUnconfiguredBuildHasNoConfiguration() {
        #expect(S3Configuration(host: "", region: "", bucket: "", accessKeyID: "", secretAccessKey: "") == nil)
        #expect(S3Configuration(host: "h.example", region: "auto", bucket: "b", accessKeyID: "k", secretAccessKey: " ") == nil)
    }

    @Test func theHostCarriesNoSchemeOrPath() {
        #expect(S3Configuration(host: "https://h.example", region: "auto", bucket: "b", accessKeyID: "k",
                                secretAccessKey: "s") == nil)
        #expect(S3Configuration(host: "h.example/b", region: "auto", bucket: "b", accessKeyID: "k",
                                secretAccessKey: "s") == nil)
    }

    @Test func valuesAreTrimmedAndThePrefixLosesItsSlashes() throws {
        let configuration = try #require(S3Configuration(host: " h.example ", region: "auto", bucket: "b",
                                                         accessKeyID: "k", secretAccessKey: "s", prefix: "/backups/ipad/"))
        #expect(configuration.host == "h.example")
        #expect(configuration.prefix == "backups/ipad")
    }
}
