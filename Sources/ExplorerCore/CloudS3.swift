// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit

/// AWS Signature Version 4 for S3. Paths are encoded byte-for-byte and never normalized.
/// Reference/test vectors: https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
internal enum S3SignatureV4 {
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func encode(_ text: String, preservingSlashes: Bool = false) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        for byte in text.utf8 {
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
                [45, 46, 95, 126].contains(byte) || (preservingSlashes && byte == 47) {
                bytes.append(byte)
            } else {
                bytes.append(37); bytes.append(hexadecimal[Int(byte >> 4)]); bytes.append(hexadecimal[Int(byte & 15)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(String, String)] = items.map { (encode($0.0), encode($0.1)) }
        let sorted = encoded.sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    static func sign(_ original: URLRequest, accessKeyID: String, secretAccessKey: String,
                     sessionToken: String? = nil, region: String, date: Date,
                     payloadHash: String = emptyPayloadHash) throws -> URLRequest {
        guard let url = original.url, let host = url.host,
              url.scheme == "https", url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              validHeaderValue(accessKeyID), validHeaderValue(secretAccessKey),
              sessionToken.map(validHeaderValue) ?? true else { throw CloudFailure(.invalidConfiguration) }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        var request = original
        request.setValue(host + (url.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let sessionToken, !sessionToken.isEmpty { request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token") }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let emptyMetadataField = value.isEmpty && name.lowercased().hasPrefix("x-amz-meta-")
            guard emptyMetadataField || validHeaderValue(value) else { throw CloudFailure(.invalidConfiguration) }
            headers[name.lowercased()] = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        // URLComponents.queryItems percent-decodes exactly once; '+' remains a literal plus.
        let query = canonicalQuery((components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let canonicalRequest = [request.httpMethod ?? "GET", path, query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        let dayKey = hmac(Data(("AWS4" + secretAccessKey).utf8), day)
        let regionKey = hmac(dayKey, region)
        let serviceKey = hmac(regionKey, "s3")
        let signingKey = hmac(serviceKey, "aws4_request")
        let signature = hex(hmac(signingKey, stringToSign))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope),SignedHeaders=\(signedHeaders),Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func validHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
    private static func hmac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
    private static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct S3ObjectMetadata: Codable, Equatable, Sendable {
    public let contentType: String?
    public let userMetadata: [String: String]

    init(response: CloudResponse) throws {
        guard response.header("x-amz-missing-meta").map({ Int($0) == 0 }) ?? true else {
            throw CloudFailure(.malformedResponse)
        }
        contentType = response.header("Content-Type")
        var fields: [String: String] = [:]
        for (header, value) in response.headers {
            let name = header.lowercased()
            if name.hasPrefix("x-amz-meta-") { fields[String(name.dropFirst(11))] = value }
        }
        userMetadata = fields
        _ = try uploadHeaders()
    }

    func uploadHeaders() throws -> [String: String] {
        var headers: [String: String] = [:]
        if let contentType {
            guard S3SignatureV4.validHeaderValue(contentType) else { throw CloudFailure(.malformedResponse) }
            headers["Content-Type"] = contentType
        }
        for (name, value) in userMetadata {
            // RFC 9110 HTTP field names are tokens; metadata must never introduce unrelated headers.
            guard !name.isEmpty, name.utf8.allSatisfy({ byte in
                (97...122).contains(byte) || (48...57).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
            }), value.isEmpty || S3SignatureV4.validHeaderValue(value) else { throw CloudFailure(.malformedResponse) }
            headers["x-amz-meta-" + name] = value
        }
        return headers
    }
}

internal struct S3CloudBackend: CloudProviderBackend {
    let connection: CloudConnection
    let credentials: CloudCredentials
    private let region: String
    private let host: String
    private let bucketPath: String
    private let now: @Sendable () -> Date

    init(connection: CloudConnection, credentials: CloudCredentials, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let bucket = connection.bucket, region = connection.region ?? "us-east-1"
        let validBucket = bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil &&
            !bucket.contains("..") && !bucket.contains(".-") && !bucket.contains("-.") &&
            bucket.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) == nil &&
            !bucket.hasSuffix("--x-s3")
        guard validBucket else { throw CloudFailure(.invalidConfiguration) }
        try Self.validate(credentials, region: region)
        self.connection = connection; self.credentials = credentials; self.region = region; self.now = now
        let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        // Dotted bucket names do not match S3's wildcard TLS certificate in virtual-hosted style.
        if bucket.contains(".") {
            host = "s3.\(region).\(suffix)"
            bucketPath = "/" + bucket
        } else {
            host = "\(bucket).s3.\(region).\(suffix)"
            bucketPath = ""
        }
    }

    static func validate(_ credentials: CloudCredentials, region: String) throws {
        guard region.utf8.count <= 64,
              region.range(of: #"\A[a-z]{2}(-[a-z]+)+-[0-9]+\z"#, options: .regularExpression) != nil,
              let access = credentials.accessKeyID, !access.isEmpty,
              access.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              let secret = credentials.secretAccessKey, S3SignatureV4.validHeaderValue(secret),
              credentials.sessionToken.map(S3SignatureV4.validHeaderValue) ?? true else {
            throw CloudFailure(.invalidConfiguration)
        }
    }

    func listRequest(prefix: String, continuationToken: String?, pageSize: Int = 1000) throws -> URLRequest {
        guard (1...1000).contains(pageSize) else { throw CloudFailure(.invalidConfiguration) }
        var query = [("list-type", "2"), ("delimiter", "/"), ("encoding-type", "url"), ("prefix", prefix), ("max-keys", String(pageSize))]
        if let token = continuationToken { query.append(("continuation-token", token)) }
        return try request(method: "GET", key: nil, query: query)
    }

    func parseList(_ response: CloudResponse) throws -> CloudPage {
        guard response.body.count <= 8 * 1024 * 1024,
              let text = String(data: response.body, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw CloudFailure(.malformedResponse) }
        let delegate = S3ListParser()
        let parser = XMLParser(data: response.body)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.root == "ListBucketResult",
              let truncated = delegate.truncated else { throw CloudFailure(.malformedResponse) }
        let token = delegate.nextToken.flatMap { $0.isEmpty ? nil : $0 }
        guard !truncated || token != nil else { throw CloudFailure(.malformedResponse) }
        func key(_ raw: String) throws -> String {
            if delegate.encoding == "url" {
                // S3 ListObjectsV2 uses '+' for spaces with EncodingType=url; a literal '+' is %2B.
                // Decode once, in this order, so %2B and literal percent sequences retain their identity.
                guard let value = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                    throw CloudFailure(.malformedResponse)
                }
                return value
            }
            return raw
        }
        guard delegate.objects.count + delegate.prefixes.count <= 1000 else { throw CloudFailure(.malformedResponse) }
        var objects: [CloudObject] = []
        for object in delegate.objects {
            guard let raw = object["Key"], !raw.isEmpty, let sizeText = object["Size"],
                  let size = Int64(sizeText), size >= 0 else { throw CloudFailure(.malformedResponse) }
            let name = try key(raw)
            objects.append(CloudObject(key: name, size: size, modified: object["LastModified"].flatMap(Self.isoDate),
                                       isDirectory: name.hasSuffix("/"), version: object["ETag"]))
        }
        for prefix in delegate.prefixes {
            let name = try key(prefix)
            guard !name.isEmpty else { throw CloudFailure(.malformedResponse) }
            if !objects.contains(where: { $0.key == name && $0.isDirectory }) {
                objects.append(CloudObject(key: name, size: nil, modified: nil, isDirectory: true, version: nil))
            }
        }
        return CloudPage(objects: objects, nextToken: truncated ? token : nil)
    }

    func statRequest(key: String) throws -> URLRequest { try request(method: "HEAD", key: key) }
    func parseStat(_ response: CloudResponse, key: String) throws -> CloudObject {
        guard let raw = response.header("Content-Length"), let size = Int64(raw), size >= 0 else {
            throw CloudFailure(.malformedResponse)
        }
        return CloudObject(key: key, size: size, modified: response.header("Last-Modified").flatMap(Self.httpDate),
                           isDirectory: key.hasSuffix("/"), version: response.header("ETag"))
    }
    func uploadRequest(key: String, condition: CloudWriteCondition, integrity: CloudUploadIntegrity? = nil) throws -> URLRequest {
        try uploadRequest(key: key, condition: condition, integrity: integrity, metadata: nil)
    }

    func uploadRequest(key: String, condition: CloudWriteCondition, integrity: CloudUploadIntegrity?,
                       metadata: S3ObjectMetadata?) throws -> URLRequest {
        var headers: [String: String]
        switch condition {
        case .absent: headers = ["If-None-Match": "*"]
        case .matches(let version):
            try Self.validateETag(version)
            headers = ["If-Match": version]
        }
        for (name, value) in try metadata?.uploadHeaders() ?? [:] { headers[name] = value }
        if let integrity {
            headers["Content-Length"] = String(integrity.size)
            headers["x-amz-checksum-sha256"] = integrity.sha256Base64
        }
        return try request(method: "PUT", key: key, headers: headers, payloadHash: integrity?.sha256Hex ?? "UNSIGNED-PAYLOAD")
    }
    func parseUpload(_ response: CloudResponse, key: String, size: Int64) throws -> CloudObject {
        guard let version = response.header("ETag"), !version.isEmpty else { throw CloudFailure(.malformedResponse) }
        return CloudObject(key: key, size: size, modified: nil, isDirectory: key.hasSuffix("/"), version: version)
    }
    // https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-deletes.html
    func deleteRequest(key: String, matchingVersion version: String) throws -> URLRequest {
        try Self.validateETag(version)
        return try request(method: "DELETE", key: key, headers: ["If-Match": version])
    }

    func copyRequest(source: String, matchingVersion: String, destination: String) throws -> URLRequest {
        try Self.validateETag(matchingVersion)
        let encodedSource = S3SignatureV4.encode(source, preservingSlashes: true)
        return try request(method: "PUT", key: destination, headers: [
            "x-amz-copy-source": "/" + connection.bucket + "/" + encodedSource,
            "x-amz-copy-source-if-match": matchingVersion,
            "If-None-Match": "*"
        ])
    }

    // CopyObject can return HTTP 200 with an error in the XML body.
    func copiedETag(_ response: CloudResponse) throws -> String {
        guard response.statusCode == 200, response.body.count <= 64 * 1024,
              let xml = String(data: response.body, encoding: .utf8),
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY"),
              let root = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]).rootElement(),
              root.localName == "CopyObjectResult" else { throw CloudFailure(.malformedResponse) }
        let tags = root.elements(forName: "ETag")
        guard tags.count == 1, let tag = tags.first?.stringValue,
              tag.utf8.count > 2, tag.first == "\"", tag.last == "\"" else { throw CloudFailure(.malformedResponse) }
        try Self.validateETag(tag)
        return tag
    }

    func downloadRequest(key: String, matchingVersion: String? = nil) throws -> URLRequest {
        var headers = ["x-amz-checksum-mode": "ENABLED"]
        if let matchingVersion { try Self.validateETag(matchingVersion); headers["If-Match"] = matchingVersion }
        return try request(method: "GET", key: key, headers: headers)
    }

    private static func validateETag(_ value: String) throws {
        guard S3SignatureV4.validHeaderValue(value), value != "*", !value.contains(","),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CloudFailure(.invalidConfiguration)
        }
    }

    private func request(method: String, key: String?, query: [(String, String)] = [],
                         headers: [String: String] = [:], payloadHash: String = S3SignatureV4.emptyPayloadHash) throws -> URLRequest {
        if let key {
            guard !key.isEmpty, key.utf8.count <= 1024, !key.utf8.contains(0),
                  !key.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
                // URL loading systems can normalize dot-only path segments before sending them.
                throw CloudFailure(.invalidKey)
            }
        }
        var components = URLComponents()
        components.scheme = "https"; components.host = host
        components.percentEncodedPath = bucketPath + "/" + S3SignatureV4.encode(key ?? "", preservingSlashes: true)
        if !query.isEmpty { components.percentEncodedQuery = S3SignatureV4.canonicalQuery(query) }
        guard let url = components.url else { throw CloudFailure(.invalidConfiguration) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try S3SignatureV4.sign(request, accessKeyID: credentials.accessKeyID!, secretAccessKey: credentials.secretAccessKey!,
                                      sessionToken: credentials.sessionToken, region: region, date: now(), payloadHash: payloadHash)
    }

    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }
}

private final class S3ListParser: NSObject, XMLParserDelegate {
    var root: String?
    var truncated: Bool?
    var nextToken: String?
    var encoding: String?
    var objects: [[String: String]] = []
    var prefixes: [String] = []
    var invalid = false
    private var path: [String] = []
    private var contents: [String: String] = [:]
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if root == nil { root = elementName }
        path.append(elementName); text = ""
        if path.count > 16 { invalid = true; parser.abortParsing() }
        if path == ["ListBucketResult", "Contents"] { contents = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
        if text.utf8.count > 64 * 1024 { invalid = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if path.count == 3 && path[1] == "Contents" { contents[elementName] = text }
        if path == ["ListBucketResult", "Contents"] {
            objects.append(contents)
            if objects.count > 1000 { invalid = true; parser.abortParsing() }
        } else if path == ["ListBucketResult", "CommonPrefixes", "Prefix"] {
            prefixes.append(text)
            if prefixes.count > 1000 { invalid = true; parser.abortParsing() }
        } else if path == ["ListBucketResult", "IsTruncated"] {
            if text == "true" { truncated = true } else if text == "false" { truncated = false } else { invalid = true }
        } else if path == ["ListBucketResult", "NextContinuationToken"] { nextToken = text }
        else if path == ["ListBucketResult", "EncodingType"] { encoding = text }
        path.removeLast(); text = ""
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        invalid = true; parser.abortParsing(); return nil
    }
}
