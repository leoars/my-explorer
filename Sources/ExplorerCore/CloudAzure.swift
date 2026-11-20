// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Azure Blob REST with a caller-supplied SAS, never an account key or an arbitrary endpoint.
/// https://learn.microsoft.com/en-us/rest/api/storageservices/list-blobs
/// https://learn.microsoft.com/en-us/rest/api/storageservices/put-blob
struct AzureCloudBackend: CloudProviderBackend {
    private let account: String
    private let container: String
    private let sas: String
    private static let apiVersion = "2023-11-03"

    init(connection: CloudConnection, credentials: CloudCredentials) throws {
        guard let account = connection.account, (3...24).contains(account.count),
              account.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              (3...63).contains(connection.bucket.count),
              connection.bucket.first?.isASCII == true, connection.bucket.last?.isASCII == true,
              connection.bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !connection.bucket.hasPrefix("-"), !connection.bucket.hasSuffix("-"), !connection.bucket.contains("--"),
              var token = credentials.sasToken, !token.isEmpty else { throw CloudFailure(.invalidConfiguration) }
        if token.hasPrefix("?") { token.removeFirst() }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/%")
        guard !token.isEmpty, token.unicodeScalars.allSatisfy(allowed.contains), token.removingPercentEncoding != nil else {
            throw CloudFailure(.invalidConfiguration)
        }
        var query = URLComponents()
        query.percentEncodedQuery = token
        guard let items = query.queryItems, !items.isEmpty,
              items.contains(where: { $0.name == "sig" && !($0.value ?? "").isEmpty }),
              Set(items.map(\.name)).count == items.count,
              !items.contains(where: { ["comp", "restype", "prefix", "delimiter", "marker", "maxresults", "snapshot", "versionid", "deletetype"].contains($0.name.lowercased()) }) else {
            throw CloudFailure(.invalidConfiguration)
        }
        self.account = account; container = connection.bucket; sas = token
    }

    func listRequest(prefix: String, continuationToken: String?, pageSize: Int = 1000) throws -> URLRequest {
        guard (1...1000).contains(pageSize) else { throw CloudFailure(.invalidConfiguration) }
        var query = [("restype", "container"), ("comp", "list"), ("delimiter", "/"), ("maxresults", String(pageSize)), ("prefix", prefix)]
        if let continuationToken, !continuationToken.isEmpty { query.append(("marker", continuationToken)) }
        var request = try request(key: nil, query: query)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        return request
    }

    func parseList(_ response: CloudResponse) throws -> CloudPage {
        guard response.body.count <= 16 * 1024 * 1024,
              let xml = String(data: response.body, encoding: .utf8),
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { throw CloudFailure(.malformedResponse) }
        let delegate = AzureListParser()
        let parser = XMLParser(data: response.body)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.sawRoot, delegate.sawBlobs,
              delegate.objects.count <= 1000 else { throw CloudFailure(.malformedResponse) }
        return CloudPage(objects: delegate.objects, nextToken: delegate.nextToken)
    }

    func statRequest(key: String) throws -> URLRequest {
        var value = try request(key: key)
        value.httpMethod = "HEAD"
        return value
    }

    func parseStat(_ response: CloudResponse, key: String) throws -> CloudObject {
        guard let rawSize = response.header("Content-Length"), let size = Int64(rawSize), size >= 0,
              let version = response.header("ETag"), !version.isEmpty else { throw CloudFailure(.malformedResponse) }
        return CloudObject(key: key, size: size, modified: Self.httpDate(response.header("Last-Modified")),
                           isDirectory: key.hasSuffix("/"), version: version)
    }

    func uploadRequest(key: String, condition: CloudWriteCondition, integrity: CloudUploadIntegrity? = nil) throws -> URLRequest {
        var value = try request(key: key)
        value.httpMethod = "PUT"
        value.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        value.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        switch condition {
        case .absent: value.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .matches(let version):
            guard !version.isEmpty, version != "*", version == version.trimmingCharacters(in: .whitespacesAndNewlines),
                  !version.contains(","), !version.contains("\r"), !version.contains("\n") else {
                throw CloudFailure(.invalidConfiguration)
            }
            value.setValue(version, forHTTPHeaderField: "If-Match")
        }
        return value
    }

    func parseUpload(_ response: CloudResponse, key: String, size: Int64) throws -> CloudObject {
        guard let version = response.header("ETag"), !version.isEmpty else { throw CloudFailure(.malformedResponse) }
        return CloudObject(key: key, size: size, modified: Self.httpDate(response.header("Last-Modified")),
                           isDirectory: key.hasSuffix("/"), version: version)
    }

    // https://learn.microsoft.com/en-us/rest/api/storageservices/delete-blob
    func deleteRequest(key: String, matchingVersion version: String) throws -> URLRequest {
        guard !version.isEmpty, version != "*", !version.contains(","), version.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              version == version.trimmingCharacters(in: .whitespacesAndNewlines) else { throw CloudFailure(.invalidConfiguration) }
        var value = try request(key: key)
        value.httpMethod = "DELETE"
        value.setValue(version, forHTTPHeaderField: "If-Match")
        // Deliberately omit snapshot/versionid and x-ms-delete-snapshots.
        return value
    }

    func downloadRequest(key: String, matchingVersion version: String? = nil) throws -> URLRequest {
        var value = try request(key: key)
        if let version {
            guard !version.isEmpty, version != "*", !version.contains(","),
                  version.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                  version == version.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw CloudFailure(.invalidConfiguration)
            }
            value.setValue(version, forHTTPHeaderField: "If-Match")
        }
        return value
    }

    private func request(key: String?, query: [(String, String)] = []) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = account + ".blob.core.windows.net"
        var path = "/" + container
        if let key {
            guard !key.isEmpty, !key.utf8.contains(0) else { throw CloudFailure(.invalidConfiguration) }
            path += "/" + key.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0), dotSegment: true) }.joined(separator: "/")
        }
        components.percentEncodedPath = path
        let encoded = query.map { Self.encode($0.0) + "=" + Self.encode($0.1) }.joined(separator: "&")
        // Preserve the SAS bytes exactly; decoding and rebuilding can alter '+' and signatures.
        components.percentEncodedQuery = encoded.isEmpty ? sas : encoded + "&" + sas
        guard let url = components.url else { throw CloudFailure(.invalidConfiguration) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.apiVersion, forHTTPHeaderField: "x-ms-version")
        return request
    }

    private static func encode(_ value: String, dotSegment: Bool = false) -> String {
        if dotSegment && (value == "." || value == "..") { return String(repeating: "%2E", count: value.count) }
        return value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    fileprivate static func httpDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

private final class AzureListParser: NSObject, XMLParserDelegate {
    var objects: [CloudObject] = []
    var nextToken: String?
    var valid = true
    var sawRoot = false
    var sawBlobs = false
    private var elements: [String] = []
    private var text = ""
    private var current: [String: String] = [:]
    private var nameEncoded = false
    private var currentKind: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        elements.append(elementName); text = ""
        if elements.count == 1 { sawRoot = elementName == "EnumerationResults" }
        if elements == ["EnumerationResults", "Blobs"] { sawBlobs = true }
        if elementName == "Blob" || elementName == "BlobPrefix" { currentKind = elementName; current = [:] }
        if elementName == "Name", currentKind != nil { nameEncoded = attributes["Encoded"]?.lowercased() == "true" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { if !elements.isEmpty { elements.removeLast() }; text = "" }
        if currentKind != nil, ["Name", "Content-Length", "Last-Modified", "Etag", "ETag", "ResourceType"].contains(elementName) {
            if elementName == "Name" {
                if nameEncoded {
                    guard let decoded = text.removingPercentEncoding else { valid = false; parser.abortParsing(); return }
                    current[elementName] = decoded
                } else { current[elementName] = text }
            } else { current[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if elementName == "Blob" || elementName == "BlobPrefix" {
            guard let name = current["Name"], !name.isEmpty else { valid = false; parser.abortParsing(); return }
            let directory = elementName == "BlobPrefix" || current["ResourceType"] == "directory" || name.hasSuffix("/")
            let size = current["Content-Length"].flatMap(Int64.init)
            if !directory && (size == nil || size! < 0) { valid = false; parser.abortParsing(); return }
            objects.append(CloudObject(key: name, size: directory ? nil : size,
                                       modified: AzureCloudBackend.httpDate(current["Last-Modified"]), isDirectory: directory,
                                       version: current["Etag"] ?? current["ETag"]))
            currentKind = nil; current = [:]
        } else if elementName == "NextMarker" {
            nextToken = text.isEmpty ? nil : text
        }
    }
}
