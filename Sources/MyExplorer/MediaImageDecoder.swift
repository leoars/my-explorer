// SPDX-License-Identifier: Apache-2.0
import Foundation
import ImageIO
import Darwin
import ExplorerCore

/// ImageIO synchronous decoding cannot be interrupted. Actor isolation serializes all decodes,
/// including an obsolete request still finishing after navigation canceled its task.
actor MediaImageDecoder {
    static let shared = MediaImageDecoder()
    private static let maxNativePixels = 64_000_000
    private static let maxNativeEdge = 16_384
    private static let previewEdge = 4_096

    func prepare(url: URL, kind: MediaKind, availability: @Sendable (URL) -> MediaFileAvailability = { MediaFileAccess.availability(of: $0) }) -> MediaViewerPreparation? {
        guard !Task.isCancelled else { return nil }
        do {
            try Task.checkCancellation()
            let resolvedURL: URL
            switch availability(url) {
            case .available(let resolved): resolvedURL = resolved
            case .needsDownload:
                return MediaViewerPreparation(image: nil, resolvedURL: url, sourcePixelSize: .zero,
                    nativeResolutionAvailable: false, needsDownload: true)
            case .unavailable: return nil
            }
            guard !Task.isCancelled else { return nil }
            if kind != .image { return MediaViewerPreparation(image: nil, resolvedURL: resolvedURL, sourcePixelSize: .zero, nativeResolutionAvailable: false, needsDownload: false) }
            return autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(resolvedURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let widthValue = metadata[kCGImagePropertyPixelWidth] as? NSNumber,
                      let heightValue = metadata[kCGImagePropertyPixelHeight] as? NSNumber,
                      !Task.isCancelled else { return nil }
                let width = widthValue.doubleValue
                let height = heightValue.doubleValue
                guard width.isFinite, height.isFinite, width >= 1, height >= 1,
                      width.rounded(.down) == width, height.rounded(.down) == height,
                      width <= Double(Int32.max), height <= Double(Int32.max) else { return nil }
                let orientation = (metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                guard (1...8).contains(orientation) else { return nil }
                let swapsAxes = (5...8).contains(orientation)
                let sourceSize = CGSize(width: swapsAxes ? height : width, height: swapsAxes ? width : height)
                let allowsNative = width <= Double(Self.maxNativeEdge) && height <= Double(Self.maxNativeEdge)
                    && width * height <= Double(Self.maxNativePixels)
                let maximumEdge = allowsNative ? Int(max(width, height)) : Self.previewEdge
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldAllowFloat: false,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard !Task.isCancelled,
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      !Task.isCancelled else { return nil }
                let nativeAvailable = allowsNative && image.width == Int(sourceSize.width) && image.height == Int(sourceSize.height)
                return MediaViewerPreparation(image: image, resolvedURL: resolvedURL,
                    sourcePixelSize: sourceSize, nativeResolutionAvailable: nativeAvailable, needsDownload: false)
            }
        } catch { return nil }
    }
}

/// Immutable image pixels and value metadata cross from the decoder actor to the UI.
struct MediaViewerPreparation: @unchecked Sendable {
    let image: CGImage?
    let resolvedURL: URL
    let sourcePixelSize: CGSize
    let nativeResolutionAvailable: Bool
    let needsDownload: Bool
}
