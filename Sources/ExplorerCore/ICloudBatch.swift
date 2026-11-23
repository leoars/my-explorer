// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One file to bring down from iCloud, with the room it will take on this Mac.
public struct ICloudBatchItem: Equatable, Sendable {
    public let url: URL
    public let size: Int64
    public init(url: URL, size: Int64) { self.url = url; self.size = size }
}

/// Downloading many iCloud items at once: what there is to download, and the disk space that
/// must be left alone while doing it.
public enum ICloudBatch {
    /// Above this many files the person is asked before anything starts.
    public static let confirmationThreshold = 50

    public struct Volume: Equatable, Sendable {
        public let available: Int64
        public let total: Int64
        public init(available: Int64, total: Int64) { self.available = available; self.total = total }
        /// The free space that downloads never eat into: five percent of the disk.
        public var reserve: Int64 { max(0, total / 20) }
        /// Whether this many more bytes can arrive and still leave the reserve free.
        public func fits(_ size: Int64) -> Bool { available - max(0, size) >= reserve }
    }

    /// The space of the volume that holds `url`, as the system reports it at this moment.
    public static func volume(at url: URL) -> Volume? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey]), let total = values.volumeTotalCapacity else { return nil }
        // The figure "for important usage" counts space the system would still have to purge.
        // The reserve is kept against what is really free: the smaller of the two.
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        return Volume(available: important > 0 ? min(plain, important) : plain, total: Int64(total))
    }

    public static func totalSize(_ items: [ICloudBatchItem]) -> Int64 { items.reduce(0) { $0 + max(0, $1.size) } }

    /// How many items, from the first on, can be downloaded without touching the reserve.
    public static func countThatFits(_ items: [ICloudBatchItem], in volume: Volume) -> Int {
        var used: Int64 = 0, count = 0
        for item in items {
            used += max(0, item.size)
            guard volume.fits(used) else { break }
            count += 1
        }
        return count
    }

    /// A file of the listing whose content is not on this Mac.
    public static func isPending(_ entry: FileEntry) -> Bool {
        entry.url.isFileURL && !entry.isDirectory && !entry.isSymbolicLink && entry.secureFolderURL == nil
            && (entry.iCloudAvailability == .onlineOnly || entry.iCloudAvailability == .failed)
    }

    /// A folder of the listing that is in iCloud and may hold content that is not on this Mac.
    public static func isFolder(_ entry: FileEntry) -> Bool {
        entry.url.isFileURL && entry.isDirectory && !entry.isPackage && !entry.isSymbolicLink
            && entry.secureFolderURL == nil && entry.iCloudAvailability != nil
    }

    /// A document kept as a package (a folder shown as one file): downloaded whole, never asked about.
    public static func isPackage(_ entry: FileEntry) -> Bool {
        entry.url.isFileURL && entry.isDirectory && entry.isPackage && !entry.isSymbolicLink
            && entry.secureFolderURL == nil && entry.iCloudAvailability != nil
    }

    /// Whether the entry gives a batch something to do or to ask about.
    public static func concerns(_ entry: FileEntry) -> Bool { isPending(entry) || isFolder(entry) || isPackage(entry) }

    /// The size of an item as the file system has it now; nil when it cannot be read.
    public static func currentSize(of url: URL) -> Int64? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    /// What to download for these entries, in their order; a folder, when included, stands for
    /// everything under it that is not on this Mac. Reads the disk: not for the main thread.
    public static func plan(_ entries: [FileEntry], includingFolders: Bool,
                            isCancelled: () -> Bool = { Task.isCancelled }) -> [ICloudBatchItem] {
        var items: [ICloudBatchItem] = []
        var seen: Set<String> = []
        for entry in entries {
            if isCancelled() { return [] }
            if isPending(entry) {
                if seen.insert(entry.url.path).inserted { items.append(ICloudBatchItem(url: entry.url, size: entry.size ?? 0)) }
            } else if isPackage(entry) || (includingFolders && isFolder(entry)) {
                for item in pending(under: entry.url, isCancelled: isCancelled) where seen.insert(item.url.path).inserted {
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Every file under a folder whose content is not on this Mac, in path order. The file system
    /// alone tells (the `SF_DATALESS` mark), so nothing is downloaded by looking.
    public static func pending(under folder: URL, isCancelled: () -> Bool = { Task.isCancelled }) -> [ICloudBatchItem] {
        guard !LocalTransferRecovery.isProtected(folder), !SecureFolderService.isVault(folder),
              let enumerator = FileManager.default.enumerator(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var items: [ICloudBatchItem] = []
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { return [] }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]) else { continue }
            if values.isDirectory == true {
                if SecureFolderService.isVault(url) || LocalTransferRecovery.isMarkedDirectory(url) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, ICloudAvailability.coarse(at: url) == .onlineOnly else { continue }
            items.append(ICloudBatchItem(url: url, size: Int64(values.fileSize ?? 0)))
        }
        return items.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}
