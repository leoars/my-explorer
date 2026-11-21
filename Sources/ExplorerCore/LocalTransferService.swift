// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CryptoKit

/// Local transfers and an in-session undo journal. Each top-level item publishes atomically.
/// Backups stay on their original volumes so a failed cross-volume move never loses its source.
public actor LocalTransferService {
    private var history: [LocalTransferRecord] = []
    private let historyLimit: Int
    private var occupied = false
    private let hooks: LocalTransferHooks
    private var retainedRecoveryRoots: Set<String> = []
    public init(historyLimit: Int = 20) { self.historyLimit = min(100, max(1, historyLimit)); hooks = LocalTransferHooks() }
    init(historyLimit: Int = 20, hooks: LocalTransferHooks) {
        self.historyLimit = min(100, max(1, historyLimit)); self.hooks = hooks
    }
    public var canUndo: Bool { !history.isEmpty && !occupied }
    public var undoKind: LocalTransferKind? { history.last?.kind }

    public func transfer(sources: [URL], to destination: URL, move: Bool,
                         resolveConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                         progress: (@Sendable (StorageTransferProgress) -> Void)? = nil,
                         control: LocalTransferControl = LocalTransferControl()) async throws -> [URL] {
        guard !occupied else { throw LocalTransferFailure(.busy) }
        occupied = true; defer { occupied = false }
        var actions: [LocalTransferAction] = [], completed: [URL] = []
        do {
            let privateRoots = history.flatMap { $0.actions.flatMap { [$0.roots.destination] + ($0.roots.source.map { [$0] } ?? []) } }
            let prepared = try await Self.worker(control) {
                try LocalTransferFS.prepare(sources: sources, destination: destination, privateRoots: privateRoots, control: control)
            }
            let tracker = LocalTransferTracker(snapshots: prepared.sources.map(\.snapshot), progress: progress, control: control)
            for source in prepared.sources {
                try control.checkpoint()
                let initial = prepared.destination.appendingPathComponent(source.url.lastPathComponent)
                if move && source.url == initial { tracker.finish(source.snapshot); continue }
                let action = try await buildAndPublish(source: source, destination: initial, move: move,
                    parent: prepared.parent, resolver: resolveConflict, tracker: tracker, control: control)
                if let action { actions.append(action); completed.append(action.destination) }
            }
            if !actions.isEmpty { await appendRecord(LocalTransferRecord(kind: move ? .move : .copy, actions: actions)) }
            return completed
        } catch {
            retainRecovery(from: error)
            if !actions.isEmpty { await appendRecord(LocalTransferRecord(kind: move ? .move : .copy, actions: actions)) }
            let failure = error as? LocalTransferFailure
            throw LocalTransferFailure(failure?.reason ?? (Task.isCancelled ? .cancelled : .io),
                                       completed: completed + (failure?.completed ?? []),
                                       recoveryLocations: failure?.recoveryLocations ?? [])
        }
    }

    func recordTrash(_ origin: TrashRestoreOrigin, at location: URL, group: UUID) async {
        let item = TrashedItem(origin: origin, location: location)
        if history.last?.trashGroup == group {
            history[history.count - 1].trashed.append(item)
        } else {
            await appendRecord(LocalTransferRecord(kind: .trash, actions: [], trashGroup: group, trashed: [item]))
        }
    }

    func recordS3Trash(_ item: S3DeletedItem, group: UUID) async {
        if history.last?.trashGroup == group {
            history[history.count - 1].s3Items.append(item)
        } else {
            await appendRecord(LocalTransferRecord(kind: .trash, actions: [], trashGroup: group, s3Items: [item]))
        }
    }

    public func undo(resolveTrashConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice = { _ in .cancel },
                     progress: (@Sendable (StorageTransferProgress) -> Void)? = nil,
                     control: LocalTransferControl = LocalTransferControl()) async throws -> [URL] {
        guard !occupied else { throw LocalTransferFailure(.busy) }
        guard var record = history.last else { throw LocalTransferFailure(.undoUnavailable) }
        occupied = true; defer { occupied = false }
        if record.kind == .trash {
            return try await restoreTrash(record, resolveConflict: resolveTrashConflict, control: control)
        }
        // Validate the entire record before mutating anything, including replaced originals and leftovers.
        let initialActions = record.actions
        try await Self.worker(control) { try LocalTransferFS.validateUndo(initialActions, control: control) }
        var completed: [URL] = []
        do {
            while let action = record.actions.last {
                try control.checkpoint()
                let hooks = self.hooks
                try await Self.worker(control) { try LocalTransferFS.undo(action, control: control, hooks: hooks) }
                record.actions.removeLast()
                completed.append(action.destination.deletingLastPathComponent())
                if action.sourceBackup != nil || action.directMove { completed.append(action.source.deletingLastPathComponent()) }
                let remaining = record
                record = await Task.detached { LocalTransferFS.rebased([remaining])[0] }.value
                history[history.count - 1] = record
                progress?(StorageTransferProgress(completedItems: completed.count, totalItems: completed.count + record.actions.count,
                    currentSource: action.destination, currentDestination: action.sourceBackup == nil ? nil : action.source,
                    bytesCompleted: 0, totalBytes: nil))
            }
            history.removeLast()
            await rebaseHistory()
            return Array(Set(completed))
        } catch {
            retainRecovery(from: error)
            if record.actions.isEmpty { history.removeLast() }
            await rebaseHistory()
            let failure = error as? LocalTransferFailure
            throw LocalTransferFailure(failure?.reason ?? .io, completed: completed,
                                       recoveryLocations: failure?.recoveryLocations ?? [])
        }
    }

    private func restoreTrash(_ record: LocalTransferRecord,
                              resolveConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                              control: LocalTransferControl) async throws -> [URL] {
        var targets: [(TrashedItem, URL)] = []
        var completed: [URL] = []
        do {
            guard let group = record.trashGroup else { throw LocalTransferFailure(.undoUnavailable) }
            for item in record.s3Items.reversed() {
                let url = try await item.restore(resolveConflict: resolveConflict, control: control)
                if let index = history.firstIndex(where: { $0.trashGroup == group }) {
                    history[index].s3Items.removeAll { $0 === item }
                }
                completed.append(url)
            }
            // Resolve all known collisions before moving any item in the selection.
            var reserved = Set(record.trashed.map { $0.origin.url.explorerIdentity })
            for item in record.trashed.reversed() {
                var destination = item.origin.url
                let occupied: Bool
                do {
                    occupied = try await Self.worker(control) {
                        try item.validate()
                        return LocalTransferFS.exists(item.origin.url)
                    }
                } catch let failure as LocalTransferFailure where failure.reason == .trashUnavailable {
                    if let index = history.firstIndex(where: { $0.trashGroup == group }) {
                        history[index].trashed.removeAll { $0.location == item.location }
                    }
                    throw failure
                }
                if occupied {
                    let conflict = StorageConflict(source: item.location, destination: destination, isDirectory: item.origin.isDirectory)
                    guard await resolveConflict(conflict) == .keepBoth else { throw LocalTransferFailure(.cancelled) }
                    let excluded = reserved
                    destination = try await Self.worker(control) {
                        try LocalTransferFS.availableName(item.origin.url, directory: item.origin.isDirectory, excluding: excluded)
                    }
                    reserved.insert(destination.explorerIdentity)
                }
                targets.append((item, destination))
            }
            for (item, destination) in targets {
                try await Self.worker(control) { try item.restore(to: destination) }
                if let index = history.firstIndex(where: { $0.trashGroup == group }) {
                    history[index].trashed.removeAll { $0.location == item.location }
                }
                completed.append(destination)
            }
        } catch {
            history.removeAll { $0.trashGroup == record.trashGroup && $0.trashed.isEmpty && $0.s3Items.isEmpty }
            if !completed.isEmpty { await rebaseHistory() }
            if completed.isEmpty, let cloudError = error as? CloudFailure { throw cloudError }
            throw LocalTransferFailure((error as? LocalTransferFailure)?.reason ?? .io, completed: completed)
        }
        history.removeAll { $0.trashGroup == record.trashGroup && $0.trashed.isEmpty && $0.s3Items.isEmpty }
        await rebaseHistory()
        return completed
    }

    public func forgetTrash(location: URL) async {
        for index in history.indices where history[index].kind == .trash {
            history[index].trashed.removeAll { $0.location.standardizedFileURL.path == location.standardizedFileURL.path }
        }
        history.removeAll { $0.kind == .trash && $0.trashed.isEmpty && $0.s3Items.isEmpty }
        await rebaseHistory()
    }

    /// Discards undo history after expiry/quit. Modified backups are retained for manual recovery.
    public func clearHistory() async {
        guard !occupied else { return }
        occupied = true; defer { occupied = false }
        let old = history, retained = retainedRecoveryRoots; history.removeAll()
        await Task.detached { for record in old { LocalTransferFS.discard(record, retaining: retained) } }.value
    }

    private func appendRecord(_ record: LocalTransferRecord) async {
        history.append(record)
        if history.count > historyLimit {
            let old = history.removeFirst()
            let retained = retainedRecoveryRoots
            await Task.detached { LocalTransferFS.discard(old, retaining: retained) }.value
        }
    }
    private func retainRecovery(from error: any Error) {
        guard let failure = error as? LocalTransferFailure, failure.reason == .recoveryRequired else { return }
        retainedRecoveryRoots.formUnion(failure.recoveryLocations.map { $0.standardizedFileURL.path })
    }
    private func rebaseHistory() async {
        let records = history
        history = await Task.detached { LocalTransferFS.rebased(records) }.value
    }
    private static func worker<T: Sendable>(_ control: LocalTransferControl,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) {
            try control.checkpoint(); return try body()
        }
        return try await withTaskCancellationHandler { try await worker.value }
            onCancel: { control.cancel(); worker.cancel() }
    }

    private func buildAndPublish(source: LocalTransferSource, destination initial: URL, move: Bool,
                                 parent: LocalTransferParent,
                                 resolver: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                                 tracker: LocalTransferTracker, control: LocalTransferControl) async throws -> LocalTransferAction? {
        var destination = initial
        var original = try await Self.worker(control) {
            if LocalTransferFS.exists(initial) { try LocalTransferRecovery.assertExportable(initial) }
            return try LocalTransferFS.snapshotIfPresent(initial, control: control)
        }
        if source.url == initial {
            destination = try LocalTransferFS.availableName(initial, directory: source.snapshot.isDirectory)
            original = nil
        } else if let current = original {
            let choice = await resolver(StorageConflict(source: source.url, destination: initial,
                isDirectory: source.snapshot.isDirectory && current.isDirectory))
            try control.checkpoint()
            switch choice {
            case .skip: tracker.finish(source.snapshot); return nil
            case .cancel: throw LocalTransferFailure(.cancelled)
            case .keepBoth:
                destination = try LocalTransferFS.availableName(initial, directory: source.snapshot.isDirectory)
                original = nil
            case .replace: break
            }
        }
        let target = destination, before = original
        var parentInfo = stat()
        guard stat(target.deletingLastPathComponent().path, &parentInfo) == 0 else { throw LocalTransferFailure(.invalidDestination) }
        let direct = move && source.snapshot.entries[""]?.device == UInt64(parentInfo.st_dev)
            && !(source.snapshot.isDirectory && before?.isDirectory == true)
        let roots = try await Self.worker(control) {
            try parent.validate()
            let roots = try LocalTransferFS.makeRoots(source: source.url, destination: target, move: move && !direct)
            let all = [roots.destination] + (roots.source.map { [$0] } ?? [])
            if all.contains(where: { $0.path.hasPrefix(source.url.path + "/") || $0 == source.url || $0.path.hasPrefix(target.path + "/") || $0 == target }) {
                LocalTransferFS.removeRoots(roots)
                throw LocalTransferFailure(.unsupportedEntry)
            }
            return roots
        }
        var published = false
        do {
            let hooks = self.hooks
            if direct {
                let action = try await Self.worker(control) {
                    try parent.validate()
                    return try LocalTransferFS.publishDirect(source: source, destination: target, original: before, roots: roots, control: control, hooks: hooks)
                }
                published = true
                tracker.finish(source.snapshot)
                return action
            }
            let stage = roots.destination.appendingPathComponent("output")
            var skipped: Set<String> = []
            if let before, before.isDirectory && source.snapshot.isDirectory {
                try await Self.worker(control) {
                    try LocalTransferFS.requireSnapshot(target, before, control: control)
                    try LocalTransferFS.copyTree(target, to: stage, control: control)
                }
                try await overlay(source: source.url, into: stage, final: target, relative: "", skipped: &skipped,
                                  resolver: resolver, tracker: tracker, control: control)
            } else {
                try await Self.worker(control) {
                    try LocalTransferFS.copyTree(source.url, to: stage, control: control, tracker: tracker,
                                                 finalDestination: target)
                }
            }
            let kept = skipped
            if move, !kept.isEmpty, let sourceRoot = roots.source {
                try await Self.worker(control) {
                    try LocalTransferFS.copyRemaining(source.url, to: sourceRoot.appendingPathComponent("remaining"),
                        relative: "", skipped: kept, control: control)
                }
            }
            let action = try await Self.worker(control) {
                try parent.validate()
                return try LocalTransferFS.publish(source: source, destination: target, original: before,
                    roots: roots, move: move, hasRemaining: !kept.isEmpty, control: control, hooks: hooks)
            }
            published = true
            return action
        } catch {
            if !published, (error as? LocalTransferFailure)?.reason != .recoveryRequired {
                await Task.detached { LocalTransferFS.removeRoots(roots) }.value
            }
            throw error
        }
    }

    /// Existing destination directories are merged, never followed through a symlink.
    private func overlay(source: URL, into stage: URL, final: URL, relative: String,
                         skipped: inout Set<String>,
                         resolver: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                         tracker: LocalTransferTracker, control: LocalTransferControl) async throws {
        try control.checkpoint()
        try LocalTransferFS.makeDirectoryWritable(stage)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
            try control.checkpoint()
            let child = source.appendingPathComponent(name)
            let rel = relative.isEmpty ? name : relative + "/" + name
            let childInfo = try await Self.worker(control) { try LocalTransferFS.snapshot(child, control: control) }
            var stagedTarget = stage.appendingPathComponent(name)
            var finalTarget = final.appendingPathComponent(name)
            let initialStaged = stagedTarget
            if let existing = try await Self.worker(control, { try LocalTransferFS.snapshotIfPresent(initialStaged, control: control) }) {
                let choice = await resolver(StorageConflict(source: child, destination: finalTarget,
                    isDirectory: childInfo.isDirectory && existing.isDirectory))
                try control.checkpoint()
                switch choice {
                case .cancel: throw LocalTransferFailure(.cancelled)
                case .skip: skipped.insert(rel); tracker.finish(childInfo); continue
                case .keepBoth:
                    stagedTarget = try LocalTransferFS.availableName(stagedTarget, directory: childInfo.isDirectory)
                    finalTarget = final.appendingPathComponent(stagedTarget.lastPathComponent)
                case .replace:
                    if childInfo.isDirectory && existing.isDirectory {
                        try await overlay(source: child, into: stagedTarget, final: finalTarget, relative: rel,
                                          skipped: &skipped, resolver: resolver, tracker: tracker, control: control)
                        continue
                    }
                    // Only the private staging copy is removed; the live destination is untouched here.
                    try FileManager.default.removeItem(at: stagedTarget)
                }
            }
            let output = stagedTarget, outputLocation = finalTarget
            try await Self.worker(control) {
                try LocalTransferFS.copyTree(child, to: output, control: control, tracker: tracker,
                                             finalDestination: outputLocation)
            }
        }
        // Keep existing folder metadata when merging, like the existing cloud merge operation.
        try await Self.worker(control) { try LocalTransferFS.copyMetadata(from: final, to: stage) }
        tracker.finishDirectory(source, destination: final)
    }
}

/// Internal fault injection for deterministic transaction-race tests; production uses empty hooks.
struct LocalTransferHooks: Sendable {
    var beforeRename: (@Sendable (URL, URL) -> Void)?
    var afterRename: (@Sendable (URL, URL) -> Void)?
    var beforeRecord: (@Sendable (URL) -> Void)?
}
private struct LocalTransferSource: Sendable {
    let url: URL
    let snapshot: LocalTransferSnapshot
    let parent: LocalTransferParent
}
private struct LocalTransferRoots: Sendable { let destination: URL; let source: URL? }
private struct LocalTransferRecord: Sendable {
    let kind: LocalTransferKind
    var actions: [LocalTransferAction]
    var trashGroup: UUID? = nil
    var trashed: [TrashedItem] = []
    var s3Items: [S3DeletedItem] = []
}
private struct LocalTransferAction: Sendable {
    let source: URL
    let destination: URL
    let destinationParent: LocalTransferParent
    let sourceParent: LocalTransferParent
    let roots: LocalTransferRoots
    let destinationBackup: URL?
    let sourceBackup: URL?
    let directMove: Bool
    var output: LocalTransferSnapshot
    var originalDestination: LocalTransferSnapshot?
    var originalSource: LocalTransferSnapshot?
    var remainingSource: LocalTransferSnapshot?
}
private struct LocalTransferParent: Sendable {
    let chain: [(URL, UInt64, UInt64)]
    let original: URL
    let resolved: String
    init(_ parent: URL) throws {
        guard let path = realpath(parent.path, nil) else { throw LocalTransferFailure(.invalidDestination) }
        let resolved = String(cString: path); free(path)
        self.original = parent; self.resolved = resolved
        var url = URL(fileURLWithPath: resolved)
        var chain: [(URL, UInt64, UInt64)] = []
        while true {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw LocalTransferFailure(.invalidDestination) }
            chain.append((url, UInt64(info.st_dev), info.st_ino))
            if url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        self.chain = chain
    }
    func validate() throws {
        guard let path = realpath(original.path, nil) else { throw LocalTransferFailure(.changed) }
        let current = String(cString: path); free(path)
        guard current == resolved else { throw LocalTransferFailure(.changed) }
        for (url, device, inode) in chain {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  UInt64(info.st_dev) == device, info.st_ino == inode else { throw LocalTransferFailure(.changed) }
        }
    }
}
private struct LocalTransferAttributes: Equatable, Sendable {
    let ordinaryDigest: Data
    let quarantineDigest: Data?

    func matchesCopy(_ copy: Self) -> Bool {
        // copyfile can reissue quarantine with a new timestamp and agent. Keep the
        // native marker on the copy; exact equality still governs source and Undo checks.
        ordinaryDigest == copy.ordinaryDigest &&
            (quarantineDigest == copy.quarantineDigest || copy.quarantineDigest?.isEmpty == false)
    }
}
private struct LocalTransferNode: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let type: UInt16
    let mode: UInt16
    let uid: UInt32
    let gid: UInt32
    let flags: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    let digest: Data
    let attributes: LocalTransferAttributes
    func equivalentForRebase(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && type == other.type && mode == other.mode && uid == other.uid && gid == other.gid
        && flags == other.flags && size == other.size && digest == other.digest && attributes == other.attributes
        && (type == S_IFDIR || (modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos))
    }
}
private struct LocalTransferSnapshot: Equatable, Sendable {
    let entries: [String: LocalTransferNode]
    var isDirectory: Bool { entries[""]?.type == S_IFDIR }
    var bytes: Int64 { entries.values.reduce(0) { $0 + ($1.type == S_IFREG ? $1.size : 0) } }
    func equivalentForRebase(_ other: Self) -> Bool {
        entries.keys.count == other.entries.keys.count && entries.allSatisfy { name, node in
            other.entries[name].map(node.equivalentForRebase) == true
        }
    }
    func samePayload(_ other: Self) -> Bool {
        entries.count == other.entries.count && entries.allSatisfy { name, node in
            guard let value = other.entries[name] else { return false }
            return node.type == value.type && node.size == value.size && node.digest == value.digest && node.attributes.matchesCopy(value.attributes)
        }
    }
}

private enum LocalTransferFS {
    static func normalized(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(url.lastPathComponent)
    }
    static func prepare(sources: [URL], destination: URL, privateRoots: [URL], control: LocalTransferControl) throws ->
        (sources: [LocalTransferSource], destination: URL, parent: LocalTransferParent) {
        guard !sources.isEmpty, sources.count <= 10_000, sources.allSatisfy(\.isFileURL) else { throw LocalTransferFailure(.invalidSource) }
        guard destination.isFileURL else { throw LocalTransferFailure(.invalidDestination) }
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !LocalTransferRecovery.isProtected(destination) else { throw LocalTransferFailure(.invalidDestination) }
        let parent = try LocalTransferParent(destination)
        guard FileManager.default.isWritableFile(atPath: destination.path) else { throw LocalTransferFailure(.invalidDestination) }
        var urls: [URL] = [], prepared: [LocalTransferSource] = []
        for input in sources {
            try control.checkpoint()
            let url = normalized(input)
            try LocalTransferRecovery.assertExportable(url)
            guard url.path != "/", !urls.contains(url) else {
                throw LocalTransferFailure(.invalidSource)
            }
            for other in urls {
                if url.path.hasPrefix(other.path + "/") || other.path.hasPrefix(url.path + "/") { throw LocalTransferFailure(.recursive) }
            }
            if privateRoots.contains(where: { $0 == url || $0.path.hasPrefix(url.path + "/") }) {
                throw LocalTransferFailure(.unsupportedEntry)
            }
            let contents = try snapshot(url, control: control)
            if contents.isDirectory && (destination.path == url.path || destination.path.hasPrefix(url.path + "/")) {
                throw LocalTransferFailure(.recursive)
            }
            urls.append(url)
            prepared.append(LocalTransferSource(url: url, snapshot: contents, parent: try LocalTransferParent(url.deletingLastPathComponent())))
        }
        for source in urls {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            if target != source, urls.contains(target) { throw LocalTransferFailure(.recursive) }
        }
        return (prepared, destination, parent)
    }
    static func exists(_ url: URL) -> Bool {
        var value = stat(); return lstat(url.path, &value) == 0
    }
    static func snapshotIfPresent(_ url: URL, control: LocalTransferControl) throws -> LocalTransferSnapshot? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw LocalTransferFailure(.io)
        }
        return try snapshot(url, control: control)
    }
    static func snapshot(_ root: URL, control: LocalTransferControl) throws -> LocalTransferSnapshot {
        var values: [String: LocalTransferNode] = [:]
        var rootDevice: Int32?
        func walk(_ url: URL, _ relative: String, _ depth: Int) throws {
            try control.checkpoint()
            guard values.count < 100_000, depth <= 128 else { throw LocalTransferFailure(.limitExceeded) }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw LocalTransferFailure(.changed) }
            if rootDevice == nil { rootDevice = info.st_dev }
            guard info.st_dev == rootDevice else { throw LocalTransferFailure(.unsupportedEntry) }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else { throw LocalTransferFailure(.unsupportedEntry) }
            var digest = Data()
            if type == S_IFREG {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw LocalTransferFailure(.io) }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
                      opened.st_mode & S_IFMT == S_IFREG else { throw LocalTransferFailure(.changed) }
                var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 1_048_576)
                while true {
                    try control.checkpoint()
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 { if errno == EINTR { continue }; throw LocalTransferFailure(.io) }
                    if count == 0 { break }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                digest = Data(hash.finalize())
            } else if type == S_IFLNK {
                digest = Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)
            }
            let attributes = try attributeDigest(url)
            if type == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try walk(url.appendingPathComponent(name), relative.isEmpty ? name : relative + "/" + name, depth + 1)
                }
            }
            var after = stat()
            guard lstat(url.path, &after) == 0, stable(info, after) else { throw LocalTransferFailure(.changed) }
            values[relative] = LocalTransferNode(device: UInt64(info.st_dev), inode: info.st_ino, type: type,
                mode: info.st_mode, uid: info.st_uid, gid: info.st_gid, flags: info.st_flags,
                size: type == S_IFREG ? info.st_size : 0,
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec),
                digest: digest, attributes: attributes)
        }
        try walk(root, "", 0)
        return LocalTransferSnapshot(entries: values)
    }
    static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
        && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
        && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func attributeDigest(_ url: URL) throws -> LocalTransferAttributes {
        let count = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        if count < 0 {
            if errno != ENOTSUP { throw LocalTransferFailure(.io) }
        }
        if count <= 0 { return LocalTransferAttributes(ordinaryDigest: Data(SHA256().finalize()), quarantineDigest: nil) }
        var names = [CChar](repeating: 0, count: count)
        guard listxattr(url.path, &names, names.count, XATTR_NOFOLLOW) == count else { throw LocalTransferFailure(.changed) }
        let split = Data(names.map { UInt8(bitPattern: $0) }).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
        var hash = SHA256()
        var quarantine: Data?
        for name in split {
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0, size <= 32 * 1_048_576 else { throw LocalTransferFailure(size < 0 ? .changed : .limitExceeded) }
            var bytes = [UInt8](repeating: 0, count: size)
            guard getxattr(url.path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else { throw LocalTransferFailure(.changed) }
            if name == "com.apple.quarantine" {
                quarantine = bytes.isEmpty ? Data() : Data(SHA256.hash(data: bytes))
            } else {
                hash.update(data: Data(name.utf8)); hash.update(data: Data([0])); hash.update(data: Data(bytes))
            }
        }
        return LocalTransferAttributes(ordinaryDigest: Data(hash.finalize()), quarantineDigest: quarantine)
    }
    static func requireSnapshot(_ url: URL, _ expected: LocalTransferSnapshot?, control: LocalTransferControl) throws {
        guard try snapshotIfPresent(url, control: control) == expected else { throw LocalTransferFailure(.changed) }
    }
    static func availableName(_ proposed: URL, directory: Bool, excluding reserved: Set<String> = []) throws -> URL {
        let ext = directory ? "" : proposed.pathExtension
        let stem = ext.isEmpty ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
        for index in 2...100_000 {
            let name = stem + " (\(index))" + (ext.isEmpty ? "" : "." + ext)
            let candidate = proposed.deletingLastPathComponent().appendingPathComponent(name)
            if !reserved.contains(candidate.explorerIdentity), !exists(candidate) { return candidate }
        }
        throw LocalTransferFailure(.limitExceeded)
    }
    static func makeRoot(in parent: URL) throws -> URL {
        // Foundation chooses a private replacement location on the same volume, outside the user's folder.
        let root = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: parent, create: true)
        var original = stat(), journal = stat()
        guard stat(parent.path, &original) == 0, lstat(root.path, &journal) == 0,
              original.st_dev == journal.st_dev, journal.st_mode & S_IFMT == S_IFDIR,
              journal.st_uid == getuid(), chmod(root.path, 0o700) == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw LocalTransferFailure(.io)
        }
        do { try LocalTransferRecovery.mark(root) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        return root
    }
    static func makeRoots(source: URL, destination: URL, move: Bool) throws -> LocalTransferRoots {
        let root = try makeRoot(in: destination.deletingLastPathComponent())
        do { return LocalTransferRoots(destination: root, source: move ? try makeRoot(in: source.deletingLastPathComponent()) : nil) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    static func removeRoots(_ roots: LocalTransferRoots) {
        try? FileManager.default.removeItem(at: roots.destination)
        if let source = roots.source { try? FileManager.default.removeItem(at: source) }
    }
    static func makeDirectoryWritable(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw LocalTransferFailure(.changed) }
        guard chmod(url.path, info.st_mode | S_IWUSR | S_IXUSR) == 0 else { throw LocalTransferFailure(.io) }
    }
    static func copyMetadata(from source: URL, to destination: URL) throws {
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
            throw LocalTransferFailure(.io)
        }
    }
    static func copyTree(_ source: URL, to destination: URL, control: LocalTransferControl,
                         tracker: LocalTransferTracker? = nil, finalDestination: URL? = nil, verify: Bool = true) throws {
        try control.checkpoint()
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw LocalTransferFailure(.changed) }
        let final = finalDestination ?? destination
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard mkdir(destination.path, 0o700) == 0 else { throw LocalTransferFailure(.io) }
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                try copyTree(source.appendingPathComponent(name), to: destination.appendingPathComponent(name),
                             control: control, tracker: tracker, finalDestination: final.appendingPathComponent(name), verify: false)
            }
            try copyMetadata(from: source, to: destination)
            tracker?.finishDirectory(source, destination: final)
        case S_IFLNK:
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)) == 0 else {
                throw LocalTransferFailure(.io)
            }
            tracker?.finishDirectory(source, destination: final)
        case S_IFREG:
            let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw LocalTransferFailure(.io) }
            defer { close(input) }
            var opened = stat()
            guard fstat(input, &opened) == 0, stable(info, opened), opened.st_mode & S_IFMT == S_IFREG else { throw LocalTransferFailure(.changed) }
            let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw LocalTransferFailure(.io) }
            defer { close(output) }
            guard let state = copyfile_state_alloc() else { throw LocalTransferFailure(.io) }
            defer { copyfile_state_free(state) }
            let context = LocalTransferCopyContext(control: control, tracker: tracker, source: source, destination: final)
            let callback: copyfile_callback_t = { what, stage, state, _, _, raw in
                guard let raw else { return COPYFILE_QUIT }
                let context = Unmanaged<LocalTransferCopyContext>.fromOpaque(raw).takeUnretainedValue()
                do { try context.control.checkpoint() } catch { return COPYFILE_QUIT }
                if what == COPYFILE_COPY_DATA && (stage == COPYFILE_PROGRESS || stage == COPYFILE_FINISH) {
                    var count: off_t = 0
                    if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &count) == 0 { context.report(Int64(count)) }
                }
                return COPYFILE_CONTINUE
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
            let result = fcopyfile(input, output, state, copyfile_flags_t(COPYFILE_ALL))
            try control.checkpoint()
            guard result == 0, fsync(output) == 0 else { throw LocalTransferFailure(.io) }
            var after = stat()
            guard fstat(input, &after) == 0, stable(opened, after) else { throw LocalTransferFailure(.changed) }
            context.report(info.st_size)
            tracker?.finishDirectory(source, destination: final)
        default: throw LocalTransferFailure(.unsupportedEntry)
        }
        if verify {
            let original = try snapshot(source, control: control), copied = try snapshot(destination, control: control)
            guard original.samePayload(copied) else { throw LocalTransferFailure(.copyVerificationFailed) }
        }
    }
    static func copyRemaining(_ source: URL, to destination: URL, relative: String,
                              skipped: Set<String>, control: LocalTransferControl) throws {
        if skipped.contains(relative) { try copyTree(source, to: destination, control: control); return }
        let prefix = relative.isEmpty ? "" : relative + "/"
        guard skipped.contains(where: { $0.hasPrefix(prefix) }) else { return }
        guard mkdir(destination.path, 0o700) == 0 else { throw LocalTransferFailure(.io) }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
            let rel = relative.isEmpty ? name : relative + "/" + name
            if skipped.contains(rel) || skipped.contains(where: { $0.hasPrefix(rel + "/") }) {
                try copyRemaining(source.appendingPathComponent(name), to: destination.appendingPathComponent(name),
                                  relative: rel, skipped: skipped, control: control)
            }
        }
        try copyMetadata(from: source, to: destination)
    }
    static func moveExclusive(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw LocalTransferFailure(errno == EEXIST || errno == ENOTEMPTY ? .conflict : .io)
        }
    }
    private struct RenameStep { let source: URL; let destination: URL; let snapshot: LocalTransferSnapshot }
    private static func move(_ source: URL, to destination: URL, expected: LocalTransferSnapshot, log: inout [RenameStep], hooks: LocalTransferHooks) throws {
        let steady = LocalTransferControl()
        hooks.beforeRename?(source, destination)
        try requireSnapshot(source, expected, control: steady)
        try moveExclusive(source, to: destination)
        log.append(RenameStep(source: source, destination: destination, snapshot: expected))
        hooks.afterRename?(source, destination)
        guard try snapshot(destination, control: steady).equivalentForRebase(expected) else { throw LocalTransferFailure(.changed) }
    }
    private static func rollback(_ log: [RenameStep], roots: LocalTransferRoots) throws {
        do {
            for step in log.reversed() {
                let current = try snapshot(step.destination, control: LocalTransferControl())
                guard current.equivalentForRebase(step.snapshot), !exists(step.source) else { throw LocalTransferFailure(.changed) }
                try moveExclusive(step.destination, to: step.source)
            }
        } catch {
            throw LocalTransferFailure(.recoveryRequired, recoveryLocations: [roots.destination] + (roots.source.map { [$0] } ?? []))
        }
    }
    private static func snapshotForRecord(_ url: URL, expected: LocalTransferSnapshot) throws -> LocalTransferSnapshot {
        let current = try snapshot(url, control: LocalTransferControl())
        guard current.equivalentForRebase(expected) else { throw LocalTransferFailure(.changed) }
        return current
    }
    static func publish(source: LocalTransferSource, destination: URL, original: LocalTransferSnapshot?,
                        roots: LocalTransferRoots, move moving: Bool, hasRemaining: Bool,
                        control: LocalTransferControl, hooks: LocalTransferHooks) throws -> LocalTransferAction {
        try control.checkpoint()
        try source.parent.validate()
        let parent = try LocalTransferParent(destination.deletingLastPathComponent())
        try requireSnapshot(source.url, source.snapshot, control: control)
        try requireSnapshot(destination, original, control: control)
        let sourceBackup = roots.source?.appendingPathComponent("original")
        let destinationBackup = original == nil ? nil : roots.destination.appendingPathComponent("original")
        let stage = roots.destination.appendingPathComponent("output")
        let stageContents = try snapshot(stage, control: control)
        let remainingURL = roots.source?.appendingPathComponent("remaining")
        let remaining = hasRemaining ? try remainingURL.map { try snapshot($0, control: control) } : nil
        var log: [RenameStep] = []
        do {
            if let destinationBackup, let original { try move(destination, to: destinationBackup, expected: original, log: &log, hooks: hooks) }
            try move(stage, to: destination, expected: stageContents, log: &log, hooks: hooks)
            if moving, let sourceBackup {
                try source.parent.validate()
                // Rename the original only after the entire copy has been published successfully.
                try requireSnapshot(source.url, source.snapshot, control: control)
                try move(source.url, to: sourceBackup, expected: source.snapshot, log: &log, hooks: hooks)
                if let remainingURL, let remaining { try move(remainingURL, to: source.url, expected: remaining, log: &log, hooks: hooks) }
            }
            hooks.beforeRecord?(destination) // Record only the verified committed contents, even if Cancel just arrived.
            return LocalTransferAction(source: source.url, destination: destination, destinationParent: parent,
                sourceParent: source.parent, roots: roots, destinationBackup: destinationBackup, sourceBackup: sourceBackup, directMove: false,
                output: try snapshotForRecord(destination, expected: stageContents),
                originalDestination: try destinationBackup.flatMap { url in try original.map { try snapshotForRecord(url, expected: $0) } },
                originalSource: try sourceBackup.map { try snapshotForRecord($0, expected: source.snapshot) },
                remainingSource: moving ? try remaining.map { try snapshotForRecord(source.url, expected: $0) } : nil)
        } catch {
            try rollback(log, roots: roots)
            throw error
        }
    }
    static func publishDirect(source: LocalTransferSource, destination: URL, original: LocalTransferSnapshot?,
                              roots: LocalTransferRoots, control: LocalTransferControl, hooks: LocalTransferHooks) throws -> LocalTransferAction {
        try control.checkpoint(); try source.parent.validate()
        let parent = try LocalTransferParent(destination.deletingLastPathComponent())
        try requireSnapshot(source.url, source.snapshot, control: control)
        try requireSnapshot(destination, original, control: control)
        let backup = original == nil ? nil : roots.destination.appendingPathComponent("original")
        var log: [RenameStep] = []
        do {
            if let backup, let original { try move(destination, to: backup, expected: original, log: &log, hooks: hooks) }
            try move(source.url, to: destination, expected: source.snapshot, log: &log, hooks: hooks)
            hooks.beforeRecord?(destination)
            return LocalTransferAction(source: source.url, destination: destination, destinationParent: parent,
                sourceParent: source.parent, roots: roots, destinationBackup: backup, sourceBackup: nil, directMove: true,
                output: try snapshotForRecord(destination, expected: source.snapshot),
                originalDestination: try backup.flatMap { url in try original.map { try snapshotForRecord(url, expected: $0) } }, originalSource: nil, remainingSource: nil)
        } catch { try rollback(log, roots: roots); throw error }
    }
    static func validateUndo(_ actions: [LocalTransferAction], control: LocalTransferControl) throws {
        struct Location { let snapshot: LocalTransferSnapshot? }
        var projected: [URL: Location] = [:]
        func check(_ url: URL, _ expected: LocalTransferSnapshot?) throws {
            if let later = projected[url] {
                switch (later.snapshot, expected) {
                case (nil, nil): return
                case (.some(let left), .some(let right)) where left.equivalentForRebase(right): return
                default: throw LocalTransferFailure(.changed)
                }
            }
            try requireSnapshot(url, expected, control: control)
        }
        for action in actions.reversed() {
            try control.checkpoint()
            try action.destinationParent.validate()
            try action.sourceParent.validate()
            try check(action.destination, action.output)
            if let backup = action.destinationBackup { try requireSnapshot(backup, action.originalDestination, control: control) }
            if let backup = action.sourceBackup {
                try requireSnapshot(backup, action.originalSource, control: control)
                try check(action.source, action.remainingSource)
                projected[action.source] = Location(snapshot: action.originalSource)
            } else if action.directMove {
                try check(action.source, nil)
                projected[action.source] = Location(snapshot: action.output)
            }
            projected[action.destination] = Location(snapshot: action.originalDestination)
        }
    }
    static func undo(_ action: LocalTransferAction, control: LocalTransferControl, hooks: LocalTransferHooks) throws {
        try validateUndo([action], control: control)
        var log: [RenameStep] = []
        do {
            if action.directMove {
                try move(action.destination, to: action.source, expected: action.output, log: &log, hooks: hooks)
            } else {
                try move(action.destination, to: action.roots.destination.appendingPathComponent("undo-output"), expected: action.output, log: &log, hooks: hooks)
            }
            if let backup = action.destinationBackup, let original = action.originalDestination {
                try move(backup, to: action.destination, expected: original, log: &log, hooks: hooks)
            }
            if let backup = action.sourceBackup, let sourceRoot = action.roots.source {
                if let remaining = action.remainingSource { try move(action.source, to: sourceRoot.appendingPathComponent("undo-remaining"), expected: remaining, log: &log, hooks: hooks) }
                if let original = action.originalSource { try move(backup, to: action.source, expected: original, log: &log, hooks: hooks) }
            }
            for step in log { _ = try snapshotForRecord(step.destination, expected: step.snapshot) }
        } catch {
            try rollback(log, roots: action.roots)
            throw error
        }
        removeRoots(action.roots)
    }
    static func rebased(_ records: [LocalTransferRecord]) -> [LocalTransferRecord] {
        let control = LocalTransferControl()
        func rebase(_ expected: LocalTransferSnapshot, _ url: URL) -> LocalTransferSnapshot {
            guard let current = try? snapshot(url, control: control), current.equivalentForRebase(expected) else { return expected }
            return current
        }
        return records.map { record in
            var record = record
            record.actions = record.actions.map { action in
                var action = action
                action.output = rebase(action.output, action.destination)
                if let snapshot = action.originalDestination, let url = action.destinationBackup { action.originalDestination = rebase(snapshot, url) }
                if let snapshot = action.originalSource, let url = action.sourceBackup { action.originalSource = rebase(snapshot, url) }
                if let snapshot = action.remainingSource { action.remainingSource = rebase(snapshot, action.source) }
                return action
            }
            return record
        }
    }
    static func discard(_ record: LocalTransferRecord, retaining retained: Set<String>) {
        for action in record.actions {
            // Only remove known journal entries; keep any unexpectedly modified recovery material.
            let control = LocalTransferControl()
            if let sourceRoot = action.roots.source, !retained.contains(sourceRoot.standardizedFileURL.path) {
                let expected = action.sourceBackup?.lastPathComponent
                if let names = try? FileManager.default.contentsOfDirectory(atPath: sourceRoot.path),
                   Set(names) == Set((expected.map { [$0] } ?? []) + [LocalTransferRecovery.markerName]),
                   (try? action.sourceBackup.map { try snapshot($0, control: control) }) == action.originalSource {
                    try? FileManager.default.removeItem(at: sourceRoot)
                }
            }
            let expected = action.destinationBackup?.lastPathComponent
            if retained.contains(action.roots.destination.standardizedFileURL.path) { continue }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: action.roots.destination.path),
               Set(names) == Set((expected.map { [$0] } ?? []) + [LocalTransferRecovery.markerName]),
               (try? action.destinationBackup.map { try snapshot($0, control: control) }) == action.originalDestination {
                try? FileManager.default.removeItem(at: action.roots.destination)
            }
        }
    }
}

private final class LocalTransferTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var items = 0
    let total: Int
    let totalBytes: Int64
    let progress: (@Sendable (StorageTransferProgress) -> Void)?
    let control: LocalTransferControl
    init(snapshots: [LocalTransferSnapshot], progress: (@Sendable (StorageTransferProgress) -> Void)?, control: LocalTransferControl) {
        total = snapshots.reduce(0) { $0 + $1.entries.count }
        totalBytes = snapshots.reduce(0) { $0 + $1.bytes }
        self.progress = progress; self.control = control
    }
    func report(bytes delta: Int64 = 0, items count: Int = 0, source: URL?, destination: URL?) {
        lock.lock()
        bytes += max(0, delta); items += count
        let value = StorageTransferProgress(completedItems: items, totalItems: total, currentSource: source,
            currentDestination: destination, bytesCompleted: bytes, totalBytes: totalBytes)
        lock.unlock()
        progress?(value)
    }
    func finish(_ snapshot: LocalTransferSnapshot) { report(bytes: snapshot.bytes, items: snapshot.entries.count, source: nil, destination: nil) }
    func finishDirectory(_ source: URL, destination: URL) { report(items: 1, source: source, destination: destination) }
}
private final class LocalTransferCopyContext {
    let control: LocalTransferControl
    let tracker: LocalTransferTracker?
    let source: URL
    let destination: URL
    private var last: Int64 = 0
    init(control: LocalTransferControl, tracker: LocalTransferTracker?, source: URL, destination: URL) {
        self.control = control; self.tracker = tracker; self.source = source; self.destination = destination
    }
    func report(_ bytes: Int64) {
        let delta = max(0, bytes - last); last = max(last, bytes)
        tracker?.report(bytes: delta, source: source, destination: destination)
    }
}

// Restore to another volume using the same content and metadata verification as a normal local move.
// Publish the verified copy exclusively before touching the original Trash item.
extension LocalTransferService {
    static func restoreAcrossVolumes(source: URL, target: URL, parent: Int32, removeOriginal: () throws -> Void) throws {
        let control = LocalTransferControl()
        let original = try LocalTransferFS.snapshot(source, control: control)
        let fm = FileManager.default
        let temporary = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: target.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: temporary) }
        let copy = temporary.appendingPathComponent("restored")
        try LocalTransferFS.copyTree(source, to: copy, control: control)
        let copied = try LocalTransferFS.snapshot(copy, control: control)
        guard original.samePayload(copied) else { throw LocalTransferFailure(.copyVerificationFailed) }
        try LocalTransferFS.requireSnapshot(source, original, control: control)
        guard renameatx_np(AT_FDCWD, copy.path, parent, target.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw LocalTransferFailure(errno == EEXIST || errno == ENOTEMPTY ? .conflict : .io)
        }
        do {
            try LocalTransferFS.requireSnapshot(source, original, control: control)
            try removeOriginal()
        } catch { throw LocalTransferFailure(.recoveryRequired, recoveryLocations: [target]) }
    }

    static func restoredName(_ proposed: URL, directory: Bool) throws -> URL {
        try LocalTransferFS.availableName(proposed, directory: directory)
    }
}
