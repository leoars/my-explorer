// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CRemovefile
import CryptoKit

public struct TrashEntry: Sendable {
    public let location: URL
    public let original: URL?
    public var name: String { original?.lastPathComponent ?? location.lastPathComponent }
    fileprivate let parent: TrashIdentity
    fileprivate let identity: TrashIdentity
    fileprivate let origin: TrashRestoreOrigin?
}

public struct TrashInventory: Sendable {
    public let entries: [TrashEntry]
    public let readableRoots: [URL]
    /// Includes directories where enumeration was denied, even if exact receipts still work.
    public let unreadable: [URL]
}

public actor TrashLibrary {
    public static let shared = TrashLibrary(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MyExplorer/TrashOrigins", isDirectory: true),
        roots: systemRoots)
    private let directory: URL
    private let roots: @Sendable () -> [URL]

    init(directory: URL, roots: @escaping @Sendable () -> [URL]) {
        self.directory = directory
        self.roots = roots
    }

    // Ask Foundation for this user's Trash on each local volume. Never create a Trash while browsing.
    private static func systemRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var result = [home.appendingPathComponent(".Trash", isDirectory: true)]
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            guard (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true,
                  let root = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: volume, create: false) else { continue }
            result.append(root)
        }
        return result
    }

    private func receiptFile(_ location: URL) -> URL {
        let digest = SHA256.hash(data: Data(location.standardizedFileURL.path.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    func record(_ item: TrashedItem) throws {
        // Never persist the decrypted paths of a private, transient vault mount.
        guard !SecureFolderService.isSessionURL(item.origin.url) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(item).write(to: receiptFile(item.location), options: .atomic)
    }

    public func inventory() throws -> TrashInventory {
        let fm = FileManager.default
        let receipts: [URL]
        do { receipts = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { receipts = [] }
        var known: [String: TrashedItem] = [:]
        for file in receipts where file.pathExtension == "json" {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: file), let item = try? JSONDecoder().decode(TrashedItem.self, from: data),
               item.location.isFileURL, item.origin.url.isFileURL, file.lastPathComponent == receiptFile(item.location).lastPathComponent {
                known[item.location.standardizedFileURL.path] = item
            }
        }
        var entries: [TrashEntry] = [], unreadable: [URL] = [], readableRoots: [URL] = []
        var seen: Set<String> = []
        for root in roots() {
            try Task.checkCancellation()
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            var parentInfo = stat()
            guard lstat(root.path, &parentInfo) == 0 else {
                if errno != ENOENT { unreadable.append(root) }
                continue
            }
            guard parentInfo.st_mode & S_IFMT == S_IFDIR, parentInfo.st_uid == getuid() else { unreadable.append(root); continue }
            let receiptsHere = known.values.filter { $0.location.deletingLastPathComponent().standardizedFileURL.path == path }
            let urls: [URL]
            do {
                urls = try fm.contentsOfDirectory(atPath: path).map { root.appendingPathComponent($0) }
                readableRoots.append(root)
                let present = Set(urls.map { $0.standardizedFileURL.path })
                for item in receiptsHere where !present.contains(item.location.standardizedFileURL.path) {
                    try? fm.removeItem(at: receiptFile(item.location))
                }
            } catch {
                unreadable.append(root)
                urls = receiptsHere.map(\.location)
            }
            for url in urls where ![".DS_Store", ".localized"].contains(url.lastPathComponent) {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(url.path, &info) == 0 else {
                    if errno != ENOENT && !unreadable.contains(root) { unreadable.append(root) }
                    continue
                }
                let identity = TrashIdentity(info)
                let item = known[url.standardizedFileURL.path]
                let origin = item?.origin.item == identity ? item?.origin : nil
                entries.append(.init(location: url, original: origin?.url, parent: TrashIdentity(parentInfo), identity: identity, origin: origin))
            }
        }
        return TrashInventory(entries: entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                              readableRoots: readableRoots, unreadable: unreadable)
    }

    private func validate(_ entry: TrashEntry) throws {
        let root = entry.location.deletingLastPathComponent().standardizedFileURL.path
        guard roots().contains(where: { $0.standardizedFileURL.path == root }) else { throw LocalTransferFailure(.trashUnavailable) }
        var parent = stat(), item = stat()
        guard lstat(root, &parent) == 0, TrashIdentity(parent) == entry.parent,
              lstat(entry.location.path, &item) == 0, TrashIdentity(item) == entry.identity else {
            throw LocalTransferFailure(.trashUnavailable)
        }
    }

    public func restore(_ entry: TrashEntry, into directory: URL?, keepBoth: Bool) throws -> URL {
        try validate(entry)
        guard let targetFolder = directory ?? entry.original?.deletingLastPathComponent() else {
            throw LocalTransferFailure(.invalidDestination)
        }
        try DirectoryReader.validateLocalURL(targetFolder)
        let folder = targetFolder.resolvingSymlinksInPath().standardizedFileURL
        guard DirectoryReader.enclosingVault(folder) == nil, !LocalTransferRecovery.isProtected(folder),
              !roots().contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }),
              !folder.path.hasPrefix(entry.location.path + "/") else { throw LocalTransferFailure(.invalidDestination) }
        let parent = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalTransferFailure(.invalidDestination) }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, directory != nil || TrashIdentity(info) == entry.origin?.parent else {
            throw LocalTransferFailure(.changed)
        }
        let proposed = folder.appendingPathComponent(entry.name)
        let target = keepBoth ? try LocalTransferService.restoredName(proposed, directory: entry.identity.type == S_IFDIR) : proposed
        try Task.checkCancellation()
        if renameatx_np(AT_FDCWD, entry.location.path, parent, target.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EXDEV else { throw LocalTransferFailure(errno == EEXIST || errno == ENOTEMPTY ? .conflict : .io) }
            try LocalTransferService.restoreAcrossVolumes(source: entry.location, target: target, parent: parent) {
                try self.erase(entry)
            }
        }
        try? FileManager.default.removeItem(at: receiptFile(entry.location))
        return target
    }

    public func erase(_ entry: TrashEntry) throws {
        try Task.checkCancellation()
        try validate(entry)
        let parent = open(entry.location.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalTransferFailure(.io) }
        defer { close(parent) }
        var parentInfo = stat(), itemInfo = stat()
        let name = entry.location.lastPathComponent
        guard fstat(parent, &parentInfo) == 0, TrashIdentity(parentInfo) == entry.parent,
              fstatat(parent, name, &itemInfo, AT_SYMLINK_NOFOLLOW) == 0, TrashIdentity(itemInfo) == entry.identity else {
            throw LocalTransferFailure(.changed)
        }
        // Recursive mode never follows symbolic links or crosses mount points without an explicit flag.
        guard explorer_remove_tree_at(parent, name) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? FileManager.default.removeItem(at: receiptFile(entry.location))
    }
}
