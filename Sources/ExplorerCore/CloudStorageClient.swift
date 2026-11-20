// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CryptoKit

public struct CloudStorageClient: Sendable {
    public let connection: CloudConnection
    private let backend: any CloudProviderBackend
    private let transport: any CloudTransport
    /// One-request uploads only in this version; multipart/resumable uploads are a later stage.
    public static let maximumUploadBytes: Int64 = 5_000_000_000

    public init(connection: CloudConnection, credentials: CloudCredentials,
                transport: any CloudTransport = URLSessionCloudTransport()) throws {
        self.connection = connection; self.transport = transport
        switch connection.provider {
        case .s3: backend = try S3CloudBackend(connection: connection, credentials: credentials)
        case .azure: backend = try AzureCloudBackend(connection: connection, credentials: credentials)
        case .gcs: backend = try GCSCloudBackend(connection: connection, credentials: credentials)
        }
    }

    public func list(prefix: String = "", continuationToken: String? = nil, pageSize: Int = 1000) async throws -> CloudPage {
        try Self.checkCancellation()
        try Self.validateKey(prefix, allowEmpty: true)
        guard (1...1000).contains(pageSize) else { throw CloudFailure(.invalidConfiguration) }
        let request = try backend.listRequest(prefix: prefix, continuationToken: continuationToken, pageSize: pageSize)
        try Self.validate(request)
        let response = try await requestResult { try await transport.send(request) }
        try checkStatus(response)
        let page = try backend.parseList(response)
        guard page.nextToken == nil || page.nextToken != continuationToken else { throw CloudFailure(.malformedResponse) }
        return page
    }

    public func stat(key: String) async throws -> CloudObject? {
        try Self.checkCancellation()
        try Self.validateKey(key)
        let request = try backend.statRequest(key: key)
        try Self.validate(request)
        let response = try await requestResult { try await transport.send(request) }
        if response.statusCode == 404 { return nil }
        try checkStatus(response)
        return try backend.parseStat(response, key: key)
    }

    /// Deletes only the current object with an observed version. Never targets recovery snapshots or historical versions.
    /// Transport errors after dispatch are indeterminate; callers must not automatically retry them.
    public func delete(key: String, matchingVersion: String) async throws -> CloudDeletionOutcome {
        try Self.checkCancellation()
        try Self.validateKey(key)
        let request = try backend.deleteRequest(key: key, matchingVersion: matchingVersion)
        try Self.validate(request)
        try Self.checkCancellation()
        let response: CloudResponse
        do { response = try await transport.send(request) }
        catch { return .indeterminate }
        // A confirmed response remains authoritative even when cancellation arrived after dispatch.
        switch response.statusCode {
        case 202, 204: return .acknowledged
        case 404: return .absent
        case 412: return .changed
        case 500...599: return .indeterminate
        default:
            try checkStatus(response)
            return .indeterminate
        }
    }

    public func upload(fileURL: URL, key: String, condition: CloudWriteCondition = .absent,
                       progress: CloudProgressHandler? = nil) async throws -> CloudObject {
        try Self.checkCancellation()
        try Self.validateKey(key)
        if case .matches(let version) = condition, version.isEmpty || version.contains("\r") || version.contains("\n") {
            throw CloudFailure(.invalidConfiguration)
        }
        let worker = Task.detached(priority: .userInitiated) {
            try CloudUploadSnapshot.make(source: fileURL, maximumBytes: Self.maximumUploadBytes)
        }
        let snapshot = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        defer { snapshot.remove() }
        try Self.checkCancellation()
        let size = snapshot.integrity.size
        var request = try backend.uploadRequest(key: key, condition: condition, integrity: snapshot.integrity)
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        try Self.validate(request)
        progress?(CloudTransferProgress(completedBytes: 0, totalBytes: size))
        // A server-confirmed PUT is authoritative even if cancellation arrived after dispatch.
        // Return its original receipt so callers can account for a publication without a later HEAD.
        let response = try await requestResult(checkCancellationAfterResponse: false) {
            try await transport.upload(request, fileURL: snapshot.payload, progress: progress)
        }
        try checkStatus(response)
        let object = try backend.parseUpload(response, key: key, size: size)
        progress?(CloudTransferProgress(completedBytes: size, totalBytes: size))
        return object
    }

    public func download(key: String, to destination: URL, matchingVersion: String? = nil, progress: CloudProgressHandler? = nil) async throws -> URL {
        try Self.checkCancellation()
        try Self.validateKey(key)
        var request = try backend.downloadRequest(key: key, matchingVersion: matchingVersion)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try Self.validate(request)
        let staging = try await Task.detached(priority: .userInitiated) { try Self.prepareDownload(destination) }.value
        defer { try? FileManager.default.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload")
        progress?(CloudTransferProgress(completedBytes: 0, totalBytes: nil))
        let response = try await requestResult { try await transport.download(request, to: payload, progress: progress) }
        try checkStatus(response)
        guard response.statusCode == 200 else { throw CloudFailure(.malformedResponse, detail: "Unexpected partial download") }
        // URLSession may transparently decode Content-Encoding. Refuse instead of silently changing object bytes.
        if let encoding = response.header("Content-Encoding"), !encoding.isEmpty, encoding.lowercased() != "identity" {
            throw CloudFailure(.malformedResponse, detail: "Encoded object responses are not supported")
        }
        if let matchingVersion {
            let actual = response.header(connection.provider == .gcs ? "x-goog-generation" : "ETag")
            guard actual == matchingVersion else { throw CloudFailure(.preconditionFailed, detail: "Downloaded object changed") }
        }
        let verifyWorker = Task.detached(priority: .userInitiated) {
            try CloudUploadSnapshot.verifyDownload(payload, response: response, provider: connection.provider)
        }
        let size = try await withTaskCancellationHandler { try await verifyWorker.value } onCancel: { verifyWorker.cancel() }
        try Self.checkCancellation()
        guard renamex_np(payload.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw CloudFailure(errno == EEXIST || errno == ENOTEMPTY ? .localConflict : .io)
        }
        progress?(CloudTransferProgress(completedBytes: size, totalBytes: size))
        return destination
    }

    private func requestResult(checkCancellationAfterResponse: Bool = true,
                               _ operation: () async throws -> CloudResponse) async throws -> CloudResponse {
        try Self.checkCancellation()
        do {
            let result = try await operation()
            if checkCancellationAfterResponse { try Self.checkCancellation() }
            return result
        } catch let failure as CloudFailure { throw failure }
        catch is CancellationError { throw CloudFailure(.cancelled) }
        catch {
            let code = (error as NSError).code
            throw CloudFailure(Task.isCancelled || code == NSURLErrorCancelled ? .cancelled : .io,
                               detail: "Transport failed")
        }
    }

    private static func validateKey(_ key: String, allowEmpty: Bool = false) throws {
        guard (allowEmpty || !key.isEmpty), !key.utf8.contains(0), key.utf8.count <= 1024 else { throw CloudFailure(.invalidKey) }
    }
    private static func validate(_ request: URLRequest) throws {
        guard CloudRedirectPolicy.secure(request.url) else { throw CloudFailure(.insecureTransport) }
    }
    private static func checkCancellation() throws {
        if Task.isCancelled { throw CloudFailure(.cancelled) }
    }
    private func checkStatus(_ response: CloudResponse) throws {
        if connection.provider == .s3, let reason = S3ErrorResponse.reason(for: response) {
            throw CloudFailure(reason)
        }
        switch response.statusCode {
        case 200..<300: return
        case 401: throw CloudFailure(.authenticationRequired)
        case 403: throw CloudFailure(.permissionDenied)
        case 404: throw CloudFailure(.notFound)
        case 409: throw CloudFailure(.conflict)
        case 412: throw CloudFailure(.preconditionFailed)
        case 429: throw CloudFailure(.rateLimited)
        case 500...599: throw CloudFailure(.serviceUnavailable)
        case 300...399: throw CloudFailure(.insecureTransport)
        default: throw CloudFailure(.io, detail: "HTTP \(response.statusCode)")
        }
    }
    private static func prepareDownload(_ destination: URL) throws -> URL {
        try CloudUploadSnapshot.validateLocalURL(destination)
        guard destination.path != "/" else { throw CloudFailure(.io) }
        var info = Darwin.stat()
        if lstat(destination.path, &info) == 0 { throw CloudFailure(.localConflict) }
        guard errno == ENOENT else { throw CloudFailure(.io) }
        let parent = destination.deletingLastPathComponent()
        guard fstatat(AT_FDCWD, parent.path, &info, 0) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CloudFailure(.io) }
        let directory = parent.appendingPathComponent(".my-explorer-cloud-\(UUID().uuidString)")
        guard mkdir(directory.path, 0o700) == 0 else { throw CloudFailure(.io) }
        return directory
    }
}

/// A bounded-memory, private copy. The original path is never handed to URLSession.
internal struct CloudUploadSnapshot: Sendable {
    let directory: URL
    let payload: URL
    let integrity: CloudUploadIntegrity
    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == nil || components.host == "" || components.host == "localhost",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              !decodedPath.utf8.contains(0) else { throw CloudFailure(.io) }
    }

    static func make(source: URL, maximumBytes: Int64,
                     stagingParent: URL = FileManager.default.temporaryDirectory,
                     afterChunk: (@Sendable (Int64) throws -> Void)? = nil) throws -> Self {
        try checkCancellation()
        try validateLocalURL(source)
        try LocalTransferRecovery.assertExportable(source)
        var original = Darwin.stat()
        guard lstat(source.path, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_size >= 0 else { throw CloudFailure(.io, detail: "Upload source must be a readable regular file") }
        guard original.st_size <= maximumBytes else { throw CloudFailure(.limitExceeded) }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw CloudFailure(.io) }
        defer { close(input) }
        var opened = Darwin.stat()
        guard fstat(input, &opened) == 0, unchanged(original, opened) else { throw CloudFailure(.localConflict) }
        let directory = stagingParent.appendingPathComponent(".my-explorer-upload-\(UUID().uuidString)")
        guard mkdir(directory.path, 0o700) == 0 else { throw CloudFailure(.io) }
        let payload = directory.appendingPathComponent("payload")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let output = open(payload.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw CloudFailure(.io) }
        defer { close(output) }
        var hash = SHA256(), count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try checkCancellation()
            let amount = read(input, &buffer, buffer.count)
            if amount < 0 { if errno == EINTR { continue }; throw CloudFailure(.io) }
            if amount == 0 { break }
            count += Int64(amount)
            guard count <= original.st_size, count <= maximumBytes else { throw CloudFailure(.localConflict) }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < amount {
                    try checkCancellation()
                    let written = write(output, bytes.baseAddress!.advanced(by: offset), amount - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw CloudFailure(.io) }
                    offset += written
                }
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: amount))
            }
            try afterChunk?(count)
        }
        var finalFD = Darwin.stat(), finalPath = Darwin.stat()
        guard count == original.st_size, fstat(input, &finalFD) == 0, lstat(source.path, &finalPath) == 0,
              unchanged(original, finalFD), unchanged(original, finalPath) else { throw CloudFailure(.localConflict) }
        try LocalTransferRecovery.assertExportable(source)
        try checkCancellation()
        guard fsync(output) == 0 else { throw CloudFailure(.io) }
        let digest = Data(hash.finalize())
        succeeded = true
        return Self(directory: directory, payload: payload,
                    integrity: CloudUploadIntegrity(size: count, sha256Hex: digest.map { String(format: "%02x", $0) }.joined(),
                                                    sha256Base64: digest.base64EncodedString()))
    }

    static func verifyDownload(_ payload: URL, response: CloudResponse, provider: CloudProvider) throws -> Int64 {
        try checkCancellation()
        let descriptor = open(payload.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CloudFailure(.io) }
        defer { close(descriptor) }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw CloudFailure(.io) }
        if let length = response.header("Content-Length") {
            guard let expected = Int64(length), expected == info.st_size else { throw CloudFailure(.malformedResponse, detail: "Incomplete download") }
        }
        // Composite multipart SHA256 values are not hashes of the complete object bytes.
        if provider == .s3, let expected = response.header("x-amz-checksum-sha256"),
           response.header("x-amz-checksum-type") != "COMPOSITE" {
            guard Data(base64Encoded: expected)?.count == 32 else { throw CloudFailure(.malformedResponse) }
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try checkCancellation()
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw CloudFailure(.io) }
                if count == 0 { break }
                buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: count)) }
            }
            guard Data(hash.finalize()).base64EncodedString() == expected else {
                throw CloudFailure(.malformedResponse, detail: "Download checksum mismatch")
            }
        }
        var finalFD = Darwin.stat(), finalPath = Darwin.stat()
        guard fstat(descriptor, &finalFD) == 0, lstat(payload.path, &finalPath) == 0,
              unchanged(info, finalFD), unchanged(info, finalPath) else { throw CloudFailure(.localConflict) }
        return info.st_size
    }

    private static func unchanged(_ first: Darwin.stat, _ second: Darwin.stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode &&
        first.st_size == second.st_size && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
        first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
        first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    private static func checkCancellation() throws { if Task.isCancelled { throw CloudFailure(.cancelled) } }
}
