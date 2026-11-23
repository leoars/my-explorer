// SPDX-License-Identifier: Apache-2.0
import AppKit

/// The Windows editing keys with Control, in every text field and text view of the application:
/// the address, the filter, a name being edited, dialogs, the Options, the text extraction window.
/// Left to AppKit, Control+A goes to the start of the line and Control+X does nothing.
@MainActor
enum ControlEditingKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handle(event) ? nil : event }
    }

    /// True when the key was an editing command and was carried out.
    static func handle(_ event: NSEvent) -> Bool {
        guard let editor = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
              !editor.hasMarkedText() else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let editable = editor.isEditable
        if flags == .control {
            switch key {
            case "a": editor.selectAll(nil); return true
            // With nothing selected the key is left alone: the address bar copies the whole path.
            case "c": if editor.selectedRange().length > 0 { editor.copy(nil); return true }
            case "x": if editable, editor.selectedRange().length > 0 { editor.cut(nil) }; return true
            case "v": if editable { editor.paste(nil) }; return true
            case "z": if editable { editor.undoManager?.undo() }; return true
            case "y": if editable { editor.undoManager?.redo() }; return true
            default: break
            }
            switch event.keyCode {
            case 123: editor.moveWordLeft(nil); return true
            case 124: editor.moveWordRight(nil); return true
            case 51: if editable { editor.deleteWordBackward(nil) }; return true
            case 117: if editable { editor.deleteWordForward(nil) }; return true
            case 115: editor.moveToBeginningOfDocument(nil); return true
            case 119: editor.moveToEndOfDocument(nil); return true
            default: break
            }
        }
        // The same commands with Command are carried out here too, without the menu: the App
        // Shortcuts of the system can move the shortcut of "Select All", "Copy" and the others
        // to another key, and then the menu no longer answers to Command in a text field.
        if flags == .command {
            switch key {
            case "a": editor.selectAll(nil); return true
            case "c": if editor.selectedRange().length > 0 { editor.copy(nil); return true }
            case "x": if editable, editor.selectedRange().length > 0 { editor.cut(nil) }; return true
            case "v": if editable { editor.paste(nil) }; return true
            case "z": if editable { editor.undoManager?.undo() }; return true
            default: break
            }
        }
        if flags == [.command, .shift], key == "z" {
            if editable { editor.undoManager?.redo() }
            return true
        }
        if flags == [.control, .shift] {
            if key == "z" { if editable { editor.undoManager?.redo() }; return true }
            switch event.keyCode {
            case 123: editor.moveWordLeftAndModifySelection(nil); return true
            case 124: editor.moveWordRightAndModifySelection(nil); return true
            case 115: editor.moveToBeginningOfDocumentAndModifySelection(nil); return true
            case 119: editor.moveToEndOfDocumentAndModifySelection(nil); return true
            default: break
            }
        }
        return false
    }
}
