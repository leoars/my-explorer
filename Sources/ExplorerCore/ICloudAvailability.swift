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

    static func canRemoveDownload(_ values: URLResourceValues) -> Bool {
        Self(values) == .available && values.ubiquitousItemIsUploaded == true && values.isDirectory == false
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
