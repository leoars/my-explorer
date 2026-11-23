// SPDX-License-Identifier: Apache-2.0
import AppKit
import AVFoundation
import ImageIO
import ExplorerCore

/// Cell sizes of the grid for each view mode other than details.
@MainActor
struct FileGridMetrics {
    let cell: CGSize
    let icon: CGFloat
    let flow: GridGeometry.Flow
    let arrangement: FileNameCell.Arrangement
    /// Photos and videos show their own picture in place of the icon of their type.
    let thumbnails: Bool

    static func metrics(for mode: FileViewMode) -> FileGridMetrics {
        let font = ExplorerStyle.font(.files)
        let line = ceil(font.ascender - font.descender + font.leading) + 1
        let nameWidth = max(230, font.pointSize * 19)
        switch mode {
        case .details, .list:
            return FileGridMetrics(cell: CGSize(width: nameWidth, height: FileTypeIcon.listRowHeight), icon: FileTypeIcon.listIconSide,
                                   flow: .columns, arrangement: .row, thumbnails: false)
        case .smallIcons:
            return FileGridMetrics(cell: CGSize(width: nameWidth, height: max(44, line + 26)), icon: 32,
                                   flow: .rows, arrangement: .row, thumbnails: false)
        case .largeIcons:
            return FileGridMetrics(cell: CGSize(width: 128, height: 6 + 96 + 4 + 2 * line + 8), icon: 96,
                                   flow: .rows, arrangement: .tile(lines: 2), thumbnails: true)
        case .gallery:
            return FileGridMetrics(cell: CGSize(width: 108, height: 6 + 64 + 4 + line + 8), icon: 64,
                                   flow: .columns, arrangement: .tile(lines: 1), thumbnails: true)
        }
    }

    /// Height of the strip of the gallery: one line of items and its margins.
    static var galleryStripHeight: CGFloat { metrics(for: .gallery).cell.height + 2 * GridGeometry.defaultInset + 16 }
}

extension GridGeometry {
    static let defaultInset: CGFloat = 6
}

/// Lays the items out with `GridGeometry`: equal cells whose places are computed, not stored.
@MainActor
final class FileGridLayout: NSCollectionViewLayout {
    var metrics = FileGridMetrics.metrics(for: .list) { didSet { invalidateLayout() } }
    private(set) var geometry = GridGeometry(count: 0, cell: CGSize(width: 1, height: 1), flow: .rows, viewport: .zero)

    override func prepare() {
        guard let view = collectionView else { return }
        let count = view.numberOfSections > 0 ? view.numberOfItems(inSection: 0) : 0
        geometry = GridGeometry(count: count, cell: metrics.cell, flow: metrics.flow,
                                viewport: view.enclosingScrollView?.contentSize ?? view.bounds.size, inset: GridGeometry.defaultInset)
    }

    override var collectionViewContentSize: NSSize { geometry.contentSize }

    private func attributes(_ index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = geometry.frame(at: index)
        return attributes
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        geometry.indexes(in: rect).map(attributes)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        (0..<geometry.count).contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    // The viewport is the scroll view's, watched by the grid itself; scrolling changes nothing.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { false }
}

/// The file list of the view modes other than details: list, small icons, large icons and the
/// strip of the gallery. Selection by mouse is the collection view's; the keyboard is handled
/// here, over the grid's own geometry.
@MainActor
final class FileGridView: NSCollectionView, @preconcurrency NSServicesMenuRequestor {
    let grid = FileGridLayout()
    /// Called when the user changes the selection, by mouse or keyboard.
    var onSelectionChange: (() -> Void)?
    var openSelection: (() -> Void)?
    var goBack: (() -> Void)?
    var typeSelectName: ((Int) -> String?)?
    /// What a slow second click on the name of the only selected item should do, if anything.
    var renameCandidate: ((Int, NSPoint) -> (() -> Void)?)?
    var serviceSelection: (() -> [URL])?
    /// The item under the last secondary click, for the context menu; nil over empty space.
    private(set) var clickedIndex: Int?
    /// Where the keyboard stands, and where a range extended with Shift starts.
    private var lead: Int?
    private var anchor: Int?
    private var typed = ""
    private var typedAt = Date.distantPast
    private var pendingRename: (() -> Void)?
    private var renameDelay: Task<Void, Never>?
    private var downLocation = NSPoint.zero
    private var viewport = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        collectionViewLayout = grid
        isSelectable = true
        allowsMultipleSelection = true
        allowsEmptySelection = true
        backgroundColors = [.controlBackgroundColor]
        register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The number of items per line follows the size of the scroll view.
    func watchViewport(of scroll: NSScrollView) {
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)
    }

    /// The size the grid has to have for everything in it to be reachable by scrolling.
    private var neededSize: NSSize {
        let content = currentGeometry.contentSize, port = enclosingScrollView?.contentSize ?? .zero
        return NSSize(width: max(content.width, port.width), height: max(content.height, port.height))
    }

    // With a layout of its own the collection view takes the height of its contents but keeps
    // the width of the scroll view, so in the modes that scroll sideways nothing beyond the
    // first screenful could be reached. The grid keeps its own size right, here and in layout().
    override func setFrameSize(_ newSize: NSSize) {
        let content = currentGeometry.contentSize
        super.setFrameSize(NSSize(width: max(newSize.width, content.width), height: max(newSize.height, content.height)))
    }

    @objc private func viewportChanged(_ notification: Notification) {
        guard let size = enclosingScrollView?.contentSize, size != viewport else { return }
        viewport = size
        grid.invalidateLayout()
    }

    /// In ascending order before becoming an index set: built from scattered values, a
    /// selection of tens of thousands of items would take seconds to put together.
    var selectedIndexes: IndexSet {
        selectionIndexPaths.map(\.item).sorted().reduce(into: IndexSet()) { $0.insert($1) }
    }

    /// Sets the selection without reporting it as the user's.
    func setSelection(_ indexes: IndexSet) {
        if indexes != selectedIndexes { selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) }) }
        if pendingReveal.map(indexes.contains) != true { pendingReveal = nil }
        if lead.map(indexes.contains) != true { lead = indexes.first; anchor = indexes.first }
        // A list that shrank (a filter, a refresh) must not leave the start of a range behind.
        if anchor.map(indexes.contains) != true { anchor = lead }
    }

    /// The geometry for what the grid holds now, whether or not the layout has caught up with
    /// a change of mode, of size or of the number of items.
    var currentGeometry: GridGeometry {
        GridGeometry(count: numberOfSections > 0 ? numberOfItems(inSection: 0) : 0, cell: grid.metrics.cell, flow: grid.metrics.flow,
                     viewport: enclosingScrollView?.contentSize ?? bounds.size, inset: GridGeometry.defaultInset)
    }

    func frame(of index: Int) -> NSRect? {
        let geometry = currentGeometry
        return (0..<geometry.count).contains(index) ? geometry.frame(at: index) : nil
    }

    /// Brings the layout and the size of the grid up to date with what it holds. After a change
    /// of mode or of contents the collection view only takes its new size at the next display
    /// pass, and until then nothing can be scrolled to beyond the old one.
    func settle() {
        layoutSubtreeIfNeeded()
        let wanted = neededSize
        if frame.size != wanted { setFrameSize(wanted) }
    }

    func reveal(_ index: Int) {
        settle()
        guard let frame = frame(of: index) else { return }
        scrollToVisible(frame)
        // The items of the place scrolled to are only put there by a layout pass.
        needsLayout = true
    }

    /// Reveals the item once the collection view has laid itself out again: after a change of
    /// mode it puts the scroll back at the start during that pass, undoing a reveal made before.
    private var pendingReveal: Int?
    func revealAfterLayout(_ index: Int) {
        pendingReveal = index
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.revealPending() }
    }

    private func revealPending() {
        guard let index = pendingReveal else { return }
        pendingReveal = nil
        reveal(index)
    }

    override func layout() {
        super.layout()
        let wanted = neededSize
        if frame.size != wanted { setFrameSize(wanted) }
        if let index = pendingReveal, let frame = frame(of: index), bounds.contains(frame) { scrollToVisible(frame) }
    }

    func nameCell(at index: Int) -> FileNameCell? {
        (item(at: IndexPath(item: index, section: 0)) as? FileGridItem)?.cell
    }

    private func move(to target: Int, extending: Bool) {
        guard (0..<currentGeometry.count).contains(target) else { return }
        var range = IndexSet(integer: target)
        if let start = anchor, start >= currentGeometry.count { anchor = nil }
        if extending, let anchor { range = IndexSet(integersIn: min(anchor, target)...max(anchor, target)) } else { anchor = target }
        lead = target
        selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
        reveal(target)
        onSelectionChange?()
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        onSelectionChange?()
    }

    override func deselectAll(_ sender: Any?) {
        super.deselectAll(sender)
        onSelectionChange?()
    }

    override func keyDown(with event: NSEvent) {
        clickedIndex = nil
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 36 || event.keyCode == 76 { openSelection?(); return }
        if event.keyCode == 51 && flags.isEmpty { goBack?(); return }
        let geometry = currentGeometry
        if flags.subtracting(.shift).isEmpty, [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) {
            guard geometry.count > 0 else { return }
            let selected = selectedIndexes
            let current = lead.flatMap { selected.contains($0) ? $0 : nil } ?? selected.first
            let screen = enclosingScrollView?.contentSize ?? bounds.size
            var target: Int?
            switch event.keyCode {
            case 115: target = 0
            case 119: target = geometry.count - 1
            case 116: target = current.map { geometry.page(from: $0, forward: false, viewport: screen) } ?? 0
            case 121: target = current.map { geometry.page(from: $0, forward: true, viewport: screen) } ?? 0
            default:
                let direction: GridGeometry.Direction = event.keyCode == 123 ? .left : event.keyCode == 124 ? .right
                    : event.keyCode == 126 ? .up : .down
                // With nothing selected the first arrow takes the first item.
                target = current.map { geometry.neighbor(of: $0, direction) } ?? 0
            }
            if let target { move(to: target, extending: flags.contains(.shift)) }
            return
        }
        if flags.subtracting(.shift).isEmpty, event.keyCode != 48, event.keyCode != 53, let text = event.characters, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }),
           text != " " || (!typed.isEmpty && Date().timeIntervalSince(typedAt) <= 1) {
            typeSelect(text)
            return
        }
        super.keyDown(with: event)
    }

    /// Typing goes to the next item whose name starts with what was typed; the same letter again
    /// goes on to the next name that starts with it.
    private func typeSelect(_ text: String) {
        let now = Date()
        if now.timeIntervalSince(typedAt) > 1 { typed = "" }
        typedAt = now
        typed += text
        let count = currentGeometry.count
        guard count > 0, let name = typeSelectName else { return }
        let cycling = typed.count > 1 && Set(typed.lowercased()).count == 1
        let prefix = cycling ? String(typed.prefix(1)) : typed
        let start = lead ?? selectedIndexes.first ?? -1
        let first = typed.count == 1 || cycling ? start + 1 : max(0, start)
        for offset in 0..<count {
            let index = (first + offset) % count
            if name(index)?.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                move(to: index, extending: false)
                return
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        cancelRenameClick()
        clickedIndex = nil
        typed = ""
        let point = convert(event.locationInWindow, from: nil)
        let index = currentGeometry.index(at: point)
        let flags = event.modifierFlags.intersection([.shift, .control, .command, .option])
        if event.clickCount == 2, flags.isEmpty, let index {
            if selectedIndexes != IndexSet(integer: index) { move(to: index, extending: false) }
            openSelection?()
            return
        }
        if event.clickCount == 1, flags.isEmpty, let index {
            pendingRename = renameCandidate?(index, point)
            downLocation = event.locationInWindow
        }
        super.mouseDown(with: event)
        if let index {
            lead = index
            if !flags.contains(.shift) || anchor == nil { anchor = index }
        }
        // A Control-click opened the context menu inside the call above; it is over by now.
        clickedIndex = nil
        // The collection view may have tracked the click to its end by itself.
        if NSEvent.pressedMouseButtons & 1 == 0 { finishClick(at: window?.mouseLocationOutsideOfEventStream) }
    }

    override func mouseDragged(with event: NSEvent) {
        pendingRename = nil
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        finishClick(at: event.locationInWindow)
    }

    private func finishClick(at location: NSPoint?) {
        guard let action = pendingRename else { return }
        pendingRename = nil
        guard let location, hypot(location.x - downLocation.x, location.y - downLocation.y) < 4 else { return }
        renameDelay = Task {
            do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
            action()
        }
    }

    func cancelRenameClick() {
        renameDelay?.cancel()
        renameDelay = nil
        pendingRename = nil
    }

    /// The item under the click is only meaningful while its context menu is up.
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        clickedIndex = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cancelRenameClick()
        clickedIndex = currentGeometry.index(at: convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        return menu
    }

    /// The selection is drawn stronger while the list has the keyboard.
    func redrawSelection() {
        for item in visibleItems() { item.view.needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        redrawSelection()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        redrawSelection()
        return accepted
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let sendType, ExplorerTableView.serviceTypes.contains(sendType), returnType == nil,
           !ExplorerTableView.serviceURLs(serviceSelection).isEmpty { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        ExplorerTableView.write(ExplorerTableView.serviceURLs(serviceSelection), to: pboard, types: types)
    }
}

/// Background of one item of the grid: the selection and the mark of a folder about to receive
/// what is being dragged.
@MainActor
final class FileGridItemView: NSView {
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var dropTarget = false { didSet { if dropTarget != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard selected || dropTarget else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5)
        if selected {
            let focused = window?.isKeyWindow == true && window?.firstResponder === superview
            (focused ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3) : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            path.fill()
        }
        if dropTarget {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}

@MainActor
final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("explorer.grid.item")
    let cell = FileNameCell()
    /// The iCloud state of an item that is not on this Mac, over a corner of its icon.
    let cloudBadge = NSImageView()
    private(set) var entryID: String?
    private var thumbnail: Task<Void, Never>?

    override func loadView() {
        let surface = FileGridItemView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cloudBadge.translatesAutoresizingMaskIntoConstraints = false
        cloudBadge.imageScaling = .scaleProportionallyUpOrDown
        cloudBadge.isHidden = true
        surface.addSubview(cell)
        surface.addSubview(cloudBadge)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: surface.leadingAnchor), cell.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            cell.topAnchor.constraint(equalTo: surface.topAnchor), cell.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            cloudBadge.widthAnchor.constraint(equalToConstant: 14), cloudBadge.heightAnchor.constraint(equalToConstant: 14),
            cloudBadge.trailingAnchor.constraint(equalTo: cell.icon.trailingAnchor, constant: 4),
            cloudBadge.topAnchor.constraint(equalTo: cell.icon.topAnchor, constant: -3)
        ])
        view = surface
    }

    override var isSelected: Bool { didSet { (view as? FileGridItemView)?.selected = isSelected } }
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { (view as? FileGridItemView)?.dropTarget = highlightState == .asDropTarget }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail?.cancel(); thumbnail = nil
        entryID = nil
        cell.icon.image = nil
        (view as? FileGridItemView)?.dropTarget = false
    }

    func represent(_ entry: FileEntry) {
        thumbnail?.cancel(); thumbnail = nil
        entryID = entry.id
    }

    func showCloud(state: ICloudAvailability?, downloading: Bool, description: String?) {
        let appearance = downloading ? CloudStatusCell.appearance(for: .downloading) : CloudStatusCell.appearance(for: state)
        cloudBadge.image = appearance.flatMap { ExplorerStyle.symbol($0.symbol, description: description ?? "") }
        cloudBadge.contentTintColor = appearance?.color
        cloudBadge.isHidden = appearance == nil
        cloudBadge.toolTip = description
        cloudBadge.setAccessibilityLabel(description)
    }

    /// Replaces the icon of the type with the picture of a photo or a video, when it comes.
    func showThumbnail(of entry: FileEntry, kind: MediaKind, side: CGFloat) {
        let edge = Int((side * (view.window?.backingScaleFactor ?? 2)).rounded())
        if let cached = Thumbnails.shared.cached(entry, edge: edge) { cell.icon.image = cached; return }
        let id = entry.id
        thumbnail = Task { [weak self] in
            guard let image = await Thumbnails.shared.load(entry, kind: kind, edge: edge), !Task.isCancelled,
                  let self, self.entryID == id else { return }
            self.cell.icon.image = image
        }
    }
}

/// Small pictures of photos and videos for the icon views. Decoded in this process, a few at a
/// time, and kept in memory only: nothing is written to disk and nothing is downloaded.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let simultaneous = 4

    init() {
        cache.countLimit = 1000
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    private func key(_ entry: FileEntry, _ edge: Int) -> NSString {
        "\(entry.url.path)|\(entry.size ?? -1)|\(entry.modified?.timeIntervalSinceReferenceDate ?? 0)|\(edge)" as NSString
    }

    func cached(_ entry: FileEntry, edge: Int) -> NSImage? { cache.object(forKey: key(entry, edge)) }

    func removeAll() { cache.removeAllObjects() }

    func load(_ entry: FileEntry, kind: MediaKind, edge: Int) async -> NSImage? {
        if let cached = cached(entry, edge: edge) { return cached }
        // The latest request goes first: what was asked for last is what is on screen now.
        if running < simultaneous { running += 1 } else { await withCheckedContinuation { waiting.append($0) } }
        defer { if let next = waiting.popLast() { next.resume() } else { running -= 1 } }
        guard !Task.isCancelled else { return nil }
        let url = entry.url, alias = entry.isAlias
        guard let decoded = await Task.detached(priority: .utility, operation: { await Self.decode(url, alias: alias, kind: kind, edge: edge) }).value
        else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: CGFloat(decoded.image.width) / scale, height: CGFloat(decoded.image.height) / scale))
        // What is inside a protected folder is not kept once it leaves the screen.
        if !SecureFolderService.isSessionURL(url) {
            cache.setObject(image, forKey: key(entry, edge), cost: decoded.image.bytesPerRow * decoded.image.height)
        }
        return image
    }

    nonisolated private static func decode(_ url: URL, alias: Bool, kind: MediaKind, edge: Int) async -> PreviewThumbnail? {
        // A file that is only in iCloud is not opened: reading it would download it.
        guard case .available(let resolved) = MediaFileAccess.availability(of: url, isAlias: alias) else { return nil }
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(resolved as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                                            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceShouldAllowFloat: false]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(PreviewThumbnail.init)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: resolved))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: edge, height: edge)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            // A second in, where there usually is a picture already; the very start is often black.
            if let frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image { return PreviewThumbnail(image: frame) }
            return (try? await generator.image(at: .zero).image).map(PreviewThumbnail.init)
        case .audio:
            return nil
        }
    }
}

/// The upper part of the gallery: the selected item, large.
@MainActor
final class GalleryStage: NSView {
    private let picture = NSImageView()
    private let caption = ExplorerStyle.label("", color: .secondaryLabelColor, area: .files)
    private let line = ExplorerStyle.separator()
    private var loading: Task<Void, Never>?
    private var shown: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picture.imageScaling = .scaleProportionallyDown
        picture.imageAlignment = .alignCenter
        picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        for view in [picture, caption, line] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), picture.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 12), picture.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -8),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            caption.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -8),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }

    /// Shows the entry: its picture when it is a photo or a video on this Mac, else its icon.
    func show(_ entry: FileEntry?, name: String, local: Bool) {
        guard let entry else {
            loading?.cancel(); loading = nil
            shown = nil
            picture.image = nil
            caption.stringValue = ""
            return
        }
        caption.stringValue = name
        caption.toolTip = name
        // Asked again when the item arrives from iCloud: only then is there a picture to read.
        let id = entry.id + (local ? "|local" : "|cloud")
        guard shown != id else { return }
        loading?.cancel(); loading = nil
        shown = id
        let kind = L10n.current.fileKind(entry)
        picture.image = entry.isPackage && entry.url.isFileURL ? NSWorkspace.shared.icon(forFile: entry.url.path)
            : PremiumIcons.image(FileTypeIcon.appearance(for: entry).icon, side: 160, description: kind)
        picture.setAccessibilityLabel(name)
        guard local, let media = MediaKind.detect(entry), media != .audio else { return }
        let scale = window?.backingScaleFactor ?? 2
        // In steps, so that resizing the window does not ask for a new picture at every size.
        let edge = min(1600, max(800, Int((max(picture.bounds.width, picture.bounds.height) * scale / 400).rounded(.up)) * 400))
        loading = Task { [weak self] in
            guard let image = await Thumbnails.shared.load(entry, kind: media, edge: edge), !Task.isCancelled,
                  let self, self.shown == id else { return }
            self.picture.image = image
        }
    }
}
