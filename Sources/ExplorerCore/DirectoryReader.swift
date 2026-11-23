// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct FileEntry: Identifiable, Equatable, Sendable {
    public var id: String { url.explorerIdentity }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let secureFolderURL: URL?
    public let isSymbolicLink: Bool
    public let isAlias: Bool
    public let size: Int64?
    public let modified: Date?
    public let canRemoveICloudDownload: Bool
    public let iCloudAvailability: ICloudAvailability?
    public let kind: String
    public var canNavigate: Bool { isDirectory && !isPackage && secureFolderURL == nil }

    public init(url: URL, name: String, isDirectory: Bool, isPackage: Bool = false,
                isSymbolicLink: Bool = false, isAlias: Bool = false, size: Int64? = nil, modified: Date? = nil,
                kind: String = "File", secureFolderURL: URL? = nil, iCloudAvailability: ICloudAvailability? = nil,
                canRemoveICloudDownload: Bool = false) {
        self.canRemoveICloudDownload = canRemoveICloudDownload
        self.iCloudAvailability = iCloudAvailability
        self.url = url; self.name = name; self.isDirectory = isDirectory
        self.secureFolderURL = secureFolderURL ?? (isDirectory && SecureFolderService.isVault(url) ? url : nil)
        self.isPackage = isPackage; self.isSymbolicLink = isSymbolicLink; self.isAlias = isAlias
        self.size = size; self.modified = modified; self.kind = kind
    }

    /// This entry under a new name in the same folder, as it stands right after a rename and
    /// before the folder is read again.
    public func renamed(to newName: String) -> FileEntry {
        let plainFile = !isDirectory && !isPackage && !isSymbolicLink
        let ext = (newName as NSString).pathExtension
        return FileEntry(url: url.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: isDirectory),
                         name: newName, isDirectory: isDirectory, isPackage: isPackage, isSymbolicLink: isSymbolicLink,
                         isAlias: isAlias, size: size, modified: modified,
                         kind: plainFile ? (ext.isEmpty ? "File" : ext.uppercased()) : kind,
                         secureFolderURL: secureFolderURL == url ? nil : secureFolderURL,
                         iCloudAvailability: iCloudAvailability, canRemoveICloudDownload: canRemoveICloudDownload)
    }
}

public protocol DirectoryReading: Sendable {
    func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry]
}

public struct DirectoryReader: DirectoryReading {
    /// Sidebar discovery must not consume the active pane's filesystem workers.
    public enum Purpose: Sendable { case foreground, background }
    private let executor: DirectoryReadExecutor
    private let beforeEnumeration: (@Sendable (URL) -> Void)?
    public init() { self.init(purpose: .foreground) }
    public init(purpose: Purpose) {
        executor = purpose == .foreground ? .foreground : .background
        beforeEnumeration = nil
    }
    internal init(purpose: Purpose, beforeEnumeration: @escaping @Sendable (URL) -> Void) {
        executor = purpose == .foreground ? .foreground : .background
        self.beforeEnumeration = beforeEnumeration
    }
    internal init(executor: DirectoryReadExecutor, beforeEnumeration: (@Sendable (URL) -> Void)? = nil) {
        self.executor = executor; self.beforeEnumeration = beforeEnumeration
    }

    public func entries(at url: URL, showHidden: Bool) async throws -> [FileEntry] {
        try Task.checkCancellation()
        try Self.validateLocalURL(url)
        let before = beforeEnumeration
        return try await executor.run { request in
            try request.checkCancellation()
            before?(url)
            try request.checkCancellation()
            return try Self.enumerate(url, showHidden: showHidden, request: request)
        }
    }

    internal static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == nil || components.host == "" || components.host == "localhost",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let path = components.percentEncodedPath.removingPercentEncoding, !path.utf8.contains(0) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    private static func enumerate(_ url: URL, showHidden: Bool, request: DirectoryReadRequest) throws -> [FileEntry] {
        guard !LocalTransferRecovery.isProtected(url) else { throw CocoaError(.fileReadNoPermission) }
        // Foundation's URL-based enumeration can reject a directory symlink with
        // ENOTDIR (including /Volumes/Macintosh HD -> /). Resolve only the read
        // location, on this bounded worker; retain the user's path below for
        // entry identity, breadcrumbs, Back and Up. Mutation policies are separate.
        let directoryURL = url.resolvingSymlinksInPath()
        guard Self.enclosingVault(directoryURL) == nil, Self.enclosingVault(url) == nil,
              !LocalTransferRecovery.isProtected(directoryURL) else { throw CocoaError(.fileReadNoPermission) }
        try request.checkCancellation()
        // Whether the folder is in iCloud is asked once, of the folder: asking each item costs a
        // fifth of a millisecond, eleven seconds for fifty thousand of them.
        let inICloud = (try? directoryURL.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
            .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles])
        var entries: [FileEntry] = []
        entries.reserveCapacity(urls.count)
        let detailedICloud = inICloud && urls.count <= ICloudAvailability.detailedListingLimit
        for file in urls {
            try request.checkCancellation()
            // A disappearing or inaccessible child must not discard the whole directory.
            let values = try? file.resourceValues(forKeys: keys)
            let symbolic = values?.isSymbolicLink == true
            // This location and its ancestors were checked above; a link leads elsewhere and is
            // checked in full, anything else only for a mark of its own.
            if symbolic || values == nil { guard !LocalTransferRecovery.isProtected(file) else { continue } }
            else if values?.isDirectory == true { guard !LocalTransferRecovery.isMarkedDirectory(file) else { continue } }
            let resolvedFile = symbolic ? file.resolvingSymlinksInPath() : file
            let target = symbolic ? try? resolvedFile.resourceValues(
                forKeys: [.isDirectoryKey, .isPackageKey]) : values
            let directory = target?.isDirectory == true
            // Treat a link to the package as a vault even when the link has a different name.
            let vault = symbolic ? Self.enclosingVault(resolvedFile) :
                (directory && SecureFolderService.isVault(file) ? file : nil)
            let package = target?.isPackage == true || vault != nil
            // Stable classification only; presentation localizes type names at render time.
            let kind = symbolic ? "Symbolic link" : (directory && !package ? "Folder" :
                (package ? "Package" : file.pathExtension.isEmpty ? "File" : file.pathExtension.uppercased()))
            // Foundation may enumerate /tmp as /private/tmp. Preserve the navigated path
            // so selection and Up use the same identity, including directory symlinks.
            let displayedURL = url.appendingPathComponent(file.lastPathComponent, isDirectory: directory)
            var iCloud: ICloudAvailability?
            var removable = false
            if inICloud && !symbolic {
                if detailedICloud {
                    let metadata = try? file.resourceValues(forKeys: ICloudAvailability.keys.union([.isDirectoryKey]))
                    iCloud = metadata.map(ICloudAvailability.init) ?? .unknown
                    removable = metadata.map(ICloudAvailability.canRemoveDownload) ?? false
                } else {
                    // Removing a download is checked again, in full, when it is asked for.
                    let state = ICloudAvailability.coarse(at: file)
                    iCloud = state
                    removable = state == .available && !directory
                }
            }
            entries.append(FileEntry(url: displayedURL, name: file.lastPathComponent,
                isDirectory: directory, isPackage: package, isSymbolicLink: symbolic, isAlias: values?.isAliasFile == true,
                size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate,
                kind: kind, secureFolderURL: symbolic ? vault : nil, iCloudAvailability: iCloud, canRemoveICloudDownload: removable))
        }
        return EntryOrdering.sorted(entries)
    }

    static func enclosingVault(_ url: URL) -> URL? {
        var item = url.standardizedFileURL
        while item.pathComponents.count > 1 {
            if SecureFolderService.isVault(item) { return item }
            item.deleteLastPathComponent()
        }
        return nil
    }
}

/// Blocking filesystem calls must never occupy Swift's cooperative executor. A mount can
/// ignore cancellation inside open(); its slot remains occupied until that actual call exits.
internal final class DirectoryReadExecutor: @unchecked Sendable {
    static let foreground = DirectoryReadExecutor()
    static let background = DirectoryReadExecutor(concurrency: 2, maximumPending: 16)
    private let queue: OperationQueue
    private let lock = NSLock()
    private var pending = 0
    private let maximumPending: Int
    private let timeout: TimeInterval
    init(concurrency: Int = 4, maximumPending: Int = 32, timeout: TimeInterval = 30) {
        queue = OperationQueue()
        queue.name = "MyExplorer.DirectoryRead"
        queue.maxConcurrentOperationCount = max(1, concurrency)
        queue.qualityOfService = .userInitiated
        self.maximumPending = max(1, maximumPending)
        self.timeout = max(0.01, timeout)
    }

    func run(_ operation: @escaping @Sendable (DirectoryReadRequest) throws -> [FileEntry]) async throws -> [FileEntry] {
        let request = DirectoryReadRequest()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                guard !request.isCancelled else { return }
                let admitted = lock.withLock {
                    guard pending < maximumPending else { return false }
                    pending += 1
                    return true
                }
                guard admitted else { request.finish(.failure(POSIXError(.EBUSY))); return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    request.cancel(POSIXError(.ETIMEDOUT))
                }
                queue.addOperation { [self] in
                    defer { lock.withLock { pending -= 1 } }
                    do {
                        try request.checkCancellation()
                        let entries = try operation(request)
                        try request.checkCancellation()
                        request.finish(.success(entries))
                    } catch { request.finish(.failure(error)) }
                }
            }
        } onCancel: { request.cancel(CancellationError()) }
        try Task.checkCancellation()
        return result
    }
}

/// One-shot continuation completion lets cancellation/deadlines release the awaiting UI
/// immediately without pretending a blocked kernel call or its worker has been terminated.
internal final class DirectoryReadRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[FileEntry], any Error>?
    private var earlyResult: Result<[FileEntry], any Error>?
    private var finished = false
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    func install(_ continuation: CheckedContinuation<[FileEntry], any Error>) {
        let ready = lock.withLock {
            if finished { defer { earlyResult = nil }; return earlyResult }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }
    func finish(_ result: Result<[FileEntry], any Error>) { complete(result, cancelling: false) }
    func cancel(_ error: any Error) { complete(.failure(error), cancelling: true) }
    private func complete(_ result: Result<[FileEntry], any Error>, cancelling: Bool) {
        let waiting = lock.withLock {
            guard !finished else { return nil as CheckedContinuation<[FileEntry], any Error>? }
            finished = true
            cancelled = cancelling
            let waiting = continuation
            continuation = nil
            if waiting == nil { earlyResult = result }
            return waiting
        }
        waiting?.resume(with: result)
    }
}

public enum EntrySortKey: String, Sendable { case name, modified, kind, size }

public enum EntryOrdering {
    public static func sorted(_ entries: [FileEntry], by key: EntrySortKey = .name,
                              ascending: Bool = true, kindName: ((FileEntry) -> String)? = nil) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            // Folders remain first, including when a column is sorted descending.
            if lhs.canNavigate != rhs.canNavigate { return lhs.canNavigate }
            let comparison: ComparisonResult
            switch key {
            case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .kind: comparison = (kindName?(lhs) ?? lhs.kind).localizedStandardCompare(kindName?(rhs) ?? rhs.kind)
            case .modified: comparison = (lhs.modified ?? .distantPast).compare(rhs.modified ?? .distantPast)
            case .size:
                let a = lhs.size ?? -1, b = rhs.size ?? -1
                comparison = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            }
            if comparison == .orderedSame {
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder == .orderedSame { return lhs.id < rhs.id }
                return nameOrder == .orderedAscending
            }
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        }
    }
}
