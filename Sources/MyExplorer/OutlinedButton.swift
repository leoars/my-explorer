// SPDX-License-Identifier: Apache-2.0
import AppKit

@MainActor
private final class OutlinedButtonCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: imagePosition == .imageOnly ? 0 : 8, dy: 0), in: controlView)
    }
}

/// Native button behavior and accessibility, with a quiet, high-contrast toolbar surface.
@MainActor
class OutlinedButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private(set) var isHovered = false
    var showsSelection = false { didSet { updateTint(); needsDisplay = true } }

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
        return NSSize(width: size.width + (imagePosition == .imageOnly ? 0 : 16),
                      height: max(28, max(size.height, (font?.ascender ?? 13) - (font?.descender ?? -3) + 10)))
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
        NSColor(white: fill, alpha: isEnabled ? 1 : 0.5).setFill(); path.fill()
        let stroke = selected ? NSColor.systemBlue :
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : NSColor(white: border, alpha: isEnabled ? 1 : 0.45)
        stroke.setStroke(); path.lineWidth = lineWidth; path.stroke()
        super.draw(dirtyRect)
        if isEnabled, window?.isKeyWindow == true, window?.firstResponder === self {
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.systemBlue.setStroke(); focus.lineWidth = 2 * lineWidth; focus.stroke()
        }
    }
}
