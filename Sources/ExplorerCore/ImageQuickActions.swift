// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

public enum ImageQuickAction: String, CaseIterable, Sendable {
    case rotate, jpeg, png, pdf

    public var outputType: UTType {
        switch self { case .rotate, .png: .png; case .jpeg: .jpeg; case .pdf: .pdf }
    }

    public func supports(_ entries: [FileEntry]) -> Bool {
        guard !entries.isEmpty, entries.count <= 100, self == .pdf || entries.count == 1 else { return false }
        return entries.allSatisfy {
            $0.url.isFileURL && !$0.isDirectory && !$0.isAlias && !$0.isSymbolicLink
            && !SecureFolderService.isSessionURL($0.url)
            && $0.iCloudAvailability != .onlineOnly && $0.iCloudAvailability != .downloading
            && Self.extensions.contains($0.url.pathExtension.lowercased())
        }
    }

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"]

    /// Publish exclusively after the entire output is written. User source files are never replaced.
    public func export(_ sources: [URL], to destination: URL) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try write(sources, to: destination)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func write(_ sources: [URL], to destination: URL) throws {
        guard !sources.isEmpty, sources.count <= 100, self == .pdf || sources.count == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        try DirectoryReader.validateLocalURL(destination)
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard !LocalTransferRecovery.isProtected(destination), DirectoryReader.enclosingVault(parent) == nil,
              UTType(filenameExtension: destination.pathExtension.lowercased()) == outputType else { throw CocoaError(.fileWriteInvalidFileName) }
        var st = stat()
        guard lstat(destination.path, &st) != 0 && errno == ENOENT else { throw CocoaError(.fileWriteFileExists) }
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: dir) }
        let temp = dir.appendingPathComponent(destination.lastPathComponent)
        switch self {
        case .pdf:
            guard let pdf = CGContext(temp as CFURL, mediaBox: nil, nil) else { throw CocoaError(.fileWriteUnknown) }
            for url in sources {
                try autoreleasepool {
                    let image = try Self.read(url)
                    var page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    pdf.beginPage(mediaBox: &page)
                    pdf.draw(image, in: page)
                    pdf.endPage()
                }
            }
            pdf.closePDF()
        case .rotate, .jpeg, .png:
            var image = try Self.read(sources[0])
            if self == .rotate {
                let color = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
                guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { throw CocoaError(.fileWriteUnknown) }
                context.translateBy(x: 0, y: CGFloat(image.width))
                context.rotate(by: -.pi / 2)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let rotated = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
                image = rotated
            }
            guard let writer = CGImageDestinationCreateWithURL(temp as CFURL, outputType.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        }
        try Task.checkCancellation()
        guard renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func read(_ url: URL) throws -> CGImage {
        try Task.checkCancellation()
        guard !SecureFolderService.isSessionURL(url),
              case .available(let path) = MediaFileAccess.availability(of: url),
              !SecureFolderService.isSessionURL(path), DirectoryReader.enclosingVault(path) == nil,
              let src = CGImageSourceCreateWithURL(path as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
              (1...16384).contains(w), (1...16384).contains(h), w * h <= 64_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w,h), kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return image
    }
}
