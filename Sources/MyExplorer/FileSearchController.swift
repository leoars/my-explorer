// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
final class FileSearchController: DialogWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let name = NSTextField()
    private let ext = NSTextField()
    private let content = NSTextField()
    private let tag = NSTextField()
    private let scope = NSPopUpButton()
    private let date = NSPopUpButton()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private let revealButton = NSButton()
    private let cancelButton = NSButton()
    private let saveButton = NSButton()
    private let folder: URL
    private let onReveal: (URL) -> Void
    private let onSave: (ExplorerSavedSearch) throws -> Void
    private let subtreeWatcher = DirectoryWatcher(includeDescendants: true)
    private var rescanTask: Task<Void, Never>?
    private var needsRescan = false
    private var query: NSMetadataQuery?
    private var task: Task<Void, Never>?
    private var rows: [URL] = []
    private var active: ExplorerSearchSpec?
    nonisolated private static let limit = 2000

    init(folder: URL, saved: ExplorerSavedSearch?, onReveal: @escaping (URL) -> Void,
         onSave: @escaping (ExplorerSavedSearch) throws -> Void) {
        self.folder = saved?.spec.folder ?? folder
        self.onReveal = onReveal
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 535),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 630, height: 450)
        window.isReleasedWhenClosed = false
        window.title = saved?.title ?? L10n.text("search.title")
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let surface = window.contentView!
        surface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
                                     stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
                                     stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 16),
                                     stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -16)])
        scope.addItems(withTitles: ExplorerSearchSpec.Scope.allCases.map { L10n.text("search.scope." + $0.rawValue) })
        date.addItems(withTitles: ExplorerSearchSpec.Modified.allCases.map { L10n.text("search.date." + $0.rawValue) })
        scope.setAccessibilityLabel(L10n.text("search.scope"))
        date.setAccessibilityLabel(L10n.text("column.modified"))
        scope.target = self
        scope.action = #selector(scopeChanged)
        location.lineBreakMode = .byTruncatingMiddle
        location.textColor = .secondaryLabelColor
        location.toolTip = self.folder.path
        stack.addArrangedSubview(ExplorerStyle.stack([scope, location]))
        func pair(_ key: String, _ field: NSTextField) -> [NSView] {
            let label = NSTextField(labelWithString: L10n.text(key))
            field.setAccessibilityLabel(label.stringValue)
            field.target = self
            field.action = #selector(run)
            return [label, field]
        }
        let grid = NSGridView(views: [pair("column.name", name) + pair("search.ext", ext),
                                      pair("search.content", content) + pair("search.tag_name", tag)])
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.column(at: 1).width = 245
        grid.column(at: 3).xPlacement = .fill
        stack.addArrangedSubview(grid)
        setup(cancelButton, "dialog.cancel", #selector(cancelSearch))
        setup(saveButton, "search.save", #selector(save))
        setup(revealButton, "search.reveal", #selector(reveal))
        let searchButton = NSButton(title: L10n.text("search.run"), target: self, action: #selector(run))
        stack.addArrangedSubview(ExplorerStyle.stack([NSTextField(labelWithString: L10n.text("column.modified")), date,
                                                     NSView(), searchButton, cancelButton, saveButton]))
        for (id, key, width) in [("name","column.name",230.0), ("origin","properties.path",460.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = L10n.text(key)
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(reveal)
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel(L10n.text("search.title"))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        stack.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        stack.addArrangedSubview(ExplorerStyle.stack([status, NSView(), revealButton]))
        window.initialFirstResponder = name
        let spec = saved?.spec ?? ExplorerSearchSpec(folder: folder)
        scope.selectItem(at: ExplorerSearchSpec.Scope.allCases.firstIndex(of: spec.scope)!)
        date.selectItem(at: ExplorerSearchSpec.Modified.allCases.firstIndex(of: spec.modified)!)
        name.stringValue = spec.name
        ext.stringValue = spec.fileExtension
        content.stringValue = spec.content
        tag.stringValue = spec.tag
        scopeChanged()
        cancelButton.isEnabled = false
        saveButton.isEnabled = false
        revealButton.isEnabled = false
        if saved != nil { run() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(_ button: NSButton, _ key: String, _ action: Selector) {
        button.title = L10n.text(key); button.target = self; button.action = action; button.bezelStyle = .rounded
    }

    @objc private func scopeChanged() {
        let choice = ExplorerSearchSpec.Scope.allCases[scope.indexOfSelectedItem]
        content.isEnabled = choice != .walkFolder
        location.stringValue = choice == .computer ? "" : folder.path
    }

    private func spec() -> ExplorerSearchSpec {
        var spec = ExplorerSearchSpec(folder: folder)
        spec.scope = ExplorerSearchSpec.Scope.allCases[scope.indexOfSelectedItem]
        spec.modified = ExplorerSearchSpec.Modified.allCases[date.indexOfSelectedItem]
        spec.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        spec.fileExtension = ext.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        spec.content = content.isEnabled ? content.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        spec.tag = tag.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return spec
    }

    @objc private func run() {
        stop()
        replaceRows([])
        let criteria = spec()
        guard criteria.hasCriteria else { status.stringValue = L10n.text("search.criteria"); return }
        active = criteria
        saveButton.isEnabled = true
        cancelButton.isEnabled = true
        #if APP_STORE
        // In the sandbox a folder without access finds nothing, in Spotlight or walking it: say why.
        if criteria.scope != .computer, !Self.canOpen(folder) {
            status.stringValue = L10n.text("access.search_denied")
            cancelButton.isEnabled = false
            return
        }
        #endif
        status.stringValue = L10n.text("search.running")
        if criteria.scope == .walkFolder {
            subtreeWatcher.watch(folder) { [weak self] in self?.scheduleRescan() }
            scan(criteria)
            return
        }
        let metadata = NSMetadataQuery()
        metadata.predicate = criteria.predicate()
        metadata.searchScopes = criteria.scope == .computer ? [NSMetadataQueryLocalComputerScope] : [folder]
        metadata.notificationBatchingInterval = 0.4
        query = metadata
        for event in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateIndex(_:)), name: event, object: metadata)
        }
        if !metadata.start() {
            stop()
            status.stringValue = L10n.text("search.index_hint")
        }
    }

    #if APP_STORE
    private static func canOpen(_ folder: URL) -> Bool {
        guard let directory = opendir(folder.path) else { return false }
        closedir(directory)
        return true
    }
    #endif

    private func scheduleRescan() {
        guard active?.scope == .walkFolder else { return }
        if task != nil { needsRescan = true; return }
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, let criteria = self.active else { return }
            self.scan(criteria)
        }
    }

    private func scan(_ criteria: ExplorerSearchSpec) {
        needsRescan = false
        task = Task { [weak self] in
            do {
                let result = try await criteria.walk(limit: Self.limit)
                try Task.checkCancellation()
                guard let self else { return }
                self.replaceRows(result.urls)
                self.status.stringValue = self.summary(truncated: result.truncated) + (result.unreadable > 0 ?
                    " · " + L10n.format("search.inaccessible", String(result.unreadable)) : "")
            } catch {
                guard !Task.isCancelled else { return }
                self?.status.stringValue = error.localizedDescription
            }
            self?.task = nil
            if self?.needsRescan == true { self?.scheduleRescan() }
        }
    }

    @objc private func updateIndex(_ notification: Notification) {
        guard let query, notification.object as? NSMetadataQuery === query else { return }
        query.disableUpdates()
        let count = query.resultCount
        let paths = (0..<min(count, Self.limit + 1)).compactMap {
            (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }
        query.enableUpdates()
        task?.cancel()
        task = Task { [weak self] in
            let urls = await withTaskGroup(of: [URL].self) { group in
                group.addTask(priority: .utility) {
                    var visible: [URL] = []
                    for path in paths {
                        if Task.isCancelled || visible.count == Self.limit { break }
                        let url = URL(fileURLWithPath: path)
                        if ExplorerSearchSpec.mayShow(url) { visible.append(url) }
                    }
                    return visible
                }
                return await group.next() ?? []
            }
            guard !Task.isCancelled, let self else { return }
            self.replaceRows(urls)
            self.status.stringValue = self.summary(truncated: count > Self.limit) + (urls.isEmpty ? " · " + L10n.text("search.index_hint") : "")
        }
    }

    private func summary(truncated: Bool) -> String {
        L10n.format(truncated ? "search.limited" : "search.count", String(rows.count))
    }

    private func replaceRows(_ urls: [URL]) {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        rows = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        table.reloadData()
        if let selected, let index = rows.firstIndex(of: selected) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        revealButton.isEnabled = table.selectedRow >= 0
    }

    private func stop() {
        subtreeWatcher.stop()
        needsRescan = false
        rescanTask?.cancel(); rescanTask = nil
        task?.cancel(); task = nil
        if let query {
            NotificationCenter.default.removeObserver(self, name: nil, object: query)
            query.stop()
            self.query = nil
        }
        active = nil
        cancelButton.isEnabled = false
        saveButton.isEnabled = false
    }
    @objc private func cancelSearch() { stop(); status.stringValue = L10n.text("search.stopped") }
    func windowWillClose(_ notification: Notification) { stop(); replaceRows([]) }

    @objc private func save() {
        guard let criteria = active, let window else { return }
        let panel = NSAlert()
        panel.messageText = L10n.text("search.save")
        let title = NSTextField(string: criteria.name)
        title.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        title.setAccessibilityLabel(L10n.text("column.name"))
        panel.accessoryView = title
        panel.window.initialFirstResponder = title
        panel.addButton(withTitle: L10n.text("dialog.confirm"))
        panel.addButton(withTitle: L10n.text("dialog.cancel"))
        panel.beginSheetModal(for: window) { [weak self] response in
            let text = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !text.isEmpty else { return }
            do { try self?.onSave(ExplorerSavedSearch(title: text, spec: criteria)) }
            catch { SearchTagEditor.showError(error.localizedDescription, owner: window) }
        }
    }

    #if !APP_STORE
    static func smoke(root: URL) async throws {
        let fm = FileManager.default
        let area = root.appendingPathComponent("Search-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: area) }
        let nested = area.appendingPathComponent("First/Second", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let target = nested.appendingPathComponent("Relatório.PDF")
        try Data().write(to: target)
        try FinderTags.change("Work", add: true, at: target)
        var criteria = ExplorerSearchSpec(folder: area)
        criteria.scope = .walkFolder
        criteria.fileExtension = "pdf"
        criteria.tag = "Work"
        let saved = ExplorerSavedSearch(title: "Work PDFs", spec: criteria)
        var revealed: URL?
        let search = FileSearchController(folder: area, saved: saved, onReveal: { revealed = $0 }, onSave: { _ in })
        search.showWindow(nil)
        defer { search.close() }
        func wait(_ message: String, _ accepted: () -> Bool) async throws {
            for _ in 0..<200 {
                if accepted() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw SmokeFailure.failed(message)
        }
        try await wait("Initial tagged search results") { search.rows == [target] }
        let copy = area.appendingPathComponent("First/Relatório.PDF")
        try Data().write(to: copy)
        try FinderTags.change("Work", add: true, at: copy)
        try await wait("Saved search refresh after external tag change") { Set(search.rows) == Set([target, copy]) }
        guard let index = search.rows.firstIndex(of: target) else { throw SmokeFailure.failed("Missing nested PDF") }
        search.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        search.revealButton.performClick(nil)
        guard revealed == target else { throw SmokeFailure.failed("Wrong result with duplicate file names") }
    }
    #endif

    @objc private func reveal() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let url = rows[table.selectedRow]
        onReveal(url)
        close()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { revealButton.isEnabled = table.selectedRow >= 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name" ?
                               rows[row].lastPathComponent : rows[row].deletingLastPathComponent().path)
        cell.lineBreakMode = .byTruncatingMiddle
        cell.toolTip = rows[row].path
        return cell
    }
}
