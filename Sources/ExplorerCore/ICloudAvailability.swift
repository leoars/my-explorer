// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum ICloudAvailability: String, Sendable {
    case onlineOnly, available, downloading, uploading, waiting, conflict, failed, unknown

    static let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadRequestedKey,
        .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey]

    init(_ values: URLResourceValues) {
        if values.ubiquitousItemHasUnresolvedConflicts == true { self = .conflict }
        else if values.ubiquitousItemDownloadingError != nil || values.ubiquitousItemUploadingError != nil { self = .failed }
        else if values.ubiquitousItemIsDownloading == true { self = .downloading }
        else if values.ubiquitousItemIsUploading == true { self = .uploading }
        else if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            self = values.ubiquitousItemDownloadRequested == true ? .waiting : .onlineOnly
        } else if values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded {
            self = values.ubiquitousItemIsUploaded == false ? .waiting : .available
        } else { self = .unknown }
    }

    /// Above this many items a listing does not ask iCloud about each one (about a millisecond and
    /// a half apiece, which made a folder of tens of thousands of items time out): it only tells
    /// what is on this Mac from what is not, which the file system answers at once.
    static let detailedListingLimit = 1_000

    /// The coarse state of an item of an iCloud folder, from the file system alone.
    static func coarse(at url: URL) -> ICloudAvailability {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .unknown }
        return info.st_flags & UInt32(SF_DATALESS) != 0 ? .onlineOnly : .available
    }

    static func canRemoveDownload(_ values: URLResourceValues) -> Bool {
        Self(values) == .available && values.ubiquitousItemIsUploaded == true && values.isDirectory == false
    }

    /// The current state of one item, read fresh from the file system; nil when it is not in iCloud.
    public static func current(at url: URL) -> ICloudAvailability? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: keys.union([.isUbiquitousItemKey])),
              values.isUbiquitousItem == true else { return nil }
        return Self(values)
    }

    /// Whether the item's content is on this Mac, whatever else its state says (a conflict, an
    /// upload in progress); nil when it is not in iCloud.
    public static func isDownloaded(at url: URL) -> Bool? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return nil }
        return values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded
    }

    public enum Operation: Sendable { case download, removeDownload }
    public static func request(_ operation: Operation, at url: URL) throws {
        try DirectoryReader.validateLocalURL(url)
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: keys.union([.isUbiquitousItemKey, .isSymbolicLinkKey, .isDirectoryKey]))
        guard values.isUbiquitousItem == true, values.isSymbolicLink != true,
              !LocalTransferRecovery.isProtected(url), !SecureFolderService.isVault(url), !SecureFolderService.isSessionURL(url) else { throw CocoaError(.fileWriteNoPermission) }
        switch operation {
        case .download: try FileManager.default.startDownloadingUbiquitousItem(at: url)
        case .removeDownload:
            guard canRemoveDownload(values) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.evictUbiquitousItem(at: url)
        }
    }
}
