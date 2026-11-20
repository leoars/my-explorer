// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
final class OCRBatchWindowController: DialogWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let destinationLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton()
    private let languageLabel = NSTextField(labelWithString: "")
    let languagePicker = NSPopUpButton()
    private let startButton = NSButton()
    private let cancelButton = NSButton()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    let table = NSTableView()
    private var sources: [URL] = []
    private(set) var destinationDirectory: URL?
    private var languages: [String] = []
    private var task: Task<Void, Never>?
    private var discovery: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var panel: NSOpenPanel?
    private var cancellationRequested = false
    private var discovering = false
    private var discoveryFailed = false
    private var currentProgress: SearchablePDFBatchProgress?
    private(set) var report: SearchablePDFBatchResult?
    private var completed: [SearchablePDFBatchItem] = []
    private(set) var isRunning = false
    func usesFiles(where matches: (URL) -> Bool) -> Bool {
        sources.contains(where: matches) || [destinationDirectory, panel?.directoryURL].compactMap { $0 }.contains(where: matches)
    }
    var statusText: String { status.stringValue }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 700, height: 450)
        window.setAccessibilityIdentifier("explorer.ocr.batch.window")
        buildInterface(); reloadAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func open(_ urls: [URL]) {
        // A new selection must not replace the report of a running batch.
        if isRunning { showWindow(nil); window?.makeKeyAndOrderFront(nil); return }
        cleanup()
        sources = urls; destinationDirectory = urls.first?.deletingLastPathComponent()
        report = nil; completed = []; currentProgress = nil; languages = []
        discoveryFailed = false; discovering = true
        reloadAppearance(); updateControls()
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        let ticket = generation
        discovery = Task { [weak self] in
            do {
                let values = try await AppAutomation.files.ocrLanguages()
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.languages = values; self.discovering = false; self.discoveryFailed = values.isEmpty
                self.rebuildLanguages(); self.updateControls(); self.renderStatus()
            } catch {
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.discovering = false; self.discoveryFailed = true; self.updateControls(); self.renderStatus()
            }
        }
    }
    func setDestination(_ url: URL) {
        guard !isRunning else { return }
        destinationDirectory = url; renderDestination(); updateControls()
    }
    @objc private func chooseDestination(_ sender: Any?) {
        guard let window, !isRunning, panel == nil else { return }
        let next = NSOpenPanel(); next.canChooseDirectories = true; next.canChooseFiles = false
        next.allowsMultipleSelection = false; next.canCreateDirectories = true
        next.directoryURL = destinationDirectory; next.message = L10n.text("ocr.batch.choose")
        panel = next; let ticket = generation
        next.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.generation == ticket else { return }
            self.panel = nil
            if response == .OK, let url = next.url { self.setDestination(url) }
        }
    }
    @objc func startBatch(_ sender: Any?) {
        guard !isRunning, !discovering, !languages.isEmpty, let destinationDirectory,
              (1...50).contains(sources.count) else { return }
        panel?.cancel(nil); panel = nil
        generation &+= 1; let ticket = generation
        cancellationRequested = false; report = nil; completed = []; currentProgress = nil
        let language = languagePicker.selectedItem?.representedObject as? String
        let request = SearchablePDFBatchRequest(sourceURLs: sources, destinationDirectoryURL: destinationDirectory,
                                              languages: language.map { [$0] } ?? [])
        isRunning = true; updateControls(); renderStatus(); table.reloadData()
        task = Task { [weak self] in
            do {
                let result = try await AppAutomation.files.searchablePDFBatch(request, progress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == ticket, self.isRunning else { return }
                        guard value.completedResults.count >= self.completed.count, value.index >= (self.currentProgress?.index ?? 0) else { return }
                        self.currentProgress = value; self.completed = value.completedResults
                        self.table.reloadData(); self.renderStatus()
                    }
                })
                guard let self, self.generation == ticket else { return }
                self.report = result; self.completed = result.items
                self.isRunning = false; self.cancellationRequested = false; self.currentProgress = nil
                self.table.reloadData(); self.updateControls(); self.renderStatus()
            } catch {
                guard let self, self.generation == ticket else { return }
                self.isRunning = false; self.cancellationRequested = false; self.currentProgress = nil
                let reason = (error as? SearchablePDFFailure)?.reason ?? (error is CancellationError ? .cancelled : .unavailable)
                self.completed += self.sources.dropFirst(self.completed.count).map { .init(sourceURL: $0, state: .notStarted, reason: reason) }
                self.report = .init(items: self.completed)
                self.table.reloadData(); self.updateControls(); self.renderStatus()
            }
        }
    }
    @objc func cancelBatch(_ sender: Any?) {
        guard isRunning else { return }
        cancellationRequested = true; task?.cancel(); updateControls(); renderStatus()
    }
    private func cleanup() {
        generation &+= 1; task?.cancel(); task = nil; discovery?.cancel(); discovery = nil
        panel?.cancel(nil); panel = nil
        isRunning = false; cancellationRequested = false; discovering = false
        spinner.stopAnimation(nil)
    }
    override func close() { cleanup(); super.close() }
    func windowWillClose(_ notification: Notification) { cleanup() }
    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sources.indices.contains(row) else { return nil }
        let cell = NSTextField(labelWithString: ""); cell.font = ExplorerStyle.font(.files)
        cell.lineBreakMode = .byTruncatingTail
        let item = completed.indices.contains(row) ? completed[row] : nil
        switch tableColumn?.identifier.rawValue {
        case "source": cell.stringValue = sources[row].lastPathComponent; cell.toolTip = sources[row].path
        case "state":
            let state = item?.state.rawValue ?? (isRunning && currentProgress?.index == row + 1 ? "running" : "waiting")
            cell.stringValue = L10n.text("ocr.batch." + state); cell.toolTip = cell.stringValue
        default:
            if item?.state == .succeeded, let url = item?.destinationURL {
                cell.stringValue = url.lastPathComponent; cell.toolTip = url.path
            } else if let item {
                cell.stringValue = item.reason.map { Self.errorText($0) } ?? ""
                cell.toolTip = [cell.stringValue, item.destinationURL?.path].compactMap { $0 }.joined(separator: "\n")
            }
        }
        return cell
    }
    private func updateControls() {
        startButton.isEnabled = !isRunning && !discovering && !languages.isEmpty && (1...50).contains(sources.count) && destinationDirectory != nil
        chooseButton.isEnabled = !isRunning; languagePicker.isEnabled = !isRunning && !languages.isEmpty
        cancelButton.isEnabled = isRunning && !cancellationRequested
        if isRunning || discovering { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    private func renderStatus() {
        if cancellationRequested { status.stringValue = L10n.text("operation.cancelling") }
        else if isRunning, let value = currentProgress {
            status.stringValue = L10n.format("ocr.batch.progress", L10n.current.number(value.index), L10n.current.number(value.total))
            if let page = value.page, page.totalPages > 0 {
                status.stringValue += " — " + L10n.format("ocr.progress", L10n.current.number(page.completedPages), L10n.current.number(page.totalPages))
            }
        } else if let report {
            let counts = [SearchablePDFBatchItem.State.succeeded, .failed, .cancelled, .notStarted, .needsInput].map { state in
                L10n.current.number(report.items.filter { $0.state == state }.count)
            }
            status.stringValue = L10n.current.text("ocr.batch.summary", counts[0], counts[1], counts[2], counts[3], counts[4])
        } else if discoveryFailed { status.stringValue = L10n.text("ocr.batch.no_languages") }
        else if discovering || isRunning { status.stringValue = L10n.text("ocr.pdf_preparing") }
        else { status.stringValue = L10n.format("ocr.batch.ready", L10n.current.number(sources.count)) }
    }
    private func renderDestination() {
        destinationLabel.stringValue = L10n.text("ocr.batch.destination") + ": " + (destinationDirectory?.path ?? "—")
        destinationLabel.toolTip = destinationDirectory?.path
    }
    private func rebuildLanguages() {
        let selected = languagePicker.selectedItem?.representedObject as? String
        languagePicker.removeAllItems(); languagePicker.addItem(withTitle: L10n.text("ocr.automatic"))
        for language in languages {
            languagePicker.addItem(withTitle: "\(L10n.current.locale.localizedString(forIdentifier: language) ?? language) (\(language))")
            languagePicker.lastItem?.representedObject = language
        }
        if let item = languagePicker.itemArray.first(where: { $0.representedObject as? String == selected }), selected != nil { languagePicker.select(item) }
    }
    func reloadAppearance() {
        window?.title = L10n.text("ocr.batch.title")
        for (button, key) in [(chooseButton, "ocr.batch.choose"), (startButton, "ocr.batch.start"), (cancelButton, "dialog.cancel")] {
            button.title = L10n.text(key); button.font = ExplorerStyle.font(.bars)
        }
        languageLabel.stringValue = L10n.text("ocr.language"); note.stringValue = L10n.text("ocr.batch.note")
        for label in [languageLabel, destinationLabel, note, status] { label.font = ExplorerStyle.font(.bars) }
        for column in table.tableColumns { column.title = L10n.text("ocr.batch." + (column.identifier.rawValue == "result" ? "output" : column.identifier.rawValue)) }
        table.rowHeight = max(28, ExplorerStyle.font(.files).pointSize + 12)
        if let window {
            let minimumHeight = max(510, ExplorerStyle.font(.bars).pointSize * 18 + 240)
            window.minSize = NSSize(width: 700, height: minimumHeight)
            if window.frame.height < minimumHeight {
                var frame = window.frame; frame.size.height = minimumHeight; window.setFrame(frame, display: true)
            }
        }
        rebuildLanguages(); renderDestination(); renderStatus(); table.reloadData()
    }
    private static func errorText(_ reason: SearchablePDFFailure.Reason?) -> String {
        switch reason {
        case .cancelled: return L10n.text("cloud.error.cancelled")
        case .destinationExists: return L10n.text("ocr.pdf_exists")
        case .unsupportedDocument: return L10n.text("ocr.pdf_unsupported")
        case .publicationIndeterminate: return L10n.text("ocr.pdf_indeterminate")
        case .limitExceeded: return L10n.text("ocr.pdf_limit")
        case .invalidRequest: return L10n.text("ocr.batch.invalid")
        case .busy: return L10n.text("ocr.error.busy")
        case .needsDownload: return L10n.text("preview.needs_download")
        case .timedOut: return L10n.text("ocr.error.timeout")
        case .sourceChanged: return L10n.text("ocr.error.changed")
        default: return L10n.text("ocr.pdf_failed")
        }
    }
    private func buildInterface() {
        let root = ExplorerSurface(); window?.contentView = root
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.setAccessibilityIdentifier("explorer.ocr.batch.destination")
        for (button, action, id) in [(chooseButton, #selector(chooseDestination), "choose"), (startButton, #selector(startBatch), "start"), (cancelButton, #selector(cancelBatch), "cancel")] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("explorer.ocr.batch.\(id)")
        }
        languagePicker.setAccessibilityIdentifier("explorer.ocr.batch.language")
        languagePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 350).isActive = true
        let controls = ExplorerStyle.stack([languageLabel, languagePicker])
        let actions = ExplorerStyle.stack([startButton, cancelButton])
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let statusRow = ExplorerStyle.stack([spinner, status]); status.setAccessibilityIdentifier("explorer.ocr.batch.status")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityIdentifier("explorer.ocr.batch.files")
        for (name, width) in [("source", 280.0), ("state", 130.0), ("result", 430.0)] {
            let column = NSTableColumn(identifier: .init(name)); column.width = width; column.minWidth = 70
            column.headerCell.lineBreakMode = .byTruncatingTail; table.addTableColumn(column)
        }
        scroll.documentView = table; note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [destinationLabel, chooseButton, controls, actions, statusRow, scroll, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            destinationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor), controls.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
    }
}
