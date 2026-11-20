// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum CloudProvider: String, Codable, CaseIterable, Sendable { case s3, azure, gcs }

/// Connection metadata is safe to persist; credentials deliberately live in a separate, non-Codable type.
public struct CloudConnection: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var provider: CloudProvider
    public var bucket: String
    public var region: String?
    public var account: String?
    public init(id: UUID = UUID(), name: String, provider: CloudProvider, bucket: String,
                region: String? = nil, account: String? = nil) {
        self.id = id; self.name = name; self.provider = provider; self.bucket = bucket
        self.region = region; self.account = account
    }
}

public struct CloudCredentials: Sendable {
    public let accessKeyID: String?
    public let secretAccessKey: String?
    public let sessionToken: String?
    public let sasToken: String?
    public let accessToken: String?
    public init(accessKeyID: String? = nil, secretAccessKey: String? = nil, sessionToken: String? = nil,
                sasToken: String? = nil, accessToken: String? = nil) {
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey; self.sessionToken = sessionToken
        self.sasToken = sasToken; self.accessToken = accessToken
    }
}

public struct CloudObject: Equatable, Sendable {
    public let key: String
    public let size: Int64?
    public let modified: Date?
    public let isDirectory: Bool
    /// Opaque ETag (S3/Azure) or decimal generation (GCS); pass back unchanged for conditional writes.
    public let version: String?
    public init(key: String, size: Int64? = nil, modified: Date? = nil, isDirectory: Bool = false, version: String? = nil) {
        self.key = key; self.size = size; self.modified = modified; self.isDirectory = isDirectory; self.version = version
    }
}
public struct CloudPage: Equatable, Sendable {
    public let objects: [CloudObject]
    public let nextToken: String?
    public init(objects: [CloudObject], nextToken: String? = nil) { self.objects = objects; self.nextToken = nextToken }
}
public enum CloudWriteCondition: Equatable, Sendable { case absent, matches(String) }
public struct CloudTransferProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public init(completedBytes: Int64, totalBytes: Int64?) { self.completedBytes = completedBytes; self.totalBytes = totalBytes }
}
public typealias CloudProgressHandler = @Sendable (CloudTransferProgress) -> Void

public struct CloudFailure: Error, Sendable {
    public enum Reason: String, Codable, Sendable {
        case invalidConfiguration, invalidKey, authenticationRequired, permissionDenied, notFound
        case conflict, preconditionFailed, rateLimited, serviceUnavailable, malformedResponse
        case insecureTransport, cancelled, localConflict, limitExceeded, io
    }
    public let reason: Reason
    /// A safe diagnostic, never raw response bodies, credentials, or signed URLs.
    public let detail: String
    public init(_ reason: Reason, detail: String = "") { self.reason = reason; self.detail = detail }
}

public struct CloudResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode; self.headers = headers; self.body = body
    }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Injectable transport: metadata is bounded data, while uploads/downloads are file-backed.
public protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CloudResponse
    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse
    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse
}

protocol CloudProviderBackend: Sendable {
    func listRequest(prefix: String, continuationToken: String?, pageSize: Int) throws -> URLRequest
    func parseList(_ response: CloudResponse) throws -> CloudPage
    func statRequest(key: String) throws -> URLRequest
    func parseStat(_ response: CloudResponse, key: String) throws -> CloudObject
    func uploadRequest(key: String, condition: CloudWriteCondition, integrity: CloudUploadIntegrity?) throws -> URLRequest
    func parseUpload(_ response: CloudResponse, key: String, size: Int64) throws -> CloudObject
    func downloadRequest(key: String, matchingVersion: String?) throws -> URLRequest
    func deleteRequest(key: String, matchingVersion: String) throws -> URLRequest
}

/// Acknowledgement is the server response, not proof that an idempotent delete found an object.
public enum CloudDeletionOutcome: String, Codable, Sendable { case acknowledged, absent, changed, indeterminate }

/// Digest of the exact private file submitted to the transport.
internal struct CloudUploadIntegrity: Sendable {
    let size: Int64
    let sha256Hex: String
    let sha256Base64: String
}
