// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A private, session-scoped copy. Its lifetime follows the undo record, including retries.
final class S3DeletedItem: Sendable {
    private let directory: URL
    private let connection: CloudConnection
    private let metadata: S3ObjectMetadata
    let key: String
    private let factory: @Sendable (UUID) async throws -> CloudStorageClient
    private var payload: URL { directory.appendingPathComponent("payload") }
    private init(directory: URL, connection: CloudConnection, key: String, metadata: S3ObjectMetadata,
                 factory: @escaping @Sendable (UUID) async throws -> CloudStorageClient) {
        self.directory = directory
        self.connection = connection
        self.metadata = metadata
        self.key = key
        self.factory = factory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func capture(_ object: CloudObject, version: String, client: CloudStorageClient,
                        factory: @escaping @Sendable (UUID) async throws -> CloudStorageClient) async throws -> S3DeletedItem {
        guard let size = object.size, size >= 0, size <= CloudStorageClient.maximumUploadBytes else {
            throw StorageDeletionFailure(.limitExceeded)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("myexplorer-undo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        do {
            let payload = directory.appendingPathComponent("payload")
            let metadata = try await client.downloadS3Backup(key: object.key, to: payload, matchingVersion: version)
            let attrs = try FileManager.default.attributesOfItem(atPath: payload.path)
            guard (attrs[.size] as? NSNumber)?.int64Value == size else { throw StorageDeletionFailure(.changed) }
            return S3DeletedItem(directory: directory, connection: client.connection, key: object.key,
                                 metadata: metadata, factory: factory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func restore(resolveConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                 control: LocalTransferControl) async throws -> URL {
        let client = try await factory(connection.id)
        guard client.connection == connection else { throw LocalTransferFailure(.changed) }
        let marker = key.hasSuffix("/")
        let path = (marker ? String(key.dropLast()) : key) as NSString
        let ext = marker ? "" : path.pathExtension
        let stem = ext.isEmpty ? path as String : path.deletingPathExtension
        let original = RemoteLocation.url(connectionID: connection.id, key: key)
        for index in 1...1000 {
            try control.checkpoint()
            let candidate = index == 1 ? key : stem + " (\(index))" + (ext.isEmpty ? "" : "." + ext) + (marker ? "/" : "")
            do {
                if marker {
                    if try await client.stat(key: String(candidate.dropLast())) != nil { throw CloudFailure(.preconditionFailed) }
                } else if candidate.utf8.count < 1024 {
                    let children = try await client.list(prefix: candidate + "/", pageSize: 1)
                    if !children.objects.isEmpty || children.nextToken != nil { throw CloudFailure(.preconditionFailed) }
                }
                if try await client.stat(key: candidate) != nil { throw CloudFailure(.preconditionFailed) }
                _ = try await client.upload(fileURL: payload, key: candidate, condition: .absent, s3Metadata: metadata)
                return RemoteLocation.url(connectionID: connection.id, key: candidate)
            } catch let error as CloudFailure where error.reason == .preconditionFailed {
                if index == 1 {
                    guard await resolveConflict(StorageConflict(source: original, destination: original, isDirectory: marker)) == .keepBoth
                    else { throw LocalTransferFailure(.cancelled) }
                }
            }
        }
        throw LocalTransferFailure(.limitExceeded)
    }
}
