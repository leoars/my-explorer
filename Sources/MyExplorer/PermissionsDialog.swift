// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
enum PermissionsDialog {
    static func present(for entry: FileEntry, in window: NSWindow) {
        Task {
            do {
                let url = entry.url
                let permissions = try await Task.detached { try ItemPermissions.inspect(url) }.value
                guard window.isVisible else { return }
                let alert = NSAlert()
                alert.messageText = L10n.text("permissions.title")
                alert.informativeText = entry.name
                let grid = NSGridView()
                grid.columnSpacing = 12
                grid.rowSpacing = 6
                let names = ["permissions.read", "permissions.write", "permissions.execute"].map(L10n.text)
                grid.addRow(with: [NSView()] + names.map { NSTextField(labelWithString: $0) })
                var bits: [(UInt16, NSButton)] = []
                for (row, label) in [L10n.text("permissions.owner") + " · " + permissions.owner,
                                     L10n.text("permissions.group") + " · " + permissions.group, L10n.text("permissions.others")].enumerated() {
                    var views: [NSView] = [NSTextField(labelWithString: label)]
                    for col in 0..<3 {
                        let mask = UInt16(1 << (8 - row * 3 - col))
                        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                        check.state = permissions.mode & mask != 0 ? .on : .off
                        check.isEnabled = permissions.canEdit
                        check.setAccessibilityLabel(label + ", " + names[col])
                        bits.append((mask, check))
                        views.append(check)
                    }
                    grid.addRow(with: views)
                }
                let effective = zip(names, permissions.effectiveAccess).compactMap { $0.1 ? $0.0 : nil }
                let summary = NSTextField(wrappingLabelWithString: L10n.text("permissions.effective") + " · "
                    + (effective.isEmpty ? "—" : effective.joined(separator: ", ")))
                let stack = NSStackView(views: [grid, summary])
                stack.orientation = .vertical
                stack.alignment = .leading
                if let acl = permissions.acl {
                    let text = NSTextView()
                    text.isEditable = false
                    text.string = acl
                    text.setAccessibilityLabel("ACL")
                    let scroll = NSScrollView()
                    scroll.hasVerticalScroller = true
                    scroll.documentView = text
                    scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
                    scroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
                    text.frame.size.width = 400
                    text.autoresizingMask = [.width]
                    stack.addArrangedSubview(scroll)
                }
                stack.frame.size = stack.fittingSize
                alert.accessoryView = stack
                let commit = permissions.canEdit
                if commit { alert.addButton(withTitle: L10n.text("dialog.confirm")) }
                alert.addButton(withTitle: L10n.text(commit ? "dialog.cancel" : "dialog.confirm"))
                let response = await alert.beginSheetModal(for: window)
                guard commit && response == .alertFirstButtonReturn else { return }
                let result = bits.reduce(UInt16(0)) { $0 | ($1.1.state == .on ? $1.0 : 0) }
                if result != permissions.mode & 0o777 {
                    try await Task.detached { try permissions.apply(accessBits: result, to: url) }.value
                }
            } catch {
                let alert = NSAlert(error: error)
                _ = await alert.beginSheetModal(for: window)
            }
        }
    }
}
