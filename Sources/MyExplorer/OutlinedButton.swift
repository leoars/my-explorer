// SPDX-License-Identifier: Apache-2.0
import AppKit

@MainActor
private final class OutlinedButtonCell: NSButtonCell {
    /// Room kept free at the trailing edge, for the chevron of a button that opens a menu.
    var trailingRoom: CGFloat = 0
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = cellFrame.insetBy(dx: imagePosition == .imageOnly ? 0 : 8, dy: 0)
        frame.size.width -= trailingRoom
        super.drawInterior(withFrame: frame, in: controlView)
    }
}

/// Native button behavior and accessibility, with a quiet, high-contrast toolbar surface.
@MainActor
class OutlinedButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false
    var showsSelection = false { didSet { updateTint(); needsDisplay = true } }
    /// No surface until the pointer is over it: for buttons that sit inside another control,
    /// such as the folders of the address bar.
    var quiet = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    fileprivate var trailingRoom: CGFloat = 0 {
        didSet { (cell as? OutlinedButtonCell)?.trailingRoom = trailingRoom; invalidateIntrinsicContentSize() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = OutlinedButtonCell(textCell: "")
        configureSurface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSurface()
    }

    private func configureSurface() {
        isBordered = false
        bezelStyle = .regularSquare
        // Draw inside our bounds so focus remains visible in compact stack-view bars.
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        updateTint()
    }

    override var isEnabled: Bool { didSet { updateTint(); needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { updateTint(); needsDisplay = true } }
    override var font: NSFont? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    private func updateTint() {
        // AppKit applies the disabled treatment itself; do not dim the content twice.
        contentTintColor = showsSelection && state == .on && isEnabled ? .systemBlue : .labelColor
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + (imagePosition == .imageOnly ? 0 : 16) + trailingRoom,
                      height: quiet ? max(20, ceil((font?.ascender ?? 13) - (font?.descender ?? -3)) + 4)
                          : max(28, max(size.height, (font?.ascender ?? 13) - (font?.descender ?? -3) + 10)))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint(); needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false; needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let selected = showsSelection && state == .on && isEnabled
        let active = isEnabled && (isHighlighted || selected)
        let hover = isEnabled && isHovered && window?.isKeyWindow == true
        let fill: CGFloat = dark ? (active ? 0.25 : hover ? 0.22 : 0.18) : (active ? 0.88 : hover ? 0.94 : 0.985)
        let border: CGFloat = dark ? (hover || active ? 0.53 : 0.38) : (hover || active ? 0.62 : 0.76)
        let lineWidth = 1 / max(1, window?.backingScaleFactor ?? 1)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: 5, yRadius: 5)
        if quiet {
            if hover || active { NSColor.labelColor.withAlphaComponent(active ? 0.16 : 0.09).setFill(); path.fill() }
        } else {
            NSColor(white: fill, alpha: isEnabled ? 1 : 0.5).setFill(); path.fill()
            let stroke = selected ? NSColor.systemBlue :
                NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : NSColor(white: border, alpha: isEnabled ? 1 : 0.45)
            stroke.setStroke(); path.lineWidth = lineWidth; path.stroke()
        }
        super.draw(dirtyRect)
        if isEnabled, window?.isKeyWindow == true, window?.firstResponder === self {
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.systemBlue.setStroke(); focus.lineWidth = 2 * lineWidth; focus.stroke()
        }
    }
}

/// A toolbar button that opens a menu right under itself, on the press as menus do. It draws a
/// small chevron after its content.
@MainActor
final class ToolbarMenuButton: OutlinedButton {
    let dropMenu = NSMenu()

    override init(frame: NSRect) {
        super.init(frame: frame)
        trailingRoom = 12
        target = self
        action = #selector(showMenu)
        setAccessibilityRole(.menuButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func showMenu(_ sender: Any?) {
        guard isEnabled else { return }
        highlight(true)
        dropMenu.minimumWidth = bounds.width
        dropMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
        highlight(false)
    }

    override func mouseDown(with event: NSEvent) { showMenu(nil) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let x = bounds.maxX - 12, y = bounds.midY + (isFlipped ? -1.5 : 1.5), rise: CGFloat = isFlipped ? 3.2 : -3.2
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: x - 3.2, y: y)); chevron.line(to: NSPoint(x: x, y: y + rise)); chevron.line(to: NSPoint(x: x + 3.2, y: y))
        chevron.lineWidth = 1.4; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
        NSColor.secondaryLabelColor.withAlphaComponent(isEnabled ? 1 : 0.4).setStroke()
        chevron.stroke()
    }
}

/// One title of the menu strip inside the window: it opens, under itself, the same menu the
/// menu bar of the system shows under that title.
@MainActor
final class MenuStripButton: OutlinedButton {
    var stripMenu: NSMenu?

    override init(frame: NSRect) {
        super.init(frame: frame)
        quiet = true
        target = self
        action = #selector(showMenu)
        setAccessibilityRole(.menuButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func showMenu(_ sender: Any?) {
        guard let stripMenu else { return }
        highlight(true)
        stripMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 3 : -3), in: self)
        highlight(false)
    }

    override func mouseDown(with event: NSEvent) { showMenu(nil) }
}
