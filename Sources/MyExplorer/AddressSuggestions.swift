// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
final class AddressSuggestions: NSObject {
    private var task: Task<Void, Never>?
    private var panel: NSBox?
    private var choices: [String] = []
    private var buttons: [NSButton] = []
    private var selection: Int?
    private var draft = ""
    private weak var field: NSTextField?
    var submit: (() -> Void)?
    var isVisible: Bool { panel != nil }

    func dismiss() {
        task?.cancel()
        task = nil
        panel?.removeFromSuperview()
        panel = nil
        choices = []
        buttons = []
        selection = nil
    }

    func update(_ field: NSTextField, base: URL, showHidden: Bool) {
        dismiss()
        self.field = field
        guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText(),
              !editor.string.isEmpty, Self.atEnd(editor) else { return }
        draft = editor.string
        task = Task { [weak self, weak editor, draft] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let paths = try await AddressCompletion.suggestions(for: draft, relativeTo: base, showHidden: showHidden)
                try Task.checkCancellation()
                guard let self else { return }
                self.task = nil
                guard let editor, self.field?.currentEditor() === editor, editor.string == draft,
                      !editor.hasMarkedText(), Self.atEnd(editor) else { return }
                if !paths.isEmpty { self.show(paths) }
            } catch {
                if !Task.isCancelled { self?.task = nil }
            }
        }
    }

    private static func atEnd(_ editor: NSTextView) -> Bool {
        editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0)
    }

    private func show(_ paths: [String]) {
        guard let field, let surface = field.window?.contentView else { return }
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 5
        box.contentViewMargins = NSSize(width: 4, height: 4)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        choices = paths
        for (index, path) in paths.enumerated() {
            let name = (String(path.dropLast()) as NSString).lastPathComponent
            let button = NSButton(title: name, target: self, action: #selector(clicked(_:)))
            button.isBordered = false
            button.refusesFirstResponder = true
            button.alignment = .left
            button.tag = index
            button.toolTip = path
            button.setAccessibilityLabel(path)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            buttons.append(button)
        }
        box.contentView = stack
        box.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            box.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 2),
            box.heightAnchor.constraint(equalToConstant: stack.fittingSize.height + 8)
        ])
        panel = box
    }

    func handle(_ command: Selector, editor: NSTextView, complete: (String) -> Void) -> Bool {
        guard !editor.hasMarkedText() else { dismiss(); return false }
        guard !choices.isEmpty, draft == editor.string, Self.atEnd(editor) else { dismiss(); return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let down = command == #selector(NSResponder.moveDown(_:))
            let index = selection.map { ($0 + (down ? 1 : choices.count - 1)) % choices.count } ?? (down ? 0 : choices.count - 1)
            selection = index
            for button in buttons {
                let selected = button.tag == index
                button.wantsLayer = true
                button.layer?.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.cgColor : nil
                button.contentTintColor = selected ? .alternateSelectedControlTextColor : .labelColor
            }
            NSAccessibility.post(element: buttons[index], notification: .selectedChildrenChanged)
        case #selector(NSResponder.insertTab(_:)):
            complete(choices[selection ?? 0])
        case #selector(NSResponder.insertNewline(_:)):
            guard let selection else { dismiss(); return false }
            accept(choices[selection])
        default:
            dismiss()
            return false
        }
        return true
    }

    @objc private func clicked(_ button: NSButton) {
        guard choices.indices.contains(button.tag) else { return }
        accept(choices[button.tag])
    }

    private func accept(_ path: String) {
        dismiss()
        field?.stringValue = path
        submit?()
    }
}
