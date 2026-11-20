// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

public enum StorageConflictChoice: Sendable { case replace, keepBoth, skip, cancel }
public struct StorageConflict: Sendable {
    public let source: URL
    public let destination: URL
    public let isDirectory: Bool
    public init(source: URL, destination: URL, isDirectory: Bool) {
        self.source = source; self.destination = destination; self.isDirectory = isDirectory
    }
}
public struct StorageTransferProgress: Sendable {
    public let completedItems: Int
    public let totalItems: Int
    public let currentSource: URL?
    public let currentDestination: URL?
    public let bytesCompleted: Int64
    public let totalBytes: Int64?
}
public struct StorageTransferFailure: Error, Sendable {
    public enum Reason: String, Sendable {
        case invalidSource, invalidDestination, unsupportedDirection, unsafePath, unsupportedEntry
        case limitExceeded, conflictChanged, authorizationDenied, cancelled, io, cloud
    }
    public let reason: Reason
    public let completedCount: Int
    public let cloudReason: CloudFailure.Reason?
    public init(_ reason: Reason, completedCount: Int = 0, cloudReason: CloudFailure.Reason? = nil) {
        self.reason = reason; self.completedCount = completedCount; self.cloudReason = cloudReason
    }
}

/// Copies only local ↔ cloud. Successfully published items are never deleted as rollback.
public struct StorageTransferService: Sendable {
    public struct Limits: Sendable {
        public let entries: Int
        public let depth: Int
        public init(entries: Int = 10_000, depth: Int = 64) { self.entries = max(0, entries); self.depth = max(0, depth) }
    }
    private let clientFactory: @Sendable (UUID) async throws -> CloudStorageClient
    private let limits: Limits
    public init(clientFactory: @escaping @Sendable (UUID) async throws -> CloudStorageClient, limits: Limits = Limits()) {
        self.clientFactory = clientFactory; self.limits = limits
    }

    public func copy(sources: [URL], to destination: URL,
                     resolveConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                     progress: (@Sendable (StorageTransferProgress) -> Void)? = nil,
                     authorize: (@Sendable (_ source: URL, _ destination: URL, _ replacing: Bool) async throws -> Void)? = nil,
                     onUploadConfirmed: (@Sendable (_ destination: URL, _ object: CloudObject) async -> Void)? = nil) async throws -> [URL] {
        var completed = 0
        do {
            try storageCheckCancellation()
            guard !sources.isEmpty else { throw StorageTransferFailure(.invalidSource) }
            let remoteDestination = RemoteLocation.parse(destination)
            let uploading = remoteDestination != nil
            guard uploading ? sources.allSatisfy(\.isFileURL) : destination.isFileURL && sources.allSatisfy({ RemoteLocation.parse($0) != nil }) else {
                throw StorageTransferFailure(.unsupportedDirection)
            }
            var budget = 0
            var nodes: [StorageNode] = []
            var clients: [UUID: CloudStorageClient] = [:]
            let localBase: URL?
            if uploading {
                localBase = nil
                for source in sources {
                    let node = try await Self.offMain {
                        var count = 0
                        let node = try Self.localNode(source, root: source, depth: 1, count: &count, limits: limits)
                        return (node, count)
                    }
                    budget += node.1
                    guard budget <= limits.entries else { throw StorageTransferFailure(.limitExceeded) }
                    nodes.append(node.0)
                }
            } else {
                localBase = try Self.checkedBase(destination)
                for source in sources {
                    guard let location = RemoteLocation.parse(source) else { throw StorageTransferFailure(.invalidSource) }
                    let client: CloudStorageClient
                    if let cached = clients[location.connectionID] { client = cached }
                    else { client = try await clientFactory(location.connectionID); clients[location.connectionID] = client }
                    nodes.append(try await remoteNode(location.key, connectionID: location.connectionID, client: client, depth: 1, count: &budget))
                }
            }
            let remoteClient: CloudStorageClient?
            let prefix: String
            if let remoteDestination {
                remoteClient = try await clientFactory(remoteDestination.connectionID)
                prefix = try Self.checkedPrefix(remoteDestination.key)
            } else { remoteClient = nil; prefix = "" }
            let context = TransferContext(total: budget, progress: progress, resolver: resolveConflict, authorizer: authorize, onUploadConfirmed: onUploadConfirmed)
            var results: [URL] = []
            do {
                for node in nodes {
                    try storageCheckCancellation()
                    if let remoteDestination, let remoteClient {
                        if let result = try await upload(node, prefix: prefix, client: remoteClient, connectionID: remoteDestination.connectionID, context: context) { results.append(result) }
                    } else if let localBase, let sourceRemote = RemoteLocation.parse(node.source), let client = clients[sourceRemote.connectionID] {
                        if let result = try await download(node, parent: localBase, base: localBase, client: client, context: context) { results.append(result) }
                    }
                }
            } catch {
                completed = context.published
                throw error
            }
            return results
        } catch let failure as StorageTransferFailure {
            throw StorageTransferFailure(failure.reason, completedCount: completed + failure.completedCount, cloudReason: failure.cloudReason)
        } catch let failure as CloudFailure {
            let reason: StorageTransferFailure.Reason = failure.reason == .cancelled ? .cancelled :
                [.conflict, .preconditionFailed].contains(failure.reason) ? .conflictChanged : .cloud
            throw StorageTransferFailure(reason, completedCount: completed, cloudReason: failure.reason)
        } catch is CancellationError { throw StorageTransferFailure(.cancelled, completedCount: completed) }
        catch { throw StorageTransferFailure(.io, completedCount: completed) }
    }

    private static func component(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains(":"), !name.utf8.contains(0) else { throw StorageTransferFailure(.unsafePath) }
    }
    private static func checkedPrefix(_ key: String) throws -> String {
        if key.isEmpty { return "" }
        let raw = key.hasSuffix("/") ? String(key.dropLast()) : key
        for part in raw.split(separator: "/", omittingEmptySubsequences: false) { try component(String(part)) }
        return raw + "/"
    }
    private static func localNode(_ source: URL, root: URL, depth: Int, count: inout Int, limits: Limits) throws -> StorageNode {
        try storageCheckCancellation()
        guard !LocalTransferRecovery.isProtected(source) else { throw StorageTransferFailure(.unsupportedEntry) }
        guard depth <= limits.depth else { throw StorageTransferFailure(.limitExceeded) }
        count += 1
        guard count <= limits.entries else { throw StorageTransferFailure(.limitExceeded) }
        try component(source.lastPathComponent)
        guard let metadata = try fileIdentity(source) else { throw StorageTransferFailure(.invalidSource) }
        guard metadata.type == S_IFREG || metadata.type == S_IFDIR else { throw StorageTransferFailure(.unsupportedEntry) }
        if metadata.type == S_IFDIR {
            let fd = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw StorageTransferFailure(.unsupportedEntry) }
            guard let directory = fdopendir(fd) else { close(fd); throw StorageTransferFailure(.io) }
            defer { closedir(directory) }
            var children: [URL] = []
            errno = 0
            while let record = readdir(directory) {
                try storageCheckCancellation()
                let name = withUnsafePointer(to: &record.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
                }
                guard let name else { throw StorageTransferFailure(.unsupportedEntry) }
                if name != ".", name != ".." { children.append(source.appendingPathComponent(name)) }
                guard children.count + count <= limits.entries else { throw StorageTransferFailure(.limitExceeded) }
                errno = 0
            }
            guard errno == 0 else { throw StorageTransferFailure(.io) }
            var nodes: [StorageNode] = []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try checkParents(source, base: root)
                nodes.append(try localNode(child, root: root, depth: depth + 1, count: &count, limits: limits))
            }
            return StorageNode(source: source, name: source.lastPathComponent, directory: true, size: nil, children: nodes, localRoot: root)
        }
        return StorageNode(source: source, name: source.lastPathComponent, directory: false, size: metadata.size, children: [], localRoot: root)
    }

    private func remoteNode(_ rawKey: String, connectionID: UUID, client: CloudStorageClient,
                            depth: Int, count: inout Int) async throws -> StorageNode {
        try storageCheckCancellation()
        guard depth <= limits.depth else { throw StorageTransferFailure(.limitExceeded) }
        count += 1
        guard count <= limits.entries else { throw StorageTransferFailure(.limitExceeded) }
        let prefix = try Self.checkedPrefix(rawKey)
        let name = rawKey.isEmpty ? client.connection.bucket : String(prefix.dropLast()).split(separator: "/").last.map(String.init) ?? ""
        try Self.component(name)
        let metadata = rawKey.isEmpty ? nil : try await client.stat(key: rawKey)
        if let metadata, !metadata.isDirectory, !rawKey.hasSuffix("/") {
            return StorageNode(source: RemoteLocation.url(connectionID: connectionID, key: rawKey), name: name,
                               directory: false, size: metadata.size, children: [], remoteVersion: metadata.version)
        }
        var token: String?, tokens = Set<String>(), keys = Set<String>(), children: [CloudObject] = []
        var pages = 0
        repeat {
            try storageCheckCancellation()
            pages += 1
            guard pages <= limits.entries + 1 else { throw StorageTransferFailure(.limitExceeded) }
            let page = try await client.list(prefix: prefix, continuationToken: token)
            for object in page.objects {
                guard object.key.hasPrefix(prefix) else { throw StorageTransferFailure(.unsafePath) }
                if object.key == prefix { continue }
                let relative = String(object.key.dropFirst(prefix.count))
                let childName = object.isDirectory && relative.hasSuffix("/") ? String(relative.dropLast()) : relative
                try Self.component(childName)
                if keys.insert(object.key).inserted { children.append(object) }
                guard children.count + count <= limits.entries else { throw StorageTransferFailure(.limitExceeded) }
            }
            token = page.nextToken
            if let token, !tokens.insert(token).inserted { throw StorageTransferFailure(.limitExceeded) }
        } while token != nil
        guard rawKey.isEmpty || metadata != nil || !children.isEmpty else { throw StorageTransferFailure(.invalidSource) }
        var planned: [StorageNode] = []
        for child in children.sorted(by: { $0.key < $1.key }) {
            planned.append(try await remoteNode(child.key, connectionID: connectionID, client: client, depth: depth + 1, count: &count))
        }
        return StorageNode(source: RemoteLocation.url(connectionID: connectionID, key: prefix), name: name,
                           directory: true, size: nil, children: planned)
    }

    private func upload(_ node: StorageNode, prefix: String, client: CloudStorageClient, connectionID: UUID,
                        context: TransferContext) async throws -> URL? {
        try storageCheckCancellation()
        guard !LocalTransferRecovery.isProtected(node.source) else { throw StorageTransferFailure(.unsupportedEntry) }
        if let root = node.localRoot, root.path != node.source.path {
            try Self.checkParents(node.source.deletingLastPathComponent(), base: root)
        }
        guard let currentSource = try Self.fileIdentity(node.source), currentSource.type == (node.directory ? S_IFDIR : S_IFREG) else {
            throw StorageTransferFailure(.unsupportedEntry)
        }
        var name = node.name
        var key = prefix + name + (node.directory ? "/" : "")
        var existing = try await remoteExisting(key, directory: node.directory, client: client)
        if existing != nil {
            let target = RemoteLocation.url(connectionID: connectionID, key: key)
            let choice = await context.resolver(StorageConflict(source: node.source, destination: target, isDirectory: node.directory))
            try storageCheckCancellation()
            switch choice {
            case .cancel: throw StorageTransferFailure(.cancelled)
            case .skip: context.skip(node); return nil
            case .replace: break
            case .keepBoth:
                var found = false
                for index in 2...10_000 {
                    try storageCheckCancellation()
                    name = Self.alternative(node.name, index: index, directory: node.directory)
                    key = prefix + name + (node.directory ? "/" : "")
                    if try await remoteExisting(key, directory: node.directory, client: client) == nil { found = true; break }
                }
                guard found else { throw StorageTransferFailure(.limitExceeded) }
                existing = nil
            }
        }
        let destination = RemoteLocation.url(connectionID: connectionID, key: key)
        try await context.authorize(node.source, destination, replacing: existing != nil && !node.directory)
        guard !LocalTransferRecovery.isProtected(node.source) else { throw StorageTransferFailure(.unsupportedEntry) }
        if let root = node.localRoot, root.path != node.source.path {
            try Self.checkParents(node.source.deletingLastPathComponent(), base: root)
        }
        if node.directory {
            // Existing folders are merged; untouched objects are never removed.
            if existing == nil {
                let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.CloudMarker.\(UUID().uuidString)")
                guard mkdir(temporaryDirectory.path, 0o700) == 0 else { throw StorageTransferFailure(.io) }
                defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                let temporary = temporaryDirectory.appendingPathComponent("marker")
                let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { throw StorageTransferFailure(.io) }
                close(descriptor)
                try await context.authorize(node.source, destination, replacing: false)
                let object = try await client.upload(fileURL: temporary, key: key, condition: .absent)
                context.published += 1
                await context.onUploadConfirmed?(destination, object)
                try storageCheckCancellation()
            }
            context.finish(node, destination: destination)
            for child in node.children { _ = try await upload(child, prefix: key, client: client, connectionID: connectionID, context: context) }
        } else {
            guard let current = try Self.fileIdentity(node.source), current.type == S_IFREG else { throw StorageTransferFailure(.unsupportedEntry) }
            let condition: CloudWriteCondition
            if let existing {
                guard let version = existing.version else { throw StorageTransferFailure(.conflictChanged) }
                condition = .matches(version)
            } else { condition = .absent }
            let object = try await client.upload(fileURL: node.source, key: key, condition: condition,
                                                 progress: context.byteProgress(node, destination: destination))
            context.published += 1
            await context.onUploadConfirmed?(destination, object)
            try storageCheckCancellation()
            context.finish(node, destination: destination)
        }
        return destination
    }

    private func remoteExisting(_ key: String, directory: Bool, client: CloudStorageClient) async throws -> CloudObject? {
        if let object = try await client.stat(key: key) { return object }
        if directory {
            var token: String?, tokens = Set<String>()
            repeat {
                try storageCheckCancellation()
                let page = try await client.list(prefix: key, continuationToken: token)
                if !page.objects.isEmpty { return CloudObject(key: key, isDirectory: true) }
                token = page.nextToken
                if let token {
                    guard tokens.insert(token).inserted, tokens.count <= limits.entries else { throw StorageTransferFailure(.limitExceeded) }
                }
            } while token != nil
        }
        return nil
    }

    private func download(_ node: StorageNode, parent: URL, base: URL, client: CloudStorageClient,
                          context: TransferContext) async throws -> URL? {
        try storageCheckCancellation()
        try Self.checkParents(parent, base: base)
        var destination = parent.appendingPathComponent(node.name, isDirectory: node.directory)
        guard !LocalTransferRecovery.isProtected(destination) else { throw StorageTransferFailure(.unsafePath) }
        var existing = try Self.fileIdentity(destination)
        if let existing, existing.type != S_IFREG && existing.type != S_IFDIR { throw StorageTransferFailure(.unsafePath) }
        if existing != nil {
            let choice = await context.resolver(StorageConflict(source: node.source, destination: destination, isDirectory: node.directory))
            try storageCheckCancellation()
            switch choice {
            case .cancel: throw StorageTransferFailure(.cancelled)
            case .skip: context.skip(node); return nil
            case .replace: break
            case .keepBoth:
                var found = false
                for index in 2...10_000 {
                    destination = parent.appendingPathComponent(Self.alternative(node.name, index: index, directory: node.directory), isDirectory: node.directory)
                    if try Self.fileIdentity(destination) == nil { found = true; break }
                }
                guard found else { throw StorageTransferFailure(.limitExceeded) }
                existing = nil
            }
        }
        try await context.authorize(node.source, destination, replacing: existing != nil && !node.directory)
        try Self.checkParents(parent, base: base)
        guard !LocalTransferRecovery.isProtected(destination) else { throw StorageTransferFailure(.unsafePath) }
        if node.directory {
            if let existing {
                guard existing.type == S_IFDIR, try Self.fileIdentity(destination) == existing else { throw StorageTransferFailure(.conflictChanged) }
            } else {
                guard mkdir(destination.path, 0o700) == 0 else { throw StorageTransferFailure(errno == EEXIST ? .conflictChanged : .io) }
                context.published += 1
            }
            context.finish(node, destination: destination)
            for child in node.children { _ = try await download(child, parent: destination, base: base, client: client, context: context) }
        } else {
            guard existing == nil || existing?.type == S_IFREG,
                  let remote = RemoteLocation.parse(node.source) else { throw StorageTransferFailure(.conflictChanged) }
            let parentIdentity = try Self.fileIdentity(parent)
            let staging = parent.appendingPathComponent(".my-explorer-transfer-\(UUID().uuidString)")
            guard mkdir(staging.path, 0o700) == 0 else { throw StorageTransferFailure(.io) }
            defer { try? FileManager.default.removeItem(at: staging) }
            let payload = staging.appendingPathComponent("payload")
            guard let version = node.remoteVersion else { throw StorageTransferFailure(.conflictChanged) }
            _ = try await client.download(key: remote.key, to: payload, matchingVersion: version, progress: context.byteProgress(node, destination: destination))
            try storageCheckCancellation()
            try await context.authorize(node.source, destination, replacing: existing != nil)
            try Self.checkParents(parent, base: base)
            let currentParent = try Self.fileIdentity(parent)
            guard parentIdentity?.device == currentParent?.device, parentIdentity?.inode == currentParent?.inode else {
                throw StorageTransferFailure(.conflictChanged)
            }
            let finalDestination = destination, expectedIdentity = existing
            try await Self.offMain { try Self.publish(payload, to: finalDestination, replacing: expectedIdentity) }
            context.published += 1
            context.finish(node, destination: destination)
        }
        return destination
    }

    private static func alternative(_ name: String, index: Int, directory: Bool) -> String {
        if !directory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[..<dot]) + " (\(index))" + String(name[dot...])
        }
        return name + " (\(index))"
    }
    private static func checkedBase(_ url: URL) throws -> URL {
        guard !LocalTransferRecovery.isProtected(url) else { throw StorageTransferFailure(.unsafePath) }
        for part in url.pathComponents where part != "/" { try component(part) }
        guard url.isFileURL, let info = try fileIdentity(url), info.type == S_IFDIR else { throw StorageTransferFailure(.invalidDestination) }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
    private static func checkParents(_ directory: URL, base: URL) throws {
        guard !LocalTransferRecovery.isProtected(directory) else { throw StorageTransferFailure(.unsafePath) }
        guard directory.path == base.path || directory.path.hasPrefix(base.path + "/") else { throw StorageTransferFailure(.unsafePath) }
        let relative = directory.path == base.path ? "" : String(directory.path.dropFirst(base.path.count + 1))
        var current = base
        guard try fileIdentity(base)?.type == S_IFDIR else { throw StorageTransferFailure(.unsafePath) }
        for part in relative.split(separator: "/", omittingEmptySubsequences: true) {
            try component(String(part)); current.appendPathComponent(String(part))
            guard try fileIdentity(current)?.type == S_IFDIR else { throw StorageTransferFailure(.unsafePath) }
        }
    }
    private static func fileIdentity(_ url: URL) throws -> StorageFileIdentity? {
        var info = Darwin.stat()
        if lstat(url.path, &info) == 0 { return StorageFileIdentity(info) }
        if errno == ENOENT { return nil }
        throw StorageTransferFailure(.io)
    }
    private static func publish(_ staged: URL, to destination: URL, replacing expected: StorageFileIdentity?) throws {
        guard !LocalTransferRecovery.isProtected(destination) else { throw StorageTransferFailure(.unsafePath) }
        var coordinationError: NSError?
        var result: Result<Void, any Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                try storageCheckCancellation()
                let current = try fileIdentity(coordinated)
                guard current == expected else { throw StorageTransferFailure(.conflictChanged) }
                let flags: UInt32 = expected == nil ? UInt32(RENAME_EXCL) : 0
                guard renamex_np(staged.path, coordinated.path, flags) == 0 else {
                    throw StorageTransferFailure(errno == EEXIST || errno == ENOTEMPTY ? .conflictChanged : .io)
                }
            } catch { result = .failure(error) }
        }
        if coordinationError != nil { throw StorageTransferFailure(.io) }
        try result.get()
    }
    private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try storageCheckCancellation()
        let worker = Task.detached(priority: .userInitiated) { try storageCheckCancellation(); return try body() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

private struct StorageFileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let type: UInt16
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: Darwin.stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size; type = value.st_mode & S_IFMT
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}
private struct StorageNode: Sendable {
    let source: URL
    let name: String
    let directory: Bool
    let size: Int64?
    let children: [StorageNode]
    var localRoot: URL? = nil
    var remoteVersion: String? = nil
    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}
private final class TransferContext {
    let total: Int
    let progress: (@Sendable (StorageTransferProgress) -> Void)?
    let resolver: @Sendable (StorageConflict) async -> StorageConflictChoice
    let authorizer: (@Sendable (URL, URL, Bool) async throws -> Void)?
    let onUploadConfirmed: (@Sendable (URL, CloudObject) async -> Void)?
    var published = 0
    var processed = 0
    init(total: Int, progress: (@Sendable (StorageTransferProgress) -> Void)?, resolver: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
         authorizer: (@Sendable (URL, URL, Bool) async throws -> Void)?,
         onUploadConfirmed: (@Sendable (URL, CloudObject) async -> Void)?) {
        self.total = total; self.progress = progress; self.resolver = resolver; self.authorizer = authorizer
        self.onUploadConfirmed = onUploadConfirmed
    }
    func authorize(_ source: URL, _ destination: URL, replacing: Bool) async throws {
        try storageCheckCancellation()
        do { try await authorizer?(source, destination, replacing) }
        catch is CancellationError { throw StorageTransferFailure(.cancelled) }
        catch { throw StorageTransferFailure(.authorizationDenied) }
        try storageCheckCancellation()
    }
    func byteProgress(_ node: StorageNode, destination: URL) -> CloudProgressHandler {
        let done = processed, total = total, progress = progress
        return { value in
            progress?(StorageTransferProgress(completedItems: done, totalItems: total, currentSource: node.source,
                                              currentDestination: destination, bytesCompleted: value.completedBytes, totalBytes: value.totalBytes))
        }
    }
    func finish(_ node: StorageNode, destination: URL) {
        processed += 1
        progress?(StorageTransferProgress(completedItems: processed, totalItems: total, currentSource: node.source,
                                          currentDestination: destination, bytesCompleted: node.size ?? 0, totalBytes: node.size))
    }
    func skip(_ node: StorageNode) {
        processed += node.count
        progress?(StorageTransferProgress(completedItems: processed, totalItems: total, currentSource: node.source,
                                          currentDestination: nil, bytesCompleted: 0, totalBytes: node.size))
    }
}
private func storageCheckCancellation() throws {
    if Task.isCancelled { throw StorageTransferFailure(.cancelled) }
}
