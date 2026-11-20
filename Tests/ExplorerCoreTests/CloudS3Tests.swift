// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class CloudS3Tests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_369_353_600)
    private var credentials: CloudCredentials {
        CloudCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    }
    private func backend(bucket: String = "examplebucket", region: String = "us-east-1", token: String? = nil) throws -> S3CloudBackend {
        let fixedDate = date
        return try S3CloudBackend(connection: CloudConnection(name: "Test", provider: .s3, bucket: bucket, region: region),
                                  credentials: CloudCredentials(accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey,
                                                                sessionToken: token), now: { fixedDate })
    }

    func testAWSListFormEncodingPreservesPlusPercentAndOpaqueToken() throws {
        let provider = try backend()
        let xml = """
        <ListBucketResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>
        <Contents><Key>fixture/Ol%C3%A1+%E6%97%A5%E6%9C%AC%E8%AA%9E+%2B+%25+%23+%26.txt</Key><Size>17</Size></Contents>
        <Contents><Key>fixture/literal%2520%2B%252B.txt</Key><Size>0</Size></Contents>
        <CommonPrefixes><Prefix>fixture/folder+%2B+%2520/</Prefix></CommonPrefixes>
        <NextContinuationToken>opaque+/=%2B&amp;</NextContinuationToken>
        </ListBucketResult>
        """
        let page = try provider.parseList(.init(statusCode: 200, body: Data(xml.utf8)))
        XCTAssertEqual(page.objects.map(\.key), ["fixture/Olá 日本語 + % # &.txt", "fixture/literal%20+%2B.txt", "fixture/folder + %20/"])
        XCTAssertTrue(page.objects[2].isDirectory)
        XCTAssertEqual(page.nextToken, "opaque+/=%2B&")
        let unencoded = "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>raw+a%20b.txt</Key><Size>0</Size></Contents></ListBucketResult>"
        XCTAssertEqual(try provider.parseList(.init(statusCode: 200, body: Data(unencoded.utf8))).objects.first?.key, "raw+a%20b.txt")
    }

    func testSignatureMatchesOfficialAWSGETObjectVector() throws {
        // Public AWS example credentials, never real credentials.
        // https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let signed = try S3SignatureV4.sign(request, accessKeyID: credentials.accessKeyID!, secretAccessKey: credentials.secretAccessKey!,
                                            region: "us-east-1", date: date)
        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testSignatureMatchesOfficialAWSListQueryVector() throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?prefix=J&max-keys=2")!)
        request.httpMethod = "GET"
        let signed = try S3SignatureV4.sign(request, accessKeyID: credentials.accessKeyID!, secretAccessKey: credentials.secretAccessKey!,
                                            region: "us-east-1", date: date)
        XCTAssertTrue(signed.value(forHTTPHeaderField: "Authorization")!.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"))
        XCTAssertEqual(S3SignatureV4.canonicalQuery([("a", "+ /"), ("a", "="), ("é", "東京")]),
                       "%C3%A9=%E6%9D%B1%E4%BA%AC&a=%2B%20%2F&a=%3D")
    }

    func testKeysAndOpaqueTokensAreEncodedOnceWithoutChangingObjectIdentity() throws {
        let provider = try backend(token: "temporary/session+token=")
        let request = try provider.downloadRequest(key: "folder//a b+%?#/東京.txt")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://examplebucket.s3.us-east-1.amazonaws.com/folder//a%20b%2B%25%3F%23/%E6%9D%B1%E4%BA%AC.txt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-security-token"), "temporary/session+token=")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("x-amz-security-token"))
        let list = try provider.listRequest(prefix: "photos/é+", continuationToken: "opaque+/=%&")
        let query = URLComponents(url: list.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "prefix" }?.value, "photos/é+")
        XCTAssertEqual(query.first { $0.name == "continuation-token" }?.value, "opaque+/=%&")
        XCTAssertEqual(query.first { $0.name == "max-keys" }?.value, "1000")
        XCTAssertEqual(query.first { $0.name == "encoding-type" }?.value, "url")
        XCTAssertThrowsError(try provider.downloadRequest(key: "a/../wrong-object"))
    }

    func testDottedBucketsUseTLSCompatiblePathStyleAndRejectHostInjection() throws {
        let request = try backend(bucket: "my.bucket", region: "eu-west-1").downloadRequest(key: "file.txt")
        XCTAssertEqual(request.url?.absoluteString, "https://s3.eu-west-1.amazonaws.com/my.bucket/file.txt")
        let china = try backend(region: "cn-north-1").statRequest(key: "file")
        XCTAssertEqual(china.url?.host, "examplebucket.s3.cn-north-1.amazonaws.com.cn")
        for bucket in ["evil.example/other", "evil@host", "a..b", "127.0.0.1", "x", "directory--x-s3"] {
            XCTAssertThrowsError(try backend(bucket: bucket))
        }
        XCTAssertThrowsError(try backend(region: "us-east-1.evil.example"))
        XCTAssertThrowsError(try backend(token: "token\r\nAuthorization: evil"))
    }

    func testUploadsAlwaysHaveSignedWritePreconditions() throws {
        let provider = try backend()
        let absent = try provider.uploadRequest(key: "data.bin", condition: .absent)
        XCTAssertEqual(absent.httpMethod, "PUT")
        XCTAssertEqual(absent.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertTrue(absent.value(forHTTPHeaderField: "Authorization")!.contains("if-none-match"))
        XCTAssertEqual(absent.value(forHTTPHeaderField: "x-amz-content-sha256"), "UNSIGNED-PAYLOAD")
        XCTAssertNil(absent.httpBody)
        let matched = try provider.uploadRequest(key: "data.bin", condition: .matches("\"version-etag\""))
        XCTAssertEqual(matched.value(forHTTPHeaderField: "If-Match"), "\"version-etag\"")
        XCTAssertTrue(matched.value(forHTTPHeaderField: "Authorization")!.contains("if-match"))
        XCTAssertThrowsError(try provider.uploadRequest(key: "data.bin", condition: .matches("*")))
        XCTAssertThrowsError(try provider.uploadRequest(key: "data.bin", condition: .matches("\"etag\"\nInjected: true")))
    }

    func testListDecodesUnicodeKeysPrefixesAndPreservesContinuationToken() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>
          <Contents><Key>folder%2F%E6%9D%B1%E4%BA%AC%20%2B.txt</Key><Size>123</Size>
          <LastModified>2026-11-15T00:00:00.000Z</LastModified><ETag>&quot;etag-1&quot;</ETag></Contents>
          <CommonPrefixes><Prefix>sub%20folder%2F</Prefix></CommonPrefixes>
          <NextContinuationToken>opaque+/=%&amp;</NextContinuationToken>
        </ListBucketResult>
        """
        let page = try backend().parseList(CloudResponse(statusCode: 200, body: Data(xml.utf8)))
        XCTAssertEqual(page.nextToken, "opaque+/=%&")
        XCTAssertEqual(page.objects.count, 2)
        XCTAssertEqual(page.objects[0].key, "folder/東京 +.txt")
        XCTAssertEqual(page.objects[0].size, 123)
        XCTAssertEqual(page.objects[0].version, "\"etag-1\"")
        XCTAssertNotNil(page.objects[0].modified)
        XCTAssertEqual(page.objects[1].key, "sub folder/")
        XCTAssertTrue(page.objects[1].isDirectory)
    }

    func testMalformedTruncatedAndEntityXMLAreRejected() throws {
        let samples = [
            "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>",
            "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a</Key><Size>-1</Size></Contents></ListBucketResult>",
            "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Size>1</Size></Contents></ListBucketResult>",
            "<ListBucketResult><IsTruncated>false</IsTruncated>",
            "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><ListBucketResult><IsTruncated>false</IsTruncated>&e;</ListBucketResult>",
            "<Unexpected><IsTruncated>false</IsTruncated></Unexpected>"
        ]
        for xml in samples {
            XCTAssertThrowsError(try backend().parseList(CloudResponse(statusCode: 200, body: Data(xml.utf8)))) { error in
                XCTAssertEqual((error as? CloudFailure)?.reason, .malformedResponse)
            }
        }
        let empty = try backend().parseList(CloudResponse(statusCode: 200, body: Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8)))
        XCTAssertTrue(empty.objects.isEmpty)
        XCTAssertNil(empty.nextToken)
    }

    func testStatAndUploadUseETagRatherThanAWSVersionIDForConditions() throws {
        let provider = try backend()
        let response = CloudResponse(statusCode: 200, headers: ["content-length": "42", "ETag": "\"etag\"",
                                                                "x-amz-version-id": "other-version", "Last-Modified": "Sun, 15 Nov 2026 00:00:00 GMT"])
        let object = try provider.parseStat(response, key: "file")
        XCTAssertEqual(object.version, "\"etag\"")
        XCTAssertEqual(object.size, 42)
        XCTAssertNotNil(object.modified)
        XCTAssertEqual(try provider.parseUpload(response, key: "file", size: 99).size, 99)
        XCTAssertThrowsError(try provider.parseStat(CloudResponse(statusCode: 200), key: "file"))
        XCTAssertThrowsError(try provider.parseUpload(CloudResponse(statusCode: 200), key: "file", size: 1))
    }
}
