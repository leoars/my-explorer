// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerCore
import Darwin

public struct SharedFileFailure: Error, Sendable {
    public let reason: AutomationError
    public let completed: [URL]
    public init(_ reason: AutomationError, completed: [URL]) { self.reason = reason; self.completed = completed }
}

/// Earlier files in this drag have already moved when a later file fails.
public struct S3MoveBatchFailure: Error, Sendable {
    public let completed: [URL]
    public let cause: any Error
}

/// One gate is shared by copies of the facade, including its GUI and broker owners.
/// Reentrant mutation requests fail explicitly instead of waiting behind an unknown job.
public actor SharedOperationGate {
    private var occupied = false
    public init() {}
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !occupied else { throw AutomationError.busy }
        occupied = true
        defer { occupied = false }
        return try await operation()
    }
}

/// The GUI and automation broker share this facade; adapters never construct cloud credentials.
public struct SharedFileOperations: Sendable {
    public typealias Authorization = @Sendable (URL, URL, Bool) async throws -> Void
    public let clientFactory: @Sendable (UUID) async throws -> CloudStorageClient
    private let gate = SharedOperationGate()
    private let localTransfers = LocalTransferService()
    private let ocrReader: any OCRReading
    private let searchablePDFWriter: any SearchablePDFWriting
    private let searchablePDFBatchWriter: any SearchablePDFBatchWriting
    public init(clientFactory: @escaping @Sendable (UUID) async throws -> CloudStorageClient,
                ocrReader: any OCRReading = OCRService(),
                searchablePDFWriter: any SearchablePDFWriting = SearchablePDFService(),
                searchablePDFBatchWriter: any SearchablePDFBatchWriting = SearchablePDFBatchService()) {
        self.clientFactory = clientFactory; self.ocrReader = ocrReader; self.searchablePDFWriter = searchablePDFWriter
        self.searchablePDFBatchWriter = searchablePDFBatchWriter
    }
    /// Holds the mutation gate for the entire sequential batch, including partial receipts.
    public func searchablePDFBatch(_ request: SearchablePDFBatchRequest,
                                  progress: (@Sendable (SearchablePDFBatchProgress) -> Void)? = nil,
                                  authorizeSource: (@Sendable (URL) async throws -> Void)? = nil,
                                  authorizeDestination: (@Sendable (URL) async throws -> Void)? = nil) async throws -> SearchablePDFBatchResult {
        try await gate.run {
            guard (1...50).contains(request.sourceURLs.count) else { throw AutomationError.invalidArguments }
            let hasAuthorization = authorizeSource != nil || authorizeDestination != nil
            for source in request.sourceURLs {
                _ = try AutomationOCRLocation.normalized(source)
                try await authorizeSource?(source)
            }
            _ = try AutomationOCRLocation.normalized(request.destinationDirectoryURL)
            try await authorizeDestination?(request.destinationDirectoryURL)
            // Resolve metadata on the bounded core executor, then authorize that exact directory.
            // A short symlink must not bypass either scope or the aggregate wire-result budget.
            let probe = request.destinationDirectoryURL.appendingPathComponent(".my-explorer-batch-budget-\(UUID()).pdf")
            let resolvedDirectory = try await SearchablePDFService.validatedDestinationURL(probe).deletingLastPathComponent()
            try await authorizeDestination?(resolvedDirectory)
            if hasAuthorization { try Self.validatePDFBatchMetadataBudget(request, resolvedDirectory: resolvedDirectory) }
            return try await self.searchablePDFBatchWriter.exportBatch(request, progress: progress, authorize: { url, role in
                switch role {
                case .source: try await authorizeSource?(url)
                case .destination:
                    try await authorizeDestination?(url)
                    // Recheck after scope authorization for every concrete destination. Treating
                    // the entire URL as a directory deliberately overestimates a file callback.
                    // This also closes a symlink-target change between the two preflights.
                    if hasAuthorization { try Self.validatePDFBatchMetadataBudget(request, resolvedDirectory: url) }
                }
            })
        }
    }
    private static func validatePDFBatchMetadataBudget(_ request: SearchablePDFBatchRequest, resolvedDirectory: URL) throws {
        // Every platform filename is at most 255 bytes. Its URL encoding can occupy three
        // characters per byte. Include both output copies (item and receipt) plus generous
        // fixed metadata, then reserve space for the job and MCP's duplicated JSON envelope.
        let directories = [request.destinationDirectoryURL.absoluteString, resolvedDirectory.absoluteString]
        let directory = directories.max(by: { $0.utf8.count < $1.utf8.count }) ?? ""
        let target = directory + "/" + String(repeating: "%FF", count: 255)
        let items = request.sourceURLs.map { source in
            JSONValue.object(["sourceURL": .string(source.absoluteString), "destinationURL": .string(target),
                "state": .string("succeeded"), "reason": .string("publicationIndeterminate"),
                "receipt": .object(["destinationURL": .string(target), "pageCount": .number(100),
                    "recognizedPages": .number(100), "textLayerPages": .number(100), "engine": .string("apple-vision")])])
        }
        let estimate = try AutomationWire.encode(JSONValue.object(["items": .array(items)])).count
        guard estimate <= AutomationWire.maximumMessageBytes / 8 - 16_384 else { throw AutomationError.limitExceeded }
    }
    /// Creates one new searchable PDF. A confirmed publication remains authoritative even if
    /// cancellation or revocation arrives immediately afterwards; never reinterpret it as rollback.
    public func searchablePDF(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)? = nil,
                              authorizeSource: (@Sendable (URL) async throws -> Void)? = nil,
                              authorizeDestination: (@Sendable (URL) async throws -> Void)? = nil) async throws -> SearchablePDFResult {
        try await gate.run {
            _ = try AutomationOCRLocation.normalized(request.sourceURL)
            _ = try AutomationOCRLocation.normalized(request.destinationURL)
            if authorizeSource == nil && authorizeDestination == nil {
                return try await self.searchablePDFWriter.export(request, progress: progress, authorize: nil)
            }
            try await authorizeSource?(request.sourceURL)
            try await authorizeDestination?(request.destinationURL)
            let source = try await OCRService.materializedURL(request.sourceURL)
            let destination = try await SearchablePDFService.validatedDestinationURL(request.destinationURL)
            try await authorizeSource?(source)
            try await authorizeDestination?(destination)
            try Task.checkCancellation()
            return try await self.searchablePDFWriter.export(request, progress: progress, authorize: { url, role in
                switch role {
                case .source: try await authorizeSource?(url)
                case .destination: try await authorizeDestination?(url)
                }
            })
        }
    }
    /// Local read-only OCR; cloud connections never participate in this operation.
    public func ocr(_ request: OCRRequest, progress: (@Sendable (OCRProgress) -> Void)? = nil,
                    authorizeURL: (@Sendable (URL) async throws -> Void)? = nil) async throws -> OCRResult {
        let url = request.url
        try Self.validateOCRURL(url)
        try await authorizeURL?(url)
        let resolved = try await Self.ocrMaterializedLocation(url)
        try await authorizeURL?(resolved)
        try Task.checkCancellation()
        let result = try await ocrReader.recognize(request, progress: progress, authorizeURL: authorizeURL)
        try Task.checkCancellation()
        try await authorizeURL?(url)
        let current = try await Self.ocrMaterializedLocation(url)
        guard current == resolved else { throw AutomationError.changedPlan }
        try await authorizeURL?(current)
        try Task.checkCancellation()
        return result
    }
    public func ocrLanguages() async throws -> [String] { try await ocrReader.supportedLanguages() }
    public func validateOCRAccess(_ url: URL, authorizeURL: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        try Self.validateOCRURL(url)
        try await authorizeURL(url)
        let resolved = try await Self.ocrMaterializedLocation(url)
        try await authorizeURL(resolved)
        try Task.checkCancellation()
        return resolved
    }
    private static func validateOCRURL(_ url: URL) throws {
        _ = try AutomationOCRLocation.normalized(url)
    }
    private static func ocrMaterializedLocation(_ url: URL) async throws -> URL {
        try await OCRService.materializedURL(url)
    }
    public func list(_ url: URL, hidden: Bool = false) async throws -> [FileEntry] {
        if url.isFileURL { return try await DirectoryReader().entries(at: url, showHidden: hidden) }
        guard let location = RemoteLocation.parse(url) else { throw AutomationError.invalidArguments }
        guard AutomationGrant.safeKey(location.key) else { throw AutomationError.invalidArguments }
        let prefix = location.key.isEmpty || location.key.hasSuffix("/") ? location.key : location.key + "/"
        let client = try await clientFactory(location.connectionID)
        var token: String?, seen = Set<String>(), entries: [FileEntry] = [], keys = Set<String>(), pages = 0
        repeat {
            try Task.checkCancellation()
            pages += 1
            guard pages <= 10_001 else { throw AutomationError.limitExceeded }
            let page = try await client.list(prefix: prefix, continuationToken: token)
            for object in page.objects where object.key != prefix {
                guard AutomationGrant.safeKey(object.key), object.key.hasPrefix(prefix) else { throw AutomationError.invalidArguments }
                let relative = String(object.key.dropFirst(prefix.count))
                let name = object.isDirectory && relative.hasSuffix("/") ? String(relative.dropLast()) : relative
                guard !name.isEmpty, !name.contains("/") else { throw AutomationError.invalidArguments }
                guard keys.insert(object.key).inserted else { continue }
                guard keys.count <= 10_000 else { throw AutomationError.limitExceeded }
                let url = RemoteLocation.url(connectionID: location.connectionID, key: object.key)
                if hidden || !url.lastPathComponent.hasPrefix(".") {
                    entries.append(FileEntry(url: url, name: url.lastPathComponent, isDirectory: object.isDirectory, size: object.size, modified: object.modified))
                }
            }
            token = page.nextToken
            if let token, !seen.insert(token).inserted { throw AutomationError.io }
            guard entries.count <= 10_000 else { throw AutomationError.limitExceeded }
        } while token != nil
        return EntryOrdering.sorted(entries)
    }
    public func copy(_ sources: [URL], to destination: URL,
                     resolveConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                     progress: (@Sendable (StorageTransferProgress) -> Void)? = nil,
                     authorize: Authorization? = nil) async throws -> [URL] {
        try await gate.run {
            try await self.copyUnlocked(sources, to: destination, resolveConflict: resolveConflict, progress: progress, authorize: authorize)
        }
    }
    private func copyUnlocked(_ sources: [URL], to destination: URL,
                              resolveConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                              progress: (@Sendable (StorageTransferProgress) -> Void)?,
                              authorize: Authorization?) async throws -> [URL] {
        if destination.isFileURL && sources.allSatisfy(\.isFileURL) {
            guard !LocalTransferRecovery.isProtected(destination) else { throw AutomationError.forbidden }
            // Stage each top-level item, then re-authorize immediately before publishing it.
            var completed: [URL] = []
            for source in sources {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                let staging = destination.appendingPathComponent(".my-explorer-agent-\(UUID().uuidString)", isDirectory: true)
                do {
                    try Task.checkCancellation()
                    try await authorize?(source, target, false)
                    let inventory = authorize == nil ? nil : try Self.inventory(source)
                    if let inventory, let authorize {
                        for name in inventory.keys.sorted() {
                            try await authorize(Self.child(source, name), Self.child(target, name), false)
                        }
                    }
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let copied = try await FileMutationService().transfer([source], to: staging, move: false)
                    try Task.checkCancellation()
                    if let inventory, let authorize {
                        guard try Self.inventory(source) == inventory else { throw AutomationError.changedPlan }
                        let staged = try Self.inventory(copied[0])
                        guard staged.mapValues(\.contents) == inventory.mapValues(\.contents) else { throw AutomationError.changedPlan }
                        for name in inventory.keys.sorted() {
                            try await authorize(Self.child(source, name), Self.child(target, name), false)
                        }
                    }
                    try await authorize?(source, target, false)
                    _ = try await FileMutationService().transfer(copied, to: destination, move: true)
                    completed.append(target)
                } catch {
                    let reason: AutomationError
                    if Task.isCancelled || error is CancellationError { reason = .cancelled }
                    else if let value = error as? AutomationError { reason = value }
                    else if let value = error as? FileMutationFailure {
                        switch value.reason {
                        case .conflict: reason = .conflict
                        case .cancelled: reason = .cancelled
                        case .invalidName, .recursive: reason = .invalidArguments
                        case .io: reason = .io
                        }
                    } else { reason = .io }
                    throw SharedFileFailure(reason, completed: completed)
                }
            }
            return completed
        }
        return try await StorageTransferService(clientFactory: clientFactory).copy(sources: sources, to: destination,
            resolveConflict: resolveConflict, progress: progress, authorize: authorize)
    }
    private static func child(_ root: URL, _ relative: String) -> URL {
        relative.isEmpty ? root : root.appendingPathComponent(relative)
    }
    private static func inventory(_ root: URL) throws -> [String: CopyIdentity] {
        var values: [String: CopyIdentity] = [:]
        func walk(_ url: URL, _ relative: String, _ depth: Int) throws {
            try Task.checkCancellation()
            guard !LocalTransferRecovery.isProtected(url) else { throw AutomationError.forbidden }
            guard depth <= 64, values.count < 10_000 else { throw AutomationError.limitExceeded }
            var info = Darwin.stat()
            guard lstat(url.path, &info) == 0 else { throw AutomationError.changedPlan }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { throw AutomationError.forbidden }
            values[relative] = CopyIdentity(info)
            if type == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try walk(url.appendingPathComponent(name), relative.isEmpty ? name : relative + "/" + name, depth + 1)
                }
            }
        }
        try walk(root, "", 0)
        return values
    }
    public func move(_ urls: [URL], to destination: URL) async throws -> [URL] {
        try await gate.run { try await FileMutationService().transfer(urls, to: destination, move: true) }
    }
    private static func s3MovePlan(_ sources: [URL], to destination: URL) throws -> (id: UUID, prefix: String, keys: [String]) {
        guard !sources.isEmpty, let target = RemoteLocation.parse(destination) else { throw CloudFailure(.invalidConfiguration) }
        var destinations = Set<Data>()
        let keys = try sources.map { url in
            guard let source = RemoteLocation.parse(url), source.connectionID == target.connectionID else { throw CloudFailure(.invalidConfiguration) }
            let key = try CloudStorageClient.s3MoveDestination(key: source.key, into: target.key)
            guard destinations.insert(Data(key.utf8)).inserted else { throw CloudFailure(.conflict) }
            return source.key
        }
        return (target.connectionID, target.key, keys)
    }

    public static func canMoveS3Files(_ sources: [URL], to destination: URL) -> Bool {
        (try? s3MovePlan(sources, to: destination)) != nil
    }

    public func moveS3Files(_ sources: [URL], to destination: URL) async throws -> [URL] {
        try await gate.run {
            let plan = try Self.s3MovePlan(sources, to: destination)
            let client = try await self.clientFactory(plan.id)
            guard client.connection.provider == .s3, client.connection.id == plan.id else { throw CloudFailure(.invalidConfiguration) }
            var completed: [URL] = []
            for key in plan.keys {
                do {
                    try Task.checkCancellation()
                    let moved = try await client.moveS3File(key: key, into: plan.prefix)
                    completed.append(RemoteLocation.url(connectionID: plan.id, key: moved.key))
                } catch {
                    if completed.isEmpty { throw error }
                    throw S3MoveBatchFailure(completed: completed, cause: error)
                }
            }
            return completed
        }
    }

    /// Interactive local transfers share the same mutation gate as cloud and automation operations.
    public func transferLocal(_ sources: [URL], to destination: URL, move: Bool,
                              resolveConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice,
                              progress: (@Sendable (StorageTransferProgress) -> Void)? = nil,
                              control: LocalTransferControl = LocalTransferControl()) async throws -> [URL] {
        try await gate.run {
            try await self.localTransfers.transfer(sources: sources, to: destination, move: move,
                resolveConflict: resolveConflict, progress: progress, control: control)
        }
    }
    public func localUndoKind() async -> LocalTransferKind? { await localTransfers.undoKind }
    public func undoLocal(resolveTrashConflict: @escaping @Sendable (StorageConflict) async -> StorageConflictChoice = { _ in .cancel },
                          progress: (@Sendable (StorageTransferProgress) -> Void)? = nil,
                          control: LocalTransferControl = LocalTransferControl()) async throws -> [URL] {
        try await gate.run { try await self.localTransfers.undo(resolveTrashConflict: resolveTrashConflict, progress: progress, control: control) }
    }
    public func restoreTrashItem(_ entry: TrashEntry, into folder: URL?, keepBoth: Bool = false) async throws -> URL {
        try await gate.run {
            let url = try await TrashLibrary.shared.restore(entry, into: folder, keepBoth: keepBoth)
            await localTransfers.forgetTrash(location: entry.location)
            return url
        }
    }

    public func eraseTrashItem(_ entry: TrashEntry) async throws {
        try await gate.run {
            try await TrashLibrary.shared.erase(entry)
            await localTransfers.forgetTrash(location: entry.location)
        }
    }

    public func clearLocalTransferHistory() async {
        // Called after in-flight jobs have stopped during orderly application shutdown.
        await localTransfers.clearHistory()
    }
    public func rename(_ url: URL, to name: String) async throws -> URL {
        try await gate.run { try await FileMutationService().rename(url, to: name) }
    }
    public func newFolder(in url: URL, name: String) async throws -> URL {
        try await gate.run {
            if let location = RemoteLocation.parse(url) {
                let client = try await self.clientFactory(location.connectionID)
                let key = try await client.createS3Folder(prefix: location.key, name: name)
                return RemoteLocation.url(connectionID: location.connectionID, key: key)
            }
            return try await FileMutationService().newFolder(in: url, name: name)
        }
    }
    public func trash(_ urls: [URL]) async throws -> [URL] {
        try await gate.run { try await FileMutationService().trash(urls) }
    }
    public func compress(_ urls: [URL], to url: URL) async throws -> URL {
        try await gate.run { try await ArchiveService().compress(urls: urls, to: url) }
    }
    public func extract(_ url: URL, to destination: URL) async throws -> URL {
        try await gate.run { try await ArchiveService().extract(archiveURL: url, to: destination) }
    }
    public func executeDeletion(planID: UUID, using service: StorageDeletionService, recordUndo: Bool = false,
                                authorizationCheck: @escaping @Sendable (URL) async -> Bool) async throws -> StorageDeletionResult {
        try await gate.run { try await service.execute(planID: planID, undoHistory: recordUndo ? self.localTransfers : nil, authorizationCheck: authorizationCheck) }
    }
}

private struct CopyIdentity: Equatable {
    let identity: String
    let contents: String
    init(_ info: Darwin.stat) {
        let type = info.st_mode & S_IFMT
        identity = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        contents = "\(type):\(type == S_IFREG ? info.st_size : 0)"
    }
}
