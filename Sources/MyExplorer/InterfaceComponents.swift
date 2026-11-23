// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
final class ExplorerSurface: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
enum ExplorerStyle {
    static var preferences = DisplayPreferences()
    static var browserPreferences = BrowserViewPreferences()
    static var folderViewModes = FolderViewModes()
    static var folderShortcuts = FolderShortcuts()
    static let accent = NSColor.systemBlue
    static func font(_ area: FontArea, offset: CGFloat = 0, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: max(9, CGFloat(preferences.fontSize(for: area)) + offset), weight: weight)
    }
    static func configureMenu(_ menu: NSMenu) {
        menu.font = font(.menus)
        for item in menu.items { if let submenu = item.submenu { configureMenu(submenu) } }
    }

    static func symbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    static func button(_ symbol: String, title: String, target: AnyObject, action: Selector, outlined: Bool = false) -> NSButton {
        let button = outlined ? OutlinedButton(image: self.symbol(symbol, description: title) ?? NSImage(), target: target, action: action)
            : NSButton(image: self.symbol(symbol, description: title) ?? NSImage(), target: target, action: action)
        if !outlined { button.bezelStyle = .texturedRounded }
        button.isBordered = false
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    static func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor, area: FontArea = .bars) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font(area, offset: size - 12)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    static func stack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// SF Symbols carry font-baseline alignment insets. File icons use the full square box instead.
@MainActor
private final class FileIconImageView: NSImageView {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

@MainActor
final class FileNameCell: NSTableCellView {
    let icon: NSImageView = FileIconImageView()
    let shortcutBadge: NSImageView = FileIconImageView()
    let gitBadge: NSImageView = FileIconImageView()
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    let label = ExplorerStyle.label("")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label); addSubview(shortcutBadge); addSubview(gitBadge)
        gitBadge.translatesAutoresizingMaskIntoConstraints = false
        gitBadge.imageScaling = .scaleProportionallyUpOrDown
        gitBadge.isHidden = true
        gitBadge.setAccessibilityIdentifier("explorer.git.badge")
        shortcutBadge.translatesAutoresizingMaskIntoConstraints = false
        shortcutBadge.image = NSImage(systemSymbolName: "arrowshape.turn.up.right.fill", accessibilityDescription: nil)
        shortcutBadge.contentTintColor = .black
        shortcutBadge.imageScaling = .scaleProportionallyUpOrDown
        shortcutBadge.wantsLayer = true
        shortcutBadge.layer?.backgroundColor = NSColor.white.cgColor
        shortcutBadge.layer?.cornerRadius = 2
        shortcutBadge.isHidden = true
        iconWidth = icon.widthAnchor.constraint(equalToConstant: 22)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: 22)
        imageView = icon; textField = label
        rowConstraints = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]
        tileConstraints = [
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ]
        NSLayoutConstraint.activate(rowConstraints + [
            iconWidth, iconHeight,
            gitBadge.widthAnchor.constraint(equalToConstant: 12),
            gitBadge.heightAnchor.constraint(equalToConstant: 12),
            gitBadge.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            gitBadge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
            shortcutBadge.widthAnchor.constraint(equalToConstant: 10),
            shortcutBadge.heightAnchor.constraint(equalToConstant: 10),
            shortcutBadge.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -2),
            shortcutBadge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1)
        ])
    }

    /// The icon with the name beside it, as in a row of the list, or above it, as in a tile.
    enum Arrangement { case row, tile(lines: Int) }
    private var rowConstraints: [NSLayoutConstraint] = []
    private var tileConstraints: [NSLayoutConstraint] = []
    func arrange(_ arrangement: Arrangement) {
        switch arrangement {
        case .row:
            NSLayoutConstraint.deactivate(tileConstraints); NSLayoutConstraint.activate(rowConstraints)
            label.alignment = .natural
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.lineBreakMode = .byTruncatingMiddle
        case .tile(let lines):
            NSLayoutConstraint.deactivate(rowConstraints); NSLayoutConstraint.activate(tileConstraints)
            label.alignment = .center
            label.maximumNumberOfLines = lines
            label.cell?.wraps = lines > 1
            label.cell?.truncatesLastVisibleLine = true
            label.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingMiddle
        }
    }
    func setIconSize(_ side: CGFloat) {
        iconWidth.constant = side; iconHeight.constant = side
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The iCloud column of the file list: one small symbol for the item's state, as in Finder. The
/// symbol is a button while the item can be downloaded.
final class CloudStatusCell: NSView {
    let button = NSButton()
    /// Takes the place of the symbol while the item downloads: a spinner until iCloud reports
    /// progress, then a circle that fills up.
    let indicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        // A state that cannot be clicked is still information: do not dim it.
        (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.minValue = 0; indicator.maxValue = 1
        indicator.isDisplayedWhenStopped = true
        indicator.isHidden = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 20),
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 16),
            indicator.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Symbol and tint for a state; nil when nothing is shown (not in iCloud, or already on this Mac).
    static func appearance(for state: ICloudAvailability?) -> (symbol: String, color: NSColor)? {
        switch state {
        case .onlineOnly?: return ("icloud.and.arrow.down", .secondaryLabelColor)
        case .downloading?: return ("arrow.down.circle", .controlAccentColor)
        case .uploading?: return ("icloud.and.arrow.up", .controlAccentColor)
        case .waiting?: return ("icloud", .secondaryLabelColor)
        case .conflict?, .failed?: return ("exclamationmark.icloud", .systemOrange)
        case .unknown?: return ("icloud.slash", .tertiaryLabelColor)
        case .available?, nil: return nil
        }
    }

    func configure(state: ICloudAvailability?, description: String?, canDownload: Bool, download: ICloudDownloadMonitor.Status? = nil) {
        let appearance = Self.appearance(for: state)
        button.image = appearance.flatMap { ExplorerStyle.symbol($0.symbol, description: description ?? "") }
        button.contentTintColor = appearance?.color
        button.isHidden = appearance == nil || download != nil
        button.isEnabled = canDownload
        button.toolTip = description
        button.setAccessibilityLabel(description)
        toolTip = description
        switch download {
        case nil:
            indicator.stopAnimation(nil)
            indicator.isHidden = true
        case .waiting?:
            indicator.isIndeterminate = true
            indicator.isHidden = false
            // Asked for every time: a cell put back by a reload has had its spinner stopped, and
            // starting one that already turns does nothing.
            indicator.startAnimation(nil)
        case .fraction(let value)?:
            if indicator.isIndeterminate { indicator.stopAnimation(nil); indicator.isIndeterminate = false }
            indicator.doubleValue = value
            indicator.isHidden = false
        }
        indicator.setAccessibilityLabel(description)
    }
}

/// Column header that draws a clear arrow on the sorted column: up for ascending, down for
/// descending. AppKit's own indicator is a faint chevron that is easy to miss.
final class SortHeaderCell: NSTableHeaderCell {
    private static let side: CGFloat = 12

    override func sortIndicatorRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - Self.side - 8, y: rect.midY - Self.side / 2, width: Self.side, height: Self.side)
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        guard priority == 0 else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        let name = ascending ? "chevron.up" : "chevron.down"
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            super.drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: priority)
            return
        }
        let slot = sortIndicatorRect(forBounds: cellFrame)
        let size = image.size
        let scale = min(1, slot.width / max(size.width, 1), slot.height / max(size.height, 1))
        let target = NSRect(x: slot.midX - size.width * scale / 2, y: slot.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

@MainActor
final class ExplorerTableView: NSTableView, @preconcurrency NSServicesMenuRequestor {
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let serviceTypes: [NSPasteboard.PasteboardType] = [.fileURL, filenamesType]
    var serviceSelection: (() -> [URL])?
    private var serviceURLs: [URL] { Self.serviceURLs(serviceSelection) }
    /// What the selection offers to the Services menu; the grid of the other view modes shares it.
    static func serviceURLs(_ selection: (() -> [URL])?) -> [URL] {
        guard let urls = selection?(), !urls.isEmpty, urls.allSatisfy({
            $0.isFileURL && !SecureFolderService.isSessionURL($0) && !LocalTransferRecovery.isProtected($0)
        }) else { return [] }
        return urls
    }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let sendType, Self.serviceTypes.contains(sendType) && returnType == nil && !serviceURLs.isEmpty { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        Self.write(serviceURLs, to: pboard, types: types)
    }
    static func write(_ urls: [URL], to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !urls.isEmpty, !Set(types).isDisjoint(with: serviceTypes) else { return false }
        pboard.clearContents()
        if types.contains(.fileURL), !pboard.writeObjects(urls.map { $0 as NSURL }) { return false }
        if types.contains(filenamesType) {
            pboard.addTypes([filenamesType], owner: nil)
            return pboard.setPropertyList(urls.map(\.path), forType: filenamesType)
        }
        return true
    }

    var renameCandidate: ((NSPoint) -> (() -> Void)?)?
    private var clickedName: (() -> Void)?
    private var renameDelay: Task<Void, Never>?

    override func mouseDown(with event: NSEvent) {
        cancelRenameClick()
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .control, .command, .option]).isEmpty {
            clickedName = renameCandidate?(convert(event.locationInWindow, from: nil))
        }
        super.mouseDown(with: event)
        clickedName = nil
    }

    // NSTableView sends its single action for a completed click, after tracking drags.
    func completedClick() {
        guard let clickedName else { return }
        renameDelay = Task {
            do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
            clickedName()
        }
    }

    func cancelRenameClick() {
        renameDelay?.cancel()
        renameDelay = nil
        clickedName = nil
    }

    var openSelection: (() -> Void)?
    var goBack: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelection?(); return }
        if event.keyCode == 51 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            goBack?(); return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class BreadcrumbButton: OutlinedButton {
    var destination: URL?
}

@MainActor
final class TabActionButton: NSButton {
    var tabID: UUID?
}

@MainActor
final class TabSurface: NSView {
    var selected = false
    override func draw(_ dirtyRect: NSRect) {
        (selected ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        if selected {
            NSColor.systemBlue.setFill()
            NSRect(x: 10, y: 0, width: max(0, bounds.width - 20), height: 2).fill()
        }
    }
}
