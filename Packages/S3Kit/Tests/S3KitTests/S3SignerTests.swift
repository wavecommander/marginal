import CryptoKit
import Foundation
import Testing
@testable import S3Kit

/// The worked examples in Amazon S3's "Signature Calculations for the Authorization Header:
/// Transferring Payload in a Single Chunk (AWS Signature Version 4)", reproduced exactly.
struct S3SignerAWSExampleTests {
    let signer = S3Signer(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                          secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
    /// 20130524T000000Z
    let date = Date(timeIntervalSince1970: 1_369_353_600)
    let credential = "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,"

    @Test func getObject() throws {
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        let headers = ["Range": "bytes=0-9"]
        let empty = S3Signer.emptyPayloadSHA256
        #expect(signer.canonicalRequest(method: "GET", url: url, headers: headers, payloadSHA256: empty, date: date) == """
            GET
            /test.txt

            host:examplebucket.s3.amazonaws.com
            range:bytes=0-9
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;range;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        #expect(signer.stringToSign(method: "GET", url: url, headers: headers, payloadSHA256: empty, date: date) == """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
            """)
        let signed = signer.sign(method: "GET", url: url, headers: headers, payloadSHA256: empty, date: date)
        #expect(signed["Authorization"] == credential + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,"
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        #expect(signed["x-amz-date"] == "20130524T000000Z")
        #expect(signed["x-amz-content-sha256"] == empty)
    }

    @Test func putObject() throws {
        let payload = Data("Welcome to Amazon S3.".utf8)
        let hash = S3Signer.hex(SHA256.hash(data: payload))
        #expect(hash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test$file.text"))
        let headers = ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"]
        #expect(signer.canonicalRequest(method: "PUT", url: url, headers: headers, payloadSHA256: hash, date: date) == """
            PUT
            /test%24file.text

            date:Fri, 24 May 2013 00:00:00 GMT
            host:examplebucket.s3.amazonaws.com
            x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
            x-amz-date:20130524T000000Z
            x-amz-storage-class:REDUCED_REDUNDANCY

            date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class
            44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
            """)
        #expect(signer.stringToSign(method: "PUT", url: url, headers: headers, payloadSHA256: hash, date: date)
            .hasSuffix("\n9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"))
        let signed = signer.sign(method: "PUT", url: url, headers: headers, payloadSHA256: hash, date: date)
        #expect(signed["Authorization"] == credential
            + "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,"
            + "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test func getBucketLifecycle() throws {
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle"))
        let empty = S3Signer.emptyPayloadSHA256
        #expect(signer.canonicalRequest(method: "GET", url: url, payloadSHA256: empty, date: date) == """
            GET
            /
            lifecycle=
            host:examplebucket.s3.amazonaws.com
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        #expect(signer.stringToSign(method: "GET", url: url, payloadSHA256: empty, date: date)
            .hasSuffix("\n9766c798316ff2757b517bc739a67f6213b4ab36dd5da2f94eaebf79c77395ca"))
        #expect(signer.sign(method: "GET", url: url, payloadSHA256: empty, date: date)["Authorization"] == credential
            + "SignedHeaders=host;x-amz-content-sha256;x-amz-date,"
            + "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    @Test func listObjects() throws {
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J"))
        let empty = S3Signer.emptyPayloadSHA256
        #expect(signer.canonicalRequest(method: "GET", url: url, payloadSHA256: empty, date: date) == """
            GET
            /
            max-keys=2&prefix=J
            host:examplebucket.s3.amazonaws.com
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        #expect(signer.stringToSign(method: "GET", url: url, payloadSHA256: empty, date: date)
            .hasSuffix("\ndf57d21db20da04d7fa30298dd4488ba3a2b47ca3a489c74750e0f1e7df1b9b7"))
        #expect(signer.sign(method: "GET", url: url, payloadSHA256: empty, date: date)["Authorization"] == credential
            + "SignedHeaders=host;x-amz-content-sha256;x-amz-date,"
            + "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func theInjectedClockSignsWhenNoDateIsGiven() throws {
        let fixed = date
        let clocked = S3Signer(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                               secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1",
                               now: { fixed })
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J"))
        #expect(clocked.sign(method: "GET", url: url, payloadSHA256: S3Signer.emptyPayloadSHA256)["Authorization"]?
            .hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }
}

struct S3SignerEncodingTests {
    @Test func uriEncodeKeepsOnlyUnreservedCharacters() {
        #expect(S3Signer.uriEncode("AZaz09-._~") == "AZaz09-._~")
        #expect(S3Signer.uriEncode("a b") == "a%20b")
        #expect(S3Signer.uriEncode("a+b") == "a%2Bb")
        #expect(S3Signer.uriEncode("a/b") == "a%2Fb")
        #expect(S3Signer.uriEncode("a/b", encodeSlash: false) == "a/b")
        #expect(S3Signer.uriEncode("!*'();:@&=$,?#[]%") == "%21%2A%27%28%29%3B%3A%40%26%3D%24%2C%3F%23%5B%5D%25")
        #expect(S3Signer.uriEncode("é") == "%C3%A9")
        #expect(S3Signer.uriEncode("📖") == "%F0%9F%93%96")
    }

    @Test func pathSegmentsAreEncodedOnceWithSlashesKept() throws {
        let url = try #require(URL(string: "https://h.example/bucket/Backups/My%20Notes%20%2B%20Caf%C3%A9.ttbackup"))
        #expect(S3Signer.canonicalURI(for: url) == "/bucket/Backups/My%20Notes%20%2B%20Caf%C3%A9.ttbackup")
        let unencoded = try #require(URL(string: "https://h.example/bucket/a$b/c=d"))
        #expect(S3Signer.canonicalURI(for: unencoded) == "/bucket/a%24b/c%3Dd")
        let doubled = try #require(URL(string: "https://h.example/bucket/a//b"))
        #expect(S3Signer.canonicalURI(for: doubled) == "/bucket/a//b", "S3 paths are not normalized")
        let root = try #require(URL(string: "https://h.example"))
        #expect(S3Signer.canonicalURI(for: root) == "/")
    }

    @Test func queryIsDecodedEncodedAndSortedByNameThenValue() throws {
        let url = try #require(URL(string:
            "https://h.example/bucket?prefix=app%2FBackups%2F&list-type=2&continuation-token=1a%2Bb%2Fc%3D%3D&uploads"))
        #expect(S3Signer.canonicalQueryString(for: url)
            == "continuation-token=1a%2Bb%2Fc%3D%3D&list-type=2&prefix=app%2FBackups%2F&uploads=")
        let spaces = try #require(URL(string: "https://h.example/bucket?b=x%20y&a=2&a=1"))
        #expect(S3Signer.canonicalQueryString(for: spaces) == "a=1&a=2&b=x%20y")
    }

    @Test func headerValuesAreTrimmedAndSpaceRunsCollapsed() throws {
        let signer = S3Signer(accessKeyID: "K", secretAccessKey: "S", region: "auto")
        let url = try #require(URL(string: "https://h.example:9000/b/k"))
        let canonical = signer.canonicalRequest(method: "get", url: url, headers: ["X-Amz-Meta-Title": "  a   b  "],
                                                payloadSHA256: S3Signer.unsignedPayload, date: Date(timeIntervalSince1970: 0))
        #expect(canonical == """
            GET
            /b/k

            host:h.example:9000
            x-amz-content-sha256:UNSIGNED-PAYLOAD
            x-amz-date:19700101T000000Z
            x-amz-meta-title:a b

            host;x-amz-content-sha256;x-amz-date;x-amz-meta-title
            UNSIGNED-PAYLOAD
            """)
    }

    @Test func theSignerNeverDescribesItsSecret() {
        let signer = S3Signer(accessKeyID: "K", secretAccessKey: StubServer.secret, region: "auto")
        #expect(!String(describing: signer).contains(StubServer.secret))
        var dumped = ""
        dump(signer, to: &dumped)
        #expect(!dumped.contains(StubServer.secret))
    }
}
