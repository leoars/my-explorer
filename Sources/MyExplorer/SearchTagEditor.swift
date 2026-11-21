// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
enum SearchTagEditor {
    static func present(urls: [URL], owner: NSWindow) {
        guard !urls.isEmpty else { return }
        Task {
            do {
                let tags = try await Task.detached(priority: .userInitiated) {
                    var combined = Set<String>()
                    for url in urls { combined.formUnion(try FinderTags.read(url)) }
                    return combined.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                }.value
                guard owner.isVisible else { return }
                let alert = NSAlert()
                alert.messageText = L10n.text("search.tags_edit")
                alert.informativeText = L10n.text("search.tags") + " · " + (tags.isEmpty ? "—" : tags.joined(separator: ", "))
                let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
                field.addItems(withObjectValues: tags)
                field.completes = true
                field.placeholderString = L10n.text("search.tag_name")
                field.setAccessibilityLabel(L10n.text("search.tag_name"))
                alert.accessoryView = field
                alert.window.initialFirstResponder = field
                alert.addButton(withTitle: L10n.text("search.add"))
                alert.addButton(withTitle: L10n.text("search.remove"))
                alert.addButton(withTitle: L10n.text("dialog.cancel")).keyEquivalent = "\u{1b}"
                let response = await alert.beginSheetModal(for: owner)
                guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
                let tag = field.stringValue
                let add = response == .alertFirstButtonReturn
                let failures = await Task.detached(priority: .userInitiated) {
                    var failures: [String] = []
                    for url in urls {
                        do { try FinderTags.change(tag, add: add, at: url) }
                        catch { failures.append(url.path + " — " + error.localizedDescription) }
                    }
                    return failures
                }.value
                if !failures.isEmpty { showError(failures.joined(separator: "\n"), owner: owner) }
            } catch { showError(error.localizedDescription, owner: owner) }
        }
    }

    static func showError(_ text: String, owner: NSWindow) {
        guard owner.isVisible else { return }
        let error = NSAlert()
        error.alertStyle = .warning
        error.messageText = text
        error.beginSheetModal(for: owner)
    }
}
