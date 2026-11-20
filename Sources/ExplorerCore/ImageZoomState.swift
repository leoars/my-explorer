// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

public enum ImageZoomMode: Equatable, Sendable {
    case fit, manual
}

/// Image geometry independent of its decoder and scroll view.
/// A scale factor of 1 displays one original image pixel per physical screen pixel.
public struct ImageZoomState: Equatable, Sendable {
    public static let minimumManualScale: CGFloat = 0.01
    public static let maximumManualScale: CGFloat = 8
    public static let zoomStep: CGFloat = 1.25

    public private(set) var pixelSize: CGSize
    public private(set) var backingScale: CGFloat
    public private(set) var viewportSize: CGSize
    public private(set) var mode: ImageZoomMode = .fit
    public private(set) var scaleFactor: CGFloat = 1

    public var displayedSize: CGSize {
        CGSize(width: Self.finiteDimension(pixelSize.width / backingScale * scaleFactor),
               height: Self.finiteDimension(pixelSize.height / backingScale * scaleFactor))
    }

    public init(pixelSize: CGSize, backingScale: CGFloat = 1, viewportSize: CGSize) {
        self.pixelSize = Self.validSize(pixelSize)
        self.backingScale = Self.validScale(backingScale)
        self.viewportSize = Self.validSize(viewportSize)
        fit()
    }

    /// Fits the viewport, allowing enlargement up to the same 800% limit as manual zoom.
    /// This may go below the manual minimum so even very large images can fit.
    public mutating func fit() {
        mode = .fit
        scaleFactor = max(CGFloat.leastNonzeroMagnitude, min(Self.maximumManualScale,
            viewportSize.width / pixelSize.width * backingScale,
            viewportSize.height / pixelSize.height * backingScale))
    }

    public mutating func actualSize() { setZoom(1) }
    public mutating func zoomIn() { setZoom(scaleFactor * Self.zoomStep) }
    public mutating func zoomOut() {
        // Fit can be below the manual minimum; reducing zoom must never enlarge that image.
        guard scaleFactor > Self.minimumManualScale else { return }
        setZoom(scaleFactor / Self.zoomStep)
    }

    /// Manual zoom is clamped to 1–800%. Invalid values leave the current state unchanged.
    public mutating func setZoom(_ scaleFactor: CGFloat) {
        guard scaleFactor.isFinite, scaleFactor > 0 else { return }
        mode = .manual
        self.scaleFactor = min(Self.maximumManualScale, max(Self.minimumManualScale, scaleFactor))
    }

    public mutating func updateViewport(_ size: CGSize) {
        viewportSize = Self.validSize(size)
        if mode == .fit { fit() }
    }

    public mutating func updateBackingScale(_ scale: CGFloat) {
        backingScale = Self.validScale(scale)
        if mode == .fit { fit() }
    }

    private static func validSize(_ size: CGSize) -> CGSize {
        CGSize(width: validDimension(size.width), height: validDimension(size.height))
    }
    private static func validDimension(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
    private static func validScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value >= 1 ? value : 1
    }
    private static func finiteDimension(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : CGFloat.greatestFiniteMagnitude
    }
}
