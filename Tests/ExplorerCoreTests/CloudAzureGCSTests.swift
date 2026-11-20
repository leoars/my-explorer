// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class CloudAzureGCSTests: XCTestCase {
    private func azure(sas: String = "sv=2023-11-03&sp=rlcw&sig=a%2Bb%2Fc%3D") throws -> AzureCloudBackend {
        try AzureCloudBackend(connection: .init(name: "Azure test", provider: .azure, bucket: "documents", account: "exampleacct"),
                              credentials: .init(sasToken: sas))
    }
    private func gcs() throws -> GCSCloudBackend {
        try GCSCloudBackend(connection: .init(name: "GCS test", provider: .gcs, bucket: "example-bucket"),
                            credentials: .init(accessToken: "test-access-token"))
    }
    private func query(_ request: URLRequest) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func response(_ text: String) -> CloudResponse { CloudResponse(statusCode: 200, body: Data(text.utf8)) }
    private func failure(_ expected: CloudFailure.Reason, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? CloudFailure)?.reason, expected, file: file, line: line)
        }
    }

    func testAzurePreservesSASAndSpecialObjectNames() throws {
        let backend = try azure(sas: "?sv=2023-11-03&sp=rlcw&sig=a%2Bb%2Fc%3D")
        let request = try backend.uploadRequest(key: "folder/a+b #?%é.txt", condition: .absent)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "exampleacct.blob.core.windows.net")
        XCTAssertEqual(components.percentEncodedPath, "/documents/folder/a%2Bb%20%23%3F%25%C3%A9.txt")
        XCTAssertEqual(components.percentEncodedQuery, "sv=2023-11-03&sp=rlcw&sig=a%2Bb%2Fc%3D")
        XCTAssertEqual(try query(request)["sig"], "a+b/c=")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
        XCTAssertNil(request.httpBody)
        let overwrite = try backend.uploadRequest(key: "file", condition: .matches("\"etag-123\""))
        XCTAssertEqual(overwrite.value(forHTTPHeaderField: "If-Match"), "\"etag-123\"")
        XCTAssertNil(overwrite.value(forHTTPHeaderField: "If-None-Match"))
        failure(.invalidConfiguration) { _ = try backend.uploadRequest(key: "file", condition: .matches("*")) }
    }

    func testAzureListRequestCarriesOpaqueContinuationUnchanged() throws {
        let request = try azure().listRequest(prefix: "日本語/a+b/", continuationToken: "next+/= &")
        let values = try query(request)
        XCTAssertEqual(values["prefix"], "日本語/a+b/")
        XCTAssertEqual(values["marker"], "next+/= &")
        XCTAssertEqual(values["delimiter"], "/")
        XCTAssertEqual(values["restype"], "container")
        XCTAssertEqual(values["comp"], "list")
        XCTAssertEqual(values["maxresults"], "1000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/xml")
    }

    func testAzureParsesObjectsDirectoriesEncodedNamesAndNextMarker() throws {
        let page = try azure().parseList(response("""
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults><Blobs>
          <BlobPrefix><Name>photos/</Name></BlobPrefix>
          <Blob><Name> spaced &amp; é.txt </Name><Properties>
          <Content-Length>27</Content-Length><Last-Modified>Sun, 15 Nov 2026 12:00:00 GMT</Last-Modified><Etag>"abc"</Etag>
          </Properties></Blob>
          <Blob><Name Encoded="true">name%20%2B.txt</Name><Properties><Content-Length>0</Content-Length><Etag>"def"</Etag></Properties></Blob>
        </Blobs><NextMarker>opaque+/=&amp;token</NextMarker></EnumerationResults>
        """))
        XCTAssertEqual(page.objects.count, 3)
        XCTAssertEqual(page.objects[0].key, "photos/")
        XCTAssertTrue(page.objects[0].isDirectory)
        XCTAssertEqual(page.objects[1].key, " spaced & é.txt ")
        XCTAssertEqual(page.objects[1].size, 27)
        XCTAssertEqual(page.objects[1].version, "\"abc\"")
        XCTAssertNotNil(page.objects[1].modified)
        XCTAssertEqual(page.objects[2].key, "name +.txt")
        XCTAssertEqual(page.nextToken, "opaque+/=&token")
        let empty = try azure().parseList(response("<EnumerationResults><Blobs/><NextMarker/></EnumerationResults>"))
        XCTAssertTrue(empty.objects.isEmpty)
        XCTAssertNil(empty.nextToken)
    }

    func testAzureHEADAndUploadMetadataUseETag() throws {
        let backend = try azure()
        XCTAssertEqual(try backend.statRequest(key: "a/b").httpMethod, "HEAD")
        let response = CloudResponse(statusCode: 200, headers: ["content-length": "123", "eTAG": "\"tag\"", "Last-Modified": "Sun, 15 Nov 2026 12:00:00 GMT"])
        let object = try backend.parseStat(response, key: "a/b")
        XCTAssertEqual(object.size, 123)
        XCTAssertEqual(object.version, "\"tag\"")
        XCTAssertNotNil(object.modified)
        let uploaded = try backend.parseUpload(CloudResponse(statusCode: 201, headers: ["ETag": "\"new\""]), key: "a/b", size: 456)
        XCTAssertEqual(uploaded.size, 456)
        XCTAssertEqual(uploaded.version, "\"new\"")
        failure(.malformedResponse) { _ = try backend.parseStat(CloudResponse(statusCode: 200), key: "x") }
    }

    func testAzureRejectsUnsafeConfigurationAndMalformedXML() throws {
        for sas in ["sig=abc#fragment", "sig=bad%escape", "sig=a&sig=b", "sig=a&comp=delete", "sig=a\r\n", ""] {
            failure(.invalidConfiguration) { _ = try azure(sas: sas) }
        }
        failure(.invalidConfiguration) {
            _ = try AzureCloudBackend(connection: .init(name: "bad", provider: .azure, bucket: "documents", account: "evil.example/path"), credentials: .init(sasToken: "sig=x"))
        }
        for xml in ["<Error><Code>AuthenticationFailed</Code></Error>", "<EnumerationResults/>",
                    "<EnumerationResults><Blobs><Blob><Name>x</Name></Blob></Blobs></EnumerationResults>",
                    "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><EnumerationResults><Blobs/></EnumerationResults>"] {
            failure(.malformedResponse) { _ = try azure().parseList(response(xml)) }
        }
    }

    func testGCSObjectPathAndUploadQueryEncodeWholeKey() throws {
        let backend = try gcs()
        let key = "folder/a+b #?%日本語.txt"
        let request = try backend.statRequest(key: key)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/storage/v1/b/example-bucket/o/folder%2Fa%2Bb%20%23%3F%25%E6%97%A5%E6%9C%AC%E8%AA%9E.txt")
        XCTAssertEqual(components.host, "storage.googleapis.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertFalse(request.url!.absoluteString.contains("test-access-token"))
        let upload = try backend.uploadRequest(key: key, condition: .absent)
        XCTAssertEqual(upload.httpMethod, "POST")
        XCTAssertEqual(upload.url?.path, "/upload/storage/v1/b/example-bucket/o")
        XCTAssertEqual(try query(upload)["name"], key)
        XCTAssertEqual(try query(upload)["ifGenerationMatch"], "0")
        XCTAssertEqual(try query(upload)["uploadType"], "media")
        XCTAssertNil(upload.httpBody)
        let overwrite = try backend.uploadRequest(key: key, condition: .matches("1700000000012345"))
        XCTAssertEqual(try query(overwrite)["ifGenerationMatch"], "1700000000012345")
        XCTAssertEqual(try query(backend.downloadRequest(key: key))["alt"], "media")
        for generation in ["", "*", "0", "-1", "123&other=x"] {
            failure(.invalidConfiguration) { _ = try backend.uploadRequest(key: key, condition: .matches(generation)) }
        }
    }

    func testGCSListAndMetadataPreserveGenerationNotETag() throws {
        let backend = try gcs()
        let request = try backend.listRequest(prefix: "folder/+", continuationToken: "next+/= &")
        XCTAssertEqual(try query(request)["prefix"], "folder/+")
        XCTAssertEqual(try query(request)["pageToken"], "next+/= &")
        XCTAssertEqual(try query(request)["maxResults"], "1000")
        let page = try backend.parseList(response("""
        {"kind":"storage#objects","prefixes":["folder/"],"items":[
          {"name":"file é.txt","size":"123","generation":"1700000000012345","etag":"not-the-generation","updated":"2026-11-15T12:00:00.123Z"}
        ],"nextPageToken":"next+/= &"}
        """))
        XCTAssertEqual(page.objects.count, 2)
        XCTAssertTrue(page.objects[0].isDirectory)
        XCTAssertEqual(page.objects[1].key, "file é.txt")
        XCTAssertEqual(page.objects[1].size, 123)
        XCTAssertEqual(page.objects[1].version, "1700000000012345")
        XCTAssertNotNil(page.objects[1].modified)
        XCTAssertEqual(page.nextToken, "next+/= &")
        let metadata = response("{\"name\":\"file\",\"size\":\"123\",\"generation\":\"345\",\"updated\":\"2026-11-15T12:00:00Z\"}")
        XCTAssertEqual(try backend.parseStat(metadata, key: "file").version, "345")
        XCTAssertEqual(try backend.parseUpload(metadata, key: "file", size: 123).size, 123)
        failure(.malformedResponse) { _ = try backend.parseUpload(metadata, key: "other", size: 123) }
        failure(.malformedResponse) { _ = try backend.parseUpload(metadata, key: "file", size: 124) }
    }

    func testGCSRejectsMalformedListsMetadataAndTokenInjection() throws {
        let backend = try gcs()
        for json in ["{}", "{\"error\":{}}", "{\"kind\":\"storage#objects\",\"items\":[{}]}", "{\"kind\":\"storage#objects\",\"prefixes\":[\"not-a-directory\"]}"] {
            failure(.malformedResponse) { _ = try backend.parseList(response(json)) }
        }
        failure(.malformedResponse) { _ = try backend.parseStat(response("{\"name\":\"file\",\"size\":\"-1\",\"generation\":\"1\"}"), key: "file") }
        failure(.invalidConfiguration) {
            _ = try GCSCloudBackend(connection: .init(name: "bad", provider: .gcs, bucket: "example-bucket"), credentials: .init(accessToken: "token\r\nHost: evil.example"))
        }
        XCTAssertTrue(try backend.parseList(response("{\"kind\":\"storage#objects\"}")).objects.isEmpty)
    }

    func testBothProvidersRejectOversizedPages() throws {
        let blobs = String(repeating: "<BlobPrefix><Name>folder/</Name></BlobPrefix>", count: 1001)
        failure(.malformedResponse) { _ = try azure().parseList(response("<EnumerationResults><Blobs>" + blobs + "</Blobs></EnumerationResults>")) }
        let prefixes = Array(repeating: "folder/", count: 1001)
        let body = try JSONSerialization.data(withJSONObject: ["kind": "storage#objects", "prefixes": prefixes])
        failure(.malformedResponse) { _ = try gcs().parseList(CloudResponse(statusCode: 200, body: body)) }
    }
}
