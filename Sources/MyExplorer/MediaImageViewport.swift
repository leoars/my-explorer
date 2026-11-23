// SPDX-License-Identifier: Apache-2.0
import AppKit

/// Scrollable image document. Scroll wheels and drag gestures pan; the canvas retains file-navigation focus.
@MainActor
final class MediaImageViewport: NSScrollView {
    let imageView = NSImageView()
    private let imageDocument = MediaImageDocument()
    var viewportChanged: (() -> Void)?
    var imageClicked: (() -> Void)?
    var magnified: ((CGFloat) -> Void)?
    private var previousViewportSize = NSSize.zero
    private var renderedViewportSize = NSSize.zero
    private var updatingLayout = false
    var renderedSize: NSSize { imageView.frame.size }
    var viewportSize: NSSize { contentView.bounds.size }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityIdentifier("explorer.media.image")
        imageDocument.addSubview(imageView)
        documentView = imageDocument
        imageDocument.focusNavigation = { [weak self] in self?.imageClicked?() }
        imageDocument.pan = { [weak self] delta in
            guard let self else { return }
            let origin = self.contentView.bounds.origin
            self.contentView.scroll(to: self.clampedOrigin(NSPoint(x: origin.x - delta.x, y: origin.y + delta.y)))
            self.reflectScrolledClipView(self.contentView)
        }
        setAccessibilityIdentifier("explorer.media.imageViewport")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        let size = viewportSize
        guard size != previousViewportSize, !updatingLayout else { return }
        previousViewportSize = size
        viewportChanged?()
    }

    /// Control (or Command) with the wheel zooms, as in Windows; the wheel alone pans.
    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .control || modifiers == .command else { super.scrollWheel(with: event); return }
        let delta = event.scrollingDeltaY
        guard delta != 0, imageView.image != nil else { return }
        imageClicked?()
        // A wheel notch is a clear step; a trackpad sends many small ones.
        magnified?(event.hasPreciseScrollingDeltas ? delta * 0.01 : (delta > 0 ? 0.15 : -0.15))
    }

    override func magnify(with event: NSEvent) {
        imageClicked?()
        magnified?(event.magnification)
    }

    func clearImage() {
        imageView.image = nil
        imageView.frame = .zero
        renderedViewportSize = .zero
        imageDocument.frame = NSRect(origin: .zero, size: viewportSize)
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    func render(size: NSSize, preserveCenter: Bool) {
        guard !updatingLayout else { return }
        updatingLayout = true
        defer { updatingLayout = false }
        let oldFrame = imageView.frame
        let visible = contentView.bounds
        let oldViewport = renderedViewportSize.width > 0 && renderedViewportSize.height > 0 ? renderedViewportSize : visible.size
        let center = preserveCenter && oldFrame.width > 0 && oldFrame.height > 0
            ? NSPoint(x: (visible.minX + oldViewport.width / 2 - oldFrame.minX) / oldFrame.width,
                      y: (visible.minY + oldViewport.height / 2 - oldFrame.minY) / oldFrame.height)
            : NSPoint(x: 0.5, y: 0.5)
        let viewport = viewportSize
        let documentSize = NSSize(width: max(viewport.width, size.width), height: max(viewport.height, size.height))
        imageDocument.setFrameSize(documentSize)
        imageView.frame = NSRect(x: aligned((documentSize.width - size.width) / 2),
                                 y: aligned((documentSize.height - size.height) / 2),
                                 width: size.width, height: size.height)
        let origin = NSPoint(x: imageView.frame.minX + center.x * size.width - viewport.width / 2,
                             y: imageView.frame.minY + center.y * size.height - viewport.height / 2)
        contentView.scroll(to: clampedOrigin(origin))
        reflectScrolledClipView(contentView)
        renderedViewportSize = viewport
    }

    private func aligned(_ value: CGFloat) -> CGFloat {
        let scale = max(1, window?.backingScaleFactor ?? 1)
        return (value * scale).rounded() / scale
    }

    private func clampedOrigin(_ origin: NSPoint) -> NSPoint {
        NSPoint(x: aligned(min(max(0, origin.x), max(0, imageDocument.bounds.width - viewportSize.width))),
                y: aligned(min(max(0, origin.y), max(0, imageDocument.bounds.height - viewportSize.height))))
    }
}

@MainActor
private final class MediaImageDocument: NSView {
    var focusNavigation: (() -> Void)?
    var pan: ((NSPoint) -> Void)?
    private var lastDragPoint: NSPoint?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        focusNavigation?()
        lastDragPoint = event.locationInWindow
    }
    override func mouseDragged(with event: NSEvent) {
        guard let lastDragPoint else { return }
        let point = event.locationInWindow
        pan?(NSPoint(x: point.x - lastDragPoint.x, y: point.y - lastDragPoint.y))
        self.lastDragPoint = point
    }
    override func mouseUp(with event: NSEvent) { lastDragPoint = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
