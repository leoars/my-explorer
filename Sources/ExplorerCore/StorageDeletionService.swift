// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

public struct StorageDeletionPlan: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let expiresAt: Date
    public let sources: [URL]
    public let itemCount: Int
    public let recursive: Bool
}
public struct StorageDeletionResult: Codable, Sendable {
    /// A local directory counts as one Trash operation; cloud entries count individually.
    public let completed: [URL]
}
public struct StorageDeletionFailure: Error, Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case invalidPlan, expiredPlan, reusedPlan, recursiveRequired, unsafePath, unsupportedEntry
        case limitExceeded, notFound, changed, cancelled, notAuthorized, io, cloud, indeterminate
    }
    public let reason: Reason
    public let completed: [URL]
    public let indeterminate: [URL]
    public let cloudReason: CloudFailure.Reason?
    public init(_ reason: Reason, completed: [URL] = [], indeterminate: [URL] = [], cloudReason: CloudFailure.Reason? = nil) {
        self.reason = reason; self.completed = completed; self.indeterminate = indeterminate; self.cloudReason = cloudReason
    }
}
public protocol StorageTrash: Sendable {
    func trash(_ url: URL) async throws
    func trashReturningURL(_ url: URL) async throws -> URL?
}
public extension StorageTrash {
    func trashReturningURL(_ url: URL) async throws -> URL? {
        try await trash(url)
        return nil
    }
}
public struct SystemStorageTrash: StorageTrash {
    public init() {}
    public func trash(_ url: URL) async throws {
        _ = try await trashReturningURL(url)
    }
    public func trashReturningURL(_ url: URL) async throws -> URL? {
        // Foundation is the only deletion mechanism. No permanent-delete fallback.
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            do { try LocalTransferRecovery.assertExportable(url) }
            catch { throw StorageDeletionFailure(Task.isCancelled ? .cancelled : .unsupportedEntry) }
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

/// Plans are process-local capabilities. The decoded preview cannot supply or replace a snapshot.
/// Filesystem snapshots reduce races but cannot make Foundation Trash atomic against noncooperating writers.
public actor StorageDeletionService {
    public struct Limits: Sendable {
        public let entries: Int
        public let depth: Int
        public init(entries: Int = 10_000, depth: Int = 64) { self.entries = entries; self.depth = depth }
    }
    private let clientFactory: @Sendable (UUID) async throws -> CloudStorageClient
    private let trashLibrary: TrashLibrary?
    private let trash: any StorageTrash
    private let clock: @Sendable () -> Date
    private let limits: Limits
    private let lifetime: TimeInterval
    private var plans: [UUID: DeletionStoredPlan] = [:]
    private var consumed: [UUID: Date] = [:]
    private var revoked: Set<UUID> = []
    private var running: Set<UUID> = []

    public init(clientFactory: @escaping @Sendable (UUID) async throws -> CloudStorageClient,
                trash: any StorageTrash = SystemStorageTrash(), clock: @escaping @Sendable () -> Date = { Date() },
                limits: Limits = .init(), planLifetime: TimeInterval = 300, trashLibrary: TrashLibrary? = nil) {
        self.trashLibrary = trashLibrary
        self.clientFactory = clientFactory; self.trash = trash; self.clock = clock
        self.limits = limits; lifetime = planLifetime
    }
    public func discard(planID: UUID) {
        plans.removeValue(forKey: planID)
        if running.contains(planID) { revoked.insert(planID) }
    }
    private func prune() {
        let now = clock()
        plans = plans.filter { $0.value.preview.expiresAt > now }
        consumed = consumed.filter { $0.value > now || running.contains($0.key) }
    }

    /// Optional additional restriction: exactly these remote objects and observed versions may be planned.
    /// Material folder markers count; virtual directories do not. Execution still revalidates and authorizes.
    public func plan(sources: [URL], recursive: Bool = false,
                     expectedRemoteVersions: [URL: String]? = nil) async throws -> StorageDeletionPlan {
        do {
            try Self.cancel()
            guard !sources.isEmpty, limits.entries > 0, limits.depth >= 0, lifetime > 0 else { throw StorageDeletionFailure(.invalidPlan) }
            prune()
            guard plans.count < 128, consumed.count < 1024 else { throw StorageDeletionFailure(.limitExceeded) }
            var roots: [DeletionRoot] = []
            var count = 0
            for source in sources {
                try Self.cancel()
                let root: DeletionRoot
                if source.isFileURL {
                    let snapshot = try await Self.offMain { try DeletionLocalSnapshot.capture(source, limits: self.limits) }
                    if snapshot.directory && !recursive { throw StorageDeletionFailure(.recursiveRequired) }
                    root = .local(snapshot)
                } else if let remote = RemoteLocation.parse(source) {
                    try Self.key(remote.key)
                    if remote.key.hasSuffix("/") && !recursive { throw StorageDeletionFailure(.recursiveRequired) }
                    let client = try await clientFactory(remote.connectionID)
                    guard client.connection.id == remote.connectionID else { throw StorageDeletionFailure(.unsafePath) }
                    let objects = try await inventory(client: client, key: remote.key)
                    guard !objects.isEmpty else { throw StorageDeletionFailure(.notFound) }
                    root = .remote(source, client.connection, remote.key, objects)
                } else { throw StorageDeletionFailure(.unsafePath) }
                guard !roots.contains(where: { Self.overlap($0.url, root.url) }) else { throw StorageDeletionFailure(.unsafePath) }
                count += root.count
                guard count <= limits.entries else { throw StorageDeletionFailure(.limitExceeded) }
                roots.append(root)
            }
            try Self.cancel()
            if let expectedRemoteVersions {
                guard expectedRemoteVersions.count <= limits.entries else { throw StorageDeletionFailure(.limitExceeded) }
                var expected: [URL: String] = [:], actual: [URL: String] = [:]
                for (url, version) in expectedRemoteVersions {
                    guard let remote = RemoteLocation.parse(url) else { throw StorageDeletionFailure(.unsafePath) }
                    try Self.key(remote.key)
                    let canonical = RemoteLocation.url(connectionID: remote.connectionID, key: remote.key)
                    guard !version.isEmpty, expected.updateValue(version, forKey: canonical) == nil else {
                        throw StorageDeletionFailure(.changed)
                    }
                }
                for root in roots {
                    if case .remote(_, let connection, _, let objects) = root {
                        for object in objects {
                            guard let version = object.version, !version.isEmpty else { throw StorageDeletionFailure(.changed) }
                            actual[RemoteLocation.url(connectionID: connection.id, key: object.key)] = version
                        }
                    }
                }
                guard actual == expected else { throw StorageDeletionFailure(.changed) }
            }
            let preview = StorageDeletionPlan(schemaVersion: 1, id: UUID(), expiresAt: clock().addingTimeInterval(lifetime),
                                              sources: roots.map(\.url), itemCount: count, recursive: recursive)
            guard plans.count < 128 else { throw StorageDeletionFailure(.limitExceeded) }
            plans[preview.id] = DeletionStoredPlan(preview: preview, roots: roots)
            return preview
        } catch { throw Self.failure(error) }
    }

    public func execute(planID: UUID, undoHistory: LocalTransferService? = nil, authorizationCheck: @escaping @Sendable (URL) async -> Bool) async throws -> StorageDeletionResult {
        try Self.cancel()
        guard consumed[planID] == nil else { throw StorageDeletionFailure(.reusedPlan) }
        guard let plan = plans.removeValue(forKey: planID) else { throw StorageDeletionFailure(.invalidPlan) }
        consumed[planID] = plan.preview.expiresAt
        running.insert(planID)
        defer { running.remove(planID); revoked.remove(planID) }
        // No suspension precedes consumption: concurrent execution cannot replay the plan.
        guard clock() < plan.preview.expiresAt else { throw StorageDeletionFailure(.expiredPlan) }
        var completed: [URL] = []
        do {
            for root in plan.roots {
                try active(planID)
                switch root {
                case .local(let expected):
                    // One Trash mutation covers the whole subtree: authorize every planned entry first.
                    for url in expected.items.keys.sorted(by: { $0.path < $1.path }) {
                        guard await authorizationCheck(url) else { throw StorageDeletionFailure(.notAuthorized) }
                        try active(planID)
                    }
                    let actual = try await Self.offMain { try DeletionLocalSnapshot.capture(expected.source, limits: self.limits) }
                    guard actual == expected else { throw StorageDeletionFailure(.changed) }
                    // Recheck grants after the filesystem scan; authorization can be revoked while it runs.
                    for url in expected.items.keys.sorted(by: { $0.path < $1.path }) {
                        guard await authorizationCheck(url) else { throw StorageDeletionFailure(.notAuthorized) }
                        try active(planID)
                    }
                    // A callback can itself modify the target. Reject such changes before the mutation.
                    let finalSnapshot = try await Self.offMain { try DeletionLocalSnapshot.capture(expected.source, limits: self.limits) }
                    guard finalSnapshot == expected else { throw StorageDeletionFailure(.changed) }
                    guard await authorizationCheck(expected.source) else { throw StorageDeletionFailure(.notAuthorized) }
                    try active(planID)
                    try await Self.offMain {
                        do { try LocalTransferRecovery.assertExportable(expected.source) }
                        catch { throw StorageDeletionFailure(Task.isCancelled ? .cancelled : .unsupportedEntry) }
                    }
                    try active(planID)
                    if undoHistory != nil || trashLibrary != nil {
                        let original = try TrashRestoreOrigin(expected.source)
                        if let location = try await trash.trashReturningURL(expected.source) {
                            await undoHistory?.recordTrash(original, at: location, group: planID)
                            completed.append(expected.source)
                            try await trashLibrary?.record(TrashedItem(origin: original, location: location))
                        } else { completed.append(expected.source) }
                    } else {
                        try await trash.trash(expected.source)
                        completed.append(expected.source)
                    }
                case .remote(let source, let connection, let key, let expected):
                    let id = connection.id
                    let client = try await clientFactory(id)
                    guard client.connection == connection else {
                        throw StorageDeletionFailure(.changed)
                    }
                    let current = try await inventory(client: client, key: key)
                    guard !current.isEmpty else { throw StorageDeletionFailure(.notFound) }
                    guard DeletionRemoteInventory.matches(current, expected) else {
                        throw StorageDeletionFailure(.changed)
                    }
                    for object in DeletionRemoteInventory.ordered(expected, descending: true) {
                        try active(planID)
                        let url = RemoteLocation.url(connectionID: id, key: object.key)
                        guard let actual = try await client.stat(key: object.key) else { throw StorageDeletionFailure(.notFound) }
                        guard DeletionRemoteInventory.sameObject(actual, object), let version = actual.version else {
                            throw StorageDeletionFailure(.changed)
                        }
                        guard await authorizationCheck(url) else { throw StorageDeletionFailure(.notAuthorized) }
                        try active(planID)
                        var backup: S3DeletedItem?
                        if undoHistory != nil, connection.provider == .s3 {
                            backup = try await S3DeletedItem.capture(actual, version: version, client: client, factory: clientFactory)
                            guard await authorizationCheck(url) else { throw StorageDeletionFailure(.notAuthorized) }
                            try active(planID)
                        }
                        switch try await client.delete(key: object.key, matchingVersion: version) {
                        case .acknowledged:
                            if let backup { await undoHistory?.recordS3Trash(backup, group: planID) }
                            completed.append(url)
                        case .absent: throw StorageDeletionFailure(.notFound)
                        case .changed:
                            throw StorageDeletionFailure(.changed)
                        case .indeterminate:
                            if let backup { await undoHistory?.recordS3Trash(backup, group: planID) }
                            throw StorageDeletionFailure(.indeterminate, indeterminate: [url])
                        }
                    }
                    if key.hasSuffix("/") {
                        try active(planID)
                        let remaining = try await inventory(client: client, key: key)
                        guard remaining.isEmpty else {
                            throw StorageDeletionFailure(.changed)
                        }
                    }
                    _ = source
                }
            }
            return StorageDeletionResult(completed: completed)
        } catch {
            let failure = Self.failure(error)
            throw StorageDeletionFailure(failure.reason, completed: completed, indeterminate: failure.indeterminate, cloudReason: failure.cloudReason)
        }
    }

    private func active(_ id: UUID) throws {
        try Self.cancel()
        guard !revoked.contains(id) else { throw StorageDeletionFailure(.notAuthorized) }
    }
    private func inventory(client: CloudStorageClient, key: String) async throws -> [CloudObject] {
        try Self.key(key)
        if !key.hasSuffix("/") {
            guard let object = try await client.stat(key: key) else { return [] }
            guard object.key.utf8.elementsEqual(key.utf8), object.version != nil else {
                throw StorageDeletionFailure(.changed)
            }
            return [object]
        }
        var results: [Data: CloudObject] = [:]
        var visited: Set<Data> = []
        var queue: [(String, Int)] = [(key, 0)]
        var pages = 0
        while !queue.isEmpty {
            try Self.cancel()
            let (prefix, depth) = queue.removeFirst()
            guard depth <= limits.depth, visited.insert(Data(prefix.utf8)).inserted else { throw StorageDeletionFailure(.limitExceeded) }
            if let marker = try await client.stat(key: prefix) {
                guard marker.key.utf8.elementsEqual(prefix.utf8), marker.version != nil else {
                    throw StorageDeletionFailure(.changed)
                }
                results[Data(prefix.utf8)] = marker
            }
            var token: String?
            var tokens: Set<String> = []
            repeat {
                pages += 1
                guard pages <= limits.entries + 1 else { throw StorageDeletionFailure(.limitExceeded) }
                let page = try await client.list(prefix: prefix, continuationToken: token)
                for object in page.objects {
                    try Self.key(object.key)
                    guard object.key.utf8.starts(with: prefix.utf8) else { throw StorageDeletionFailure(.unsafePath) }
                    if object.key.utf8.elementsEqual(prefix.utf8) { continue }
                    let relative = String(object.key.dropFirst(prefix.count))
                    let trimmed = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
                    guard !trimmed.contains("/"), !trimmed.isEmpty else { throw StorageDeletionFailure(.unsafePath) }
                    if object.isDirectory {
                        guard object.key.hasSuffix("/") else { throw StorageDeletionFailure(.unsafePath) }
                        if !queue.contains(where: { $0.0.utf8.elementsEqual(object.key.utf8) }) { queue.append((object.key, depth + 1)) }
                    } else {
                        guard let actual = try await client.stat(key: object.key), actual.key.utf8.elementsEqual(object.key.utf8), actual.version != nil else {
                            throw StorageDeletionFailure(.changed)
                        }
                        results[Data(object.key.utf8)] = actual
                    }
                    guard results.count + queue.count + visited.count - 1 <= limits.entries else { throw StorageDeletionFailure(.limitExceeded) }
                }
                token = page.nextToken
                if let token, !tokens.insert(token).inserted { throw StorageDeletionFailure(.unsafePath) }
            } while token != nil
        }
        guard results.count <= limits.entries else { throw StorageDeletionFailure(.limitExceeded) }
        return DeletionRemoteInventory.ordered(Array(results.values))
    }
    private static func key(_ key: String) throws {
        let value = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard !value.isEmpty, !value.utf8.contains(0), !value.contains("\\"), !value.contains(":"),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StorageDeletionFailure(.unsafePath)
        }
    }
    private static func overlap(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.isFileURL && rhs.isFileURL {
            return lhs.path == rhs.path || lhs.path.hasPrefix(rhs.path + "/") || rhs.path.hasPrefix(lhs.path + "/")
        }
        guard let a = RemoteLocation.parse(lhs), let b = RemoteLocation.parse(rhs), a.connectionID == b.connectionID else { return false }
        return a.key.utf8.elementsEqual(b.key.utf8) || (a.key.hasSuffix("/") && b.key.utf8.starts(with: a.key.utf8)) || (b.key.hasSuffix("/") && a.key.utf8.starts(with: b.key.utf8))
    }
    private static func cancel() throws { if Task.isCancelled { throw StorageDeletionFailure(.cancelled) } }
    private static func failure(_ error: any Error) -> StorageDeletionFailure {
        if let error = error as? StorageDeletionFailure { return error }
        if let error = error as? CloudFailure { return StorageDeletionFailure(error.reason == .cancelled ? .cancelled : .cloud, cloudReason: error.reason) }
        if error is CancellationError { return StorageDeletionFailure(.cancelled) }
        return StorageDeletionFailure(.io)
    }
    private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try cancel()
        let worker = Task.detached(priority: .userInitiated) { try cancel(); return try body() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
/// Object-storage identities are UTF-8 bytes, not Unicode-normalized Swift String keys.
/// Inventory equality is independent of enumeration/dictionary order and includes every field.
internal enum DeletionRemoteInventory {
    static func sameObject(_ lhs: CloudObject, _ rhs: CloudObject) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.size == rhs.size && lhs.modified == rhs.modified &&
        lhs.isDirectory == rhs.isDirectory && lhs.version.map { Data($0.utf8) } == rhs.version.map { Data($0.utf8) }
    }
    static func matches(_ lhs: [CloudObject], _ rhs: [CloudObject]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var expected: [Data: CloudObject] = [:]
        for object in rhs {
            guard expected.updateValue(object, forKey: Data(object.key.utf8)) == nil else { return false }
        }
        var seen = Set<Data>()
        for object in lhs {
            let identity = Data(object.key.utf8)
            guard seen.insert(identity).inserted, let prior = expected[identity], sameObject(object, prior) else { return false }
        }
        return true
    }
    static func ordered(_ objects: [CloudObject], descending: Bool = false) -> [CloudObject] {
        objects.sorted { left, right in
            descending ? right.key.utf8.lexicographicallyPrecedes(left.key.utf8) : left.key.utf8.lexicographicallyPrecedes(right.key.utf8)
        }
    }
}

private struct DeletionStoredPlan: Sendable { let preview: StorageDeletionPlan; let roots: [DeletionRoot] }
private enum DeletionRoot: Sendable {
    case local(DeletionLocalSnapshot)
    case remote(URL, CloudConnection, String, [CloudObject])
    var url: URL { switch self { case .local(let value): value.source; case .remote(let url, _, _, _): url } }
    var count: Int { switch self { case .local(let value): value.items.count; case .remote(_, _, _, let objects): objects.count } }
}

private struct DeletionIdentity: Equatable, Sendable {
    let device: Int32, inode: UInt64, type: UInt16, size: Int64
    let mtime: Int, mnano: Int, ctime: Int, cnano: Int
    init(_ info: Darwin.stat) {
        device = info.st_dev; inode = info.st_ino; type = info.st_mode & S_IFMT; size = info.st_size
        mtime = info.st_mtimespec.tv_sec; mnano = info.st_mtimespec.tv_nsec
        ctime = info.st_ctimespec.tv_sec; cnano = info.st_ctimespec.tv_nsec
    }
    var ancestor: DeletionAncestor { .init(device: device, inode: inode, type: type) }
}
private struct DeletionAncestor: Equatable, Sendable { let device: Int32; let inode: UInt64; let type: UInt16 }
private struct DeletionLocalSnapshot: Equatable, Sendable {
    let source: URL
    let items: [URL: DeletionIdentity]
    let ancestors: [URL: DeletionAncestor]
    var directory: Bool { items[source]?.type == S_IFDIR }

    static func capture(_ input: URL, limits: StorageDeletionService.Limits) throws -> Self {
        guard input.isFileURL, input.host == nil || input.host == "localhost", input.query == nil, input.fragment == nil else {
            throw StorageDeletionFailure(.unsafePath)
        }
        let source = input.standardizedFileURL
        guard source.path != "/", !source.path.isEmpty else { throw StorageDeletionFailure(.unsafePath) }
        // Foundation canonicalizes /private/var back to /var. Permit only macOS's fixed system aliases,
        // recording their link identity; all user-controlled ancestor links remain forbidden.
        var ancestors: [URL: DeletionAncestor] = [:]
        var parent = URL(fileURLWithPath: "/")
        for part in source.deletingLastPathComponent().pathComponents.dropFirst() {
            parent.appendPathComponent(part)
            var info = Darwin.stat()
            guard lstat(parent.path, &info) == 0 else { throw StorageDeletionFailure(.unsafePath) }
            if info.st_mode & S_IFMT != S_IFDIR {
                let aliases = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]
                guard info.st_mode & S_IFMT == S_IFLNK, let target = aliases[parent.path],
                      let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path),
                      actual == target || actual == "/" + target else { throw StorageDeletionFailure(.unsafePath) }
            }
            ancestors[parent] = DeletionIdentity(info).ancestor
        }
        let fd = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageDeletionFailure(.unsafePath) }
        defer { close(fd) }
        var items: [URL: DeletionIdentity] = [:]
        try walk(parentFD: fd, name: source.lastPathComponent, url: source, depth: 0, limits: limits, items: &items)
        // A mounted filesystem root must not be sent to Trash.
        var parentInfo = Darwin.stat()
        guard fstat(fd, &parentInfo) == 0, items[source]?.device == parentInfo.st_dev else { throw StorageDeletionFailure(.unsafePath) }
        for (url, identity) in ancestors {
            var info = Darwin.stat()
            guard lstat(url.path, &info) == 0, DeletionIdentity(info).ancestor == identity else { throw StorageDeletionFailure(.changed) }
        }
        return Self(source: source, items: items, ancestors: ancestors)
    }
    private static func walk(parentFD: Int32, name: String, url: URL, depth: Int,
                             limits: StorageDeletionService.Limits, items: inout [URL: DeletionIdentity]) throws {
        if Task.isCancelled { throw StorageDeletionFailure(.cancelled) }
        guard !LocalTransferRecovery.isProtected(url) else { throw StorageDeletionFailure(.unsupportedEntry) }
        guard depth <= limits.depth, items.count < limits.entries else { throw StorageDeletionFailure(.limitExceeded) }
        var info = Darwin.stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw StorageDeletionFailure(errno == ENOENT ? .notFound : .io) }
        let identity = DeletionIdentity(info)
        var parentInfo = Darwin.stat()
        guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_dev == identity.device else { throw StorageDeletionFailure(.unsafePath) }
        guard identity.type == S_IFREG || identity.type == S_IFDIR else { throw StorageDeletionFailure(.unsupportedEntry) }
        items[url] = identity
        guard identity.type == S_IFDIR else { return }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageDeletionFailure(.changed) }
        defer { close(fd) }
        var opened = Darwin.stat()
        guard fstat(fd, &opened) == 0, DeletionIdentity(opened) == identity else { throw StorageDeletionFailure(.changed) }
        guard let directory = fdopendir(dup(fd)) else { throw StorageDeletionFailure(.io) }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if child != "." && child != ".." { names.append(child) }
            guard names.count + items.count <= limits.entries else { throw StorageDeletionFailure(.limitExceeded) }
        }
        guard errno == 0 else { throw StorageDeletionFailure(.io) }
        for child in names.sorted() { try walk(parentFD: fd, name: child, url: url.appendingPathComponent(child), depth: depth + 1, limits: limits, items: &items) }
        guard fstat(fd, &opened) == 0, DeletionIdentity(opened) == identity else { throw StorageDeletionFailure(.changed) }
    }
}
