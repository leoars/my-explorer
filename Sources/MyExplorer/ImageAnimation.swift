// SPDX-License-Identifier: Apache-2.0
import AppKit
import ImageIO

/// Plays an animated image file (WebP, GIF, APNG, HEICS) frame by frame, at the pace the file
/// sets, for as long as it is kept: WhatsApp stickers, for one, are animated WebP. ImageIO decodes
/// one frame at a time, so a long animation does not sit whole in memory.
/// https://developer.apple.com/documentation/imageio/cganimateimageaturlwithblock(_:_:_:)
@MainActor
final class ImageAnimation {
    /// Frames larger than this on a side are left as a still picture.
    nonisolated static let maximumSide = 4_096

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
    private let stopped = Flag()

    /// Whether the file holds more than one frame of a size worth animating. Reads the file's
    /// header: not for the main thread.
    nonisolated static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return max(width, height) <= maximumSide
    }

    /// Starts playing, in a loop; nil when ImageIO cannot animate the file. `frame` is called on
    /// the main thread for every frame until `stop()`.
    init?(url: URL, frame: @escaping @MainActor (CGImage) -> Void) {
        let stopped = stopped
        let options = [kCGImageAnimationLoopCount: kCFNumberPositiveInfinity as Any] as CFDictionary
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, options) { _, image, stop in
            if stopped.isSet { stop.pointee = true; return }
            let box = FrameBox(image)
            if Thread.isMainThread { MainActor.assumeIsolated { frame(box.image) } }
            else { DispatchQueue.main.async { if !stopped.isSet { frame(box.image) } } }
        }
        guard status == noErr else { return nil }
    }

    private struct FrameBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func stop() { stopped.set() }
    deinit { stopped.set() }
}
