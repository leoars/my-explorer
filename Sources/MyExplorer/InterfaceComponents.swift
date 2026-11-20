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
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth, iconHeight,
            gitBadge.widthAnchor.constraint(equalToConstant: 12),
            gitBadge.heightAnchor.constraint(equalToConstant: 12),
            gitBadge.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            gitBadge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
            shortcutBadge.widthAnchor.constraint(equalToConstant: 10),
            shortcutBadge.heightAnchor.constraint(equalToConstant: 10),
            shortcutBadge.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -2),
            shortcutBadge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    func setIconSize(_ side: CGFloat) {
        iconWidth.constant = side; iconHeight.constant = side
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class ExplorerTableView: NSTableView {
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
