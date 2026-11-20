// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Google Cloud Storage JSON API using a short-lived OAuth access token.
/// https://cloud.google.com/storage/docs/json_api/v1/objects/list
/// https://cloud.google.com/storage/docs/json_api/v1/objects/insert
struct GCSCloudBackend: CloudProviderBackend {
    private let bucket: String
    private let accessToken: String

    init(connection: CloudConnection, credentials: CloudCredentials) throws {
        guard !connection.bucket.isEmpty, connection.bucket.utf8.count <= 222,
              connection.bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              let token = credentials.accessToken, !token.isEmpty,
              token.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
            throw CloudFailure(.invalidConfiguration)
        }
        bucket = connection.bucket; accessToken = token
    }

    func listRequest(prefix: String, continuationToken: String?, pageSize: Int = 1000) throws -> URLRequest {
        guard (1...1000).contains(pageSize) else { throw CloudFailure(.invalidConfiguration) }
        var query = [("delimiter", "/"), ("prefix", prefix), ("maxResults", String(pageSize)), ("includeFoldersAsPrefixes", "true")]
        if let continuationToken, !continuationToken.isEmpty { query.append(("pageToken", continuationToken)) }
        return try request(path: collectionPath, query: query)
    }

    func parseList(_ response: CloudResponse) throws -> CloudPage {
        let json = try objectJSON(response.body)
        guard json["kind"] as? String == "storage#objects" else { throw CloudFailure(.malformedResponse) }
        let prefixes: [String]
        if let raw = json["prefixes"] {
            guard let strings = raw as? [String], strings.allSatisfy({ !$0.isEmpty && $0.hasSuffix("/") }) else {
                throw CloudFailure(.malformedResponse)
            }
            prefixes = strings
        } else { prefixes = [] }
        let items: [[String: Any]]
        if let raw = json["items"] {
            guard let dictionaries = raw as? [[String: Any]] else { throw CloudFailure(.malformedResponse) }
            items = dictionaries
        } else { items = [] }
        guard items.count + prefixes.count <= 1000 else { throw CloudFailure(.malformedResponse) }
        var objects = prefixes.map { CloudObject(key: $0, size: nil, modified: nil, isDirectory: true, version: nil) }
        for item in items {
            let object = try parseObject(item)
            // A directory marker may appear both as a prefix and as an object.
            if !object.isDirectory || !prefixes.contains(object.key) { objects.append(object) }
        }
        let nextToken: String?
        if let raw = json["nextPageToken"] {
            guard let string = raw as? String else { throw CloudFailure(.malformedResponse) }
            nextToken = string.isEmpty ? nil : string
        } else { nextToken = nil }
        return CloudPage(objects: objects, nextToken: nextToken)
    }

    func statRequest(key: String) throws -> URLRequest { try request(path: objectPath(key)) }

    func parseStat(_ response: CloudResponse, key: String) throws -> CloudObject {
        let object = try parseObject(objectJSON(response.body))
        guard object.key == key else { throw CloudFailure(.malformedResponse) }
        return object
    }

    func uploadRequest(key: String, condition: CloudWriteCondition, integrity: CloudUploadIntegrity? = nil) throws -> URLRequest {
        guard !key.isEmpty, !key.utf8.contains(0) else { throw CloudFailure(.invalidConfiguration) }
        let generation: String
        switch condition {
        case .absent: generation = "0"
        case .matches(let version):
            guard Self.validGeneration(version) else { throw CloudFailure(.invalidConfiguration) }
            generation = version
        }
        var result = try request(path: "/upload" + collectionPath,
                                 query: [("uploadType", "media"), ("name", key), ("ifGenerationMatch", generation)])
        result.httpMethod = "POST"
        result.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return result
    }

    func parseUpload(_ response: CloudResponse, key: String, size: Int64) throws -> CloudObject {
        let object = try parseStat(response, key: key)
        guard object.size == size else { throw CloudFailure(.malformedResponse) }
        return object
    }

    // https://cloud.google.com/storage/docs/json_api/v1/objects/delete
    func deleteRequest(key: String, matchingVersion version: String) throws -> URLRequest {
        guard Self.validGeneration(version) else { throw CloudFailure(.invalidConfiguration) }
        var value = try request(path: objectPath(key), query: [("ifGenerationMatch", version)])
        value.httpMethod = "DELETE"
        return value
    }

    func downloadRequest(key: String, matchingVersion version: String? = nil) throws -> URLRequest {
        var query = [("alt", "media")]
        if let version {
            guard Self.validGeneration(version) else { throw CloudFailure(.invalidConfiguration) }
            query.append(("ifGenerationMatch", version))
        }
        return try request(path: objectPath(key), query: query)
    }

    private var collectionPath: String { "/storage/v1/b/" + Self.encode(bucket) + "/o" }
    private func objectPath(_ key: String) throws -> String {
        guard !key.isEmpty, !key.utf8.contains(0) else { throw CloudFailure(.invalidConfiguration) }
        return collectionPath + "/" + Self.encode(key)
    }
    private func request(path: String, query: [(String, String)] = []) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"; components.host = "storage.googleapis.com"
        components.percentEncodedPath = path
        if !query.isEmpty { components.percentEncodedQuery = query.map { Self.encode($0.0) + "=" + Self.encode($0.1) }.joined(separator: "&") }
        guard let url = components.url else { throw CloudFailure(.invalidConfiguration) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private static func encode(_ value: String) -> String {
        if value == "." || value == ".." { return String(repeating: "%2E", count: value.count) }
        return value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    private func objectJSON(_ data: Data) throws -> [String: Any] {
        guard data.count <= 16 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudFailure(.malformedResponse) }
        return value
    }
    private static func validGeneration(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && UInt64(value).map { $0 > 0 } == true
    }
    private func parseObject(_ json: [String: Any]) throws -> CloudObject {
        guard let key = json["name"] as? String, !key.isEmpty,
              let rawSize = json["size"] as? String, let size = Int64(rawSize), size >= 0,
              let generation = json["generation"] as? String, Self.validGeneration(generation) else {
            throw CloudFailure(.malformedResponse)
        }
        var modified: Date?
        if let updated = json["updated"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            modified = formatter.date(from: updated)
            if modified == nil { formatter.formatOptions = [.withInternetDateTime]; modified = formatter.date(from: updated) }
            guard modified != nil else { throw CloudFailure(.malformedResponse) }
        }
        return CloudObject(key: key, size: size, modified: modified, isDirectory: key.hasSuffix("/"), version: generation)
    }
}
