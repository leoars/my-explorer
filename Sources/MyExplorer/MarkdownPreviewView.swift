// SPDX-License-Identifier: Apache-2.0
import AppKit
import ImageIO
import ExplorerCore

/// Copies and drags only plain text: what is selected in a preview is the document's words,
/// not its layout.
final class MarkdownTextView: NSTextView {
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

/// A picture from the document's folder, scaled down to fit the pane.
final class MarkdownImageAttachment: NSTextAttachment {
    var naturalSize: CGSize = .zero

    func fit(width: CGFloat) {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return }
        let scale = min(1, max(16, width) / naturalSize.width, 900 / naturalSize.height)
        bounds = CGRect(x: 0, y: 0, width: floor(naturalSize.width * scale), height: floor(naturalSize.height * scale))
    }
}

/// A Markdown file in the preview pane, formatted or as its source. Links act only when clicked:
/// web and mail links open in their app, links inside the document scroll to their target, and a
/// link to a file on this Mac shows it in My Explorer. Nothing in the document is run, and no
/// image is fetched from the network.
@MainActor
final class MarkdownPreviewView: NSView, NSTextViewDelegate {
    enum Mode: Int { case formatted, source }

    var onRevealFile: ((URL) -> Void)?
    private let scrollView = NSScrollView()
    private let formattedView: MarkdownTextView
    private var sourceView: MarkdownTextView?
    private let sourceText: String
    private let style: MarkdownRenderStyle
    private var imageTask: Task<Void, Never>?
    private var fittedWidth: CGFloat = 0
    private(set) var mode: Mode = .formatted
    private(set) var loadedImageCount = 0
    private(set) var imagesSettled = false

    /// Pictures are read only from this Mac, and only so many and so large.
    nonisolated static let imageCountLimit = 64
    nonisolated static let imageFileLimit: Int64 = 25 * 1024 * 1024
    nonisolated static let decodedImageBudget = 96 * 1024 * 1024

    init(formatted: NSAttributedString, source: String, style: MarkdownRenderStyle, mode: Mode, width: CGFloat) {
        sourceText = source
        self.style = style
        formattedView = Self.makeTextView()
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, 120), height: 400))
        scrollView.frame = bounds
        formattedView.delegate = self
        formattedView.textStorage?.setAttributedString(formatted)
        formattedView.setAccessibilityIdentifier("explorer.preview.markdown")
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setMode(mode)
        loadImages()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeTextView() -> MarkdownTextView {
        // TextKit 1 lays out tables and blocks (NSTextTable, NSTextBlock).
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.drawsBackground = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.textContainerInset = NSSize(width: 8, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        return view
    }

    var displayedText: String { (mode == .formatted ? formattedView : sourceView ?? formattedView).string }
    var formattedStorage: NSTextStorage? { formattedView.textStorage }

    func setMode(_ mode: Mode) {
        self.mode = mode
        let view: MarkdownTextView
        switch mode {
        case .formatted:
            view = formattedView
        case .source:
            if let sourceView { view = sourceView } else {
                let created = Self.makeTextView()
                created.delegate = self
                created.textStorage?.setAttributedString(MarkdownRenderer.source(sourceText, style: style))
                created.setAccessibilityIdentifier("explorer.preview.markdown.source")
                sourceView = created
                view = created
            }
        }
        guard scrollView.documentView !== view else { return }
        view.frame = NSRect(origin: .zero, size: NSSize(width: max(scrollView.contentSize.width, bounds.width, 120), height: 1))
        scrollView.documentView = view
        view.scroll(.zero)
    }

    func tearDown() {
        imageTask?.cancel(); imageTask = nil
        formattedView.delegate = nil
        sourceView?.delegate = nil
        scrollView.documentView = nil
        sourceView = nil
        removeFromSuperview()
    }

    /// Room for a picture, less the insets and some indentation for lists and quotes.
    private var availableImageWidth: CGFloat {
        max(80, scrollView.contentSize.width - formattedView.textContainerInset.width * 2 - 40)
    }

    override func layout() {
        super.layout()
        // The text view is created before the pane has a size; it follows the visible width.
        let contentWidth = scrollView.contentSize.width
        if let document = scrollView.documentView, contentWidth > 0, abs(document.frame.width - contentWidth) > 0.5 {
            document.setFrameSize(NSSize(width: contentWidth, height: max(document.frame.height, 1)))
            (document as? NSTextView)?.sizeToFit()
        }
        let width = availableImageWidth
        guard loadedImageCount > 0, abs(width - fittedWidth) > 1, let storage = formattedView.textStorage else { return }
        fittedWidth = width
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            (value as? MarkdownImageAttachment)?.fit(width: width)
        }
        formattedView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
    }

    // MARK: - Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Whatever is not one of this document's links is never opened.
        guard let link = link as? MarkdownLink else { NSSound.beep(); return true }
        if !activate(link) { NSSound.beep() }
        return true
    }

    /// What a click on a link does; false when it leads nowhere.
    @discardableResult
    func activate(_ link: MarkdownLink) -> Bool {
        switch link.target {
        case .web(let url):
            return NSWorkspace.shared.open(url)
        case .anchor(let anchor):
            return scroll(to: anchor)
        case .localFile(let url):
            guard let onRevealFile else { return false }
            // Whether it exists is asked off the main thread: a volume may stop answering.
            Task { [weak self] in
                let exists = await Task.detached(priority: .userInitiated) { FileManager.default.fileExists(atPath: url.path) }.value
                guard self != nil else { return }
                if exists { onRevealFile(url) } else { NSSound.beep() }
            }
            return true
        case .refused:
            return false
        }
    }

    /// The first link whose text contains this, as the smoke test clicks it.
    func link(titled text: String) -> MarkdownLink? {
        guard let storage = formattedView.textStorage else { return nil }
        var found: MarkdownLink?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let link = value as? MarkdownLink, (storage.string as NSString).substring(with: range).contains(text) { found = link; stop.pointee = true }
        }
        return found
    }

    func contextMenuActions() -> [String]? {
        guard let storage = formattedView.textStorage, storage.length > 0,
              let base = formattedView.menu?.copy() as? NSMenu ?? NSTextView.defaultMenu?.copy() as? NSMenu else { return nil }
        var linkIndex = 0
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { linkIndex = range.location; stop.pointee = true }
        }
        formattedView.setSelectedRange(NSRange(location: linkIndex, length: 1))
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let menu = event.flatMap { formattedView.menu(for: $0) } ?? base
        return textView(formattedView, menu: menu, for: event ?? NSEvent(), at: linkIndex)?.items.compactMap { $0.action.map(NSStringFromSelector) }
    }

    /// The text view's own link items would open a link without asking this view; only Copy Link stays.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        for item in menu.items {
            let action = item.action.map(NSStringFromSelector) ?? ""
            if action.localizedCaseInsensitiveContains("link"), !action.localizedCaseInsensitiveContains("copy") { menu.removeItem(item) }
        }
        return menu
    }

    @discardableResult
    func scroll(to anchor: String) -> Bool {
        if mode != .formatted { setMode(.formatted) }
        guard let storage = formattedView.textStorage else { return false }
        var candidates = [anchor]
        if anchor.hasPrefix("user-content-") { candidates.append(String(anchor.dropFirst("user-content-".count))) }
        candidates.append(MarkdownDocument.slug(anchor))
        var found: NSRange?
        for candidate in candidates where found == nil {
            storage.enumerateAttribute(.markdownAnchor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if (value as? String) == candidate { found = range; stop.pointee = true }
            }
        }
        guard let found else { return false }
        formattedView.scrollRangeToVisible(found)
        formattedView.setSelectedRange(NSRange(location: found.location, length: 0))
        formattedView.showFindIndicator(for: found)
        return true
    }

    // MARK: - Images

    private struct DecodedImages: @unchecked Sendable { var images: [URL: CGImage] = [:] }

    private func loadImages() {
        guard let storage = formattedView.textStorage else { imagesSettled = true; return }
        var urls: [URL] = []
        storage.enumerateAttribute(.markdownImage, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let url = value as? URL, !urls.contains(url), urls.count < Self.imageCountLimit { urls.append(url) }
        }
        guard !urls.isEmpty else { imagesSettled = true; return }
        let requested = urls
        imageTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { Self.decode(requested) }
            let decoded = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.install(decoded.images)
        }
    }

    nonisolated private static func decode(_ urls: [URL]) -> DecodedImages {
        var result = DecodedImages()
        var budget = decodedImageBudget
        for url in urls {
            if Task.isCancelled { break }
            // A picture inside an unlocked secure folder stays there; one only in iCloud is not downloaded.
            guard !SecureFolderService.isSessionURL(url),
                  case .available(let resolved) = MediaFileAccess.availability(of: url),
                  !SecureFolderService.isSessionURL(resolved) else { continue }
            var info = stat()
            guard lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int64(info.st_size) <= imageFileLimit else { continue }
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(resolved as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
                let cost = image.bytesPerRow * image.height
                guard cost <= budget else { return }
                budget -= cost
                result.images[url] = image
            }
        }
        return result
    }

    private func install(_ images: [URL: CGImage]) {
        defer { imagesSettled = true }
        guard !images.isEmpty, let storage = formattedView.textStorage else { return }
        let scale = window?.backingScaleFactor ?? 2
        var replacements: [(NSRange, URL)] = []
        storage.enumerateAttribute(.markdownImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = value as? URL, images[url] != nil { replacements.append((range, url)) }
        }
        let width = availableImageWidth
        storage.beginEditing()
        for (range, url) in replacements.reversed() {
            guard let image = images[url] else { continue }
            let attachment = MarkdownImageAttachment()
            // A large picture is taken as made for a Retina screen and shown at its point size;
            // a small one keeps one point per pixel, so it is not blown up or shrunk.
            let points: CGFloat = image.width > 1200 ? scale : 1
            attachment.naturalSize = CGSize(width: CGFloat(image.width) / points, height: CGFloat(image.height) / points)
            attachment.image = NSImage(cgImage: image, size: attachment.naturalSize)
            attachment.fit(width: width)
            var attributes = storage.attributes(at: range.location, effectiveRange: nil)
            attributes[.markdownImage] = nil
            attributes[.link] = nil
            let picture = NSMutableAttributedString(attachment: attachment)
            picture.addAttributes(attributes, range: NSRange(location: 0, length: picture.length))
            storage.replaceCharacters(in: range, with: picture)
            loadedImageCount += 1
        }
        storage.endEditing()
        fittedWidth = width
        needsLayout = true
    }
}
