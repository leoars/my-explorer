// SPDX-License-Identifier: Apache-2.0
import AppKit

@MainActor
enum DialogPlacement {
    static var explorerWindow: NSWindow? {
        (NSApp.delegate as? AppDelegate)?.controller?.window
    }

    private static func frame(for dialog: NSWindow, over owner: NSWindow) -> NSRect {
        let size = dialog.frame.size
        var frame = NSRect(origin: NSPoint(x: (owner.frame.midX - size.width / 2).rounded(),
                                           y: (owner.frame.midY - size.height / 2).rounded()), size: size)
        if let visible = owner.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - size.width))
            frame.origin.y = min(visible.maxY - size.height, max(frame.minY, visible.minY))
        }
        return frame
    }

    static func center(_ dialog: NSWindow) {
        guard let owner = explorerWindow else { dialog.center(); return }
        dialog.setFrameOrigin(frame(for: dialog, over: owner).origin)
    }

    static func sheetAnchor(_ sheet: NSWindow, in parent: NSWindow) -> NSRect {
        let target = frame(for: sheet, over: explorerWindow ?? parent)
        return parent.convertFromScreen(NSRect(x: target.midX, y: target.maxY, width: 0, height: 0))
    }

    static func runModal(_ window: NSWindow, present: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        // AppKit sizes and positions standalone alerts and file pickers as the modal loop starts.
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                if NSApp.modalWindow === window { center(window) }
            }
        }
        return present()
    }
}

@MainActor
class DialogWindowController: NSWindowController, NSWindowDelegate {
    override func showWindow(_ sender: Any?) {
        if let window, !window.isVisible {
            shouldCascadeWindows = false
            DialogPlacement.center(window)
        }
        super.showWindow(sender)
    }

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        DialogPlacement.sheetAnchor(sheet, in: window)
    }
}
