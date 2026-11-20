// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import Darwin
import ExplorerCore

struct PreviewThumbnail: @unchecked Sendable {
    let image: CGImage
}

enum PreviewPreparation: Sendable {
    case image(PreviewThumbnail), quickLook(URL), needsDownload, unavailable
}

/// One image decoder and a bounded LRU cache shared by rebuilt preview panes.
/// No file contents are read before the local-availability check.
actor PreviewImageLoader {
    static let shared = PreviewImageLoader()
    private struct Key: Hashable {
        let url: URL
        let edge: Int
        let size: Int64
        let device: Int32
        let inode: UInt64
        let modified: Int64
        let modifiedNanos: Int64
        let changed: Int64
        let changedNanos: Int64
    }
    private struct Cached {
        let key: Key
        let thumbnail: PreviewThumbnail
        let cost: Int
    }
    private var cache: [Cached] = []
    private var cacheCost = 0
    var cachedByteCount: Int { cacheCost }
    var cachedItemCount: Int { cache.count }
    private let fileAccess: @Sendable (URL, Bool) -> MediaFileAvailability

    init(fileAccess: @escaping @Sendable (URL, Bool) -> MediaFileAvailability = { MediaFileAccess.availability(of: $0, isAlias: $1) }) {
        self.fileAccess = fileAccess
    }
    private let maximumCost = 32 * 1024 * 1024
    private(set) var decodeCount = 0

    func prepare(_ entry: FileEntry, image: Bool, maximumEdge: Int) -> PreviewPreparation {
        guard !Task.isCancelled else { return .unavailable }
        let url: URL
        switch fileAccess(entry.url, entry.isAlias) {
        case .available(let resolvedURL): url = resolvedURL
        case .needsDownload: return .needsDownload
        case .unavailable: return .unavailable
        }
        guard !Task.isCancelled else { return .unavailable }
        let sensitive = SecureFolderService.isSessionURL(url)
        guard image else { return sensitive ? .unavailable : .quickLook(url) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .unavailable }
        let edge = min(1600, max(320, maximumEdge))
        let key = Key(url: url, edge: edge, size: info.st_size, device: info.st_dev, inode: info.st_ino,
                      modified: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                      changed: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            return .image(hit.thumbnail)
        }
        return autoreleasepool {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  !Task.isCancelled else { return .unavailable }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false
            ]
            decodeCount += 1
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  !Task.isCancelled else { return .unavailable }
            let thumbnail = PreviewThumbnail(image: decoded)
            let cost = decoded.bytesPerRow * decoded.height
            if !sensitive && cost <= maximumCost {
                while cacheCost + cost > maximumCost || cache.count >= 32 {
                    cacheCost -= cache.removeFirst().cost
                }
                cache.append(Cached(key: key, thumbnail: thumbnail, cost: cost))
                cacheCost += cost
            }
            return .image(thumbnail)
        }
    }
}
