// SPDX-License-Identifier: Apache-2.0
import AppKit
import UniformTypeIdentifiers
import ExplorerCore
import Darwin

/// One explicit local OCR session. Closing or restarting invalidates every late callback.
@MainActor
final class OCRWindowController: DialogWindowController, NSTextViewDelegate {
    private let filename = ExplorerStyle.label("", area: .files)
    private let languageLabel = ExplorerStyle.label("")
    let languagePicker = NSPopUpButton()
    private let startButton = NSButton()
    private let cancelButton = NSButton()
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let pdfButton = NSButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    let textView = NSTextView()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var languages: [String] = []
    private var sourceURL: URL?
    private var result: OCRResult?
    private var statusKey = "ocr.preparing"
    private var lastProgress: OCRProgress?
    private var saving = false
    private var activeExportURL: URL?
    private var exportingPDF = false
    private var cancellationRequested = false
    private(set) var exportedPDFURL: URL?
    private var savePanel: NSSavePanel?
    private let discoverLanguages: @Sendable () async throws -> [String]
    private(set) var isRunning = false
    func usesFiles(where matches: (URL) -> Bool) -> Bool {
        [sourceURL, activeExportURL, exportedPDFURL, savePanel?.directoryURL].compactMap { $0 }.contains(where: matches)
    }
    var resultText: String { textView.string }
    var statusText: String { status.stringValue }
    nonisolated private static let exportQueue = DispatchQueue(label: "MyExplorer.OCR.Export", qos: .utility)

    init(discoverLanguages: @escaping @Sendable () async throws -> [String] = { try await OCRService().supportedLanguages() }) {
        self.discoverLanguages = discoverLanguages
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.delegate = self
        window.setAccessibilityIdentifier("explorer.ocr.window")
        buildInterface()
        reloadAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(_ url: URL) {
        savePanel?.cancel(nil); savePanel = nil
        cancelWork()
        sourceURL = url
        result = nil; lastProgress = nil; textView.string = ""; exportedPDFURL = nil
        textView.undoManager?.removeAllActions()
        filename.stringValue = url.lastPathComponent
        filename.toolTip = url.path
        window?.title = "\(url.lastPathComponent) — \(L10n.text("ocr.title"))"
        languages = []; rebuildLanguages()
        showStatus("ocr.preparing")
        setRunning(true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        let ticket = generation
        let discover = discoverLanguages
        task = Task { [weak self] in
            do {
                let available = try await discover()
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.languages = available
                self.rebuildLanguages()
                self.setRunning(false)
                guard !available.isEmpty else { self.showStatus("ocr.error.options"); return }
                self.startRecognition(nil)
            } catch {
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.setRunning(false); self.showError(error)
            }
        }
    }

    @objc func startRecognition(_ sender: Any?) {
        guard let sourceURL else { return }
        guard !languages.isEmpty else { open(sourceURL); return }
        cancelWork()
        result = nil; lastProgress = nil; textView.string = ""; exportedPDFURL = nil
        textView.undoManager?.removeAllActions()
        let selected = languagePicker.selectedItem?.representedObject as? String
        let request = OCRRequest(url: sourceURL, languages: selected.map { [$0] } ?? [])
        let ticket = generation
        setRunning(true); showStatus("ocr.preparing")
        task = Task { [weak self] in
            do {
                let result = try await AppAutomation.files.ocr(request, progress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == ticket, self.isRunning else { return }
                        self.lastProgress = value; self.renderStatus()
                    }
                })
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.result = result
                self.textView.string = result.fullText
                self.textView.undoManager?.removeAllActions()
                self.lastProgress = nil
                self.setRunning(false)
                self.showStatus(result.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ocr.empty" : "ocr.completed")
            } catch {
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.setRunning(false); self.showError(error)
            }
        }
    }

    @objc func cancelRecognition(_ sender: Any?) {
        if exportingPDF {
            // The writer reports success if atomic publication already won the cancellation race.
            cancellationRequested = true; task?.cancel(); updateControls(); renderStatus()
            return
        }
        cancelWork(); lastProgress = nil; setRunning(false)
        showStatus("cloud.error.cancelled")
    }
    private func cancelWork() {
        generation &+= 1; task?.cancel(); task = nil
        activeExportURL = nil
        exportingPDF = false; cancellationRequested = false
        progress.stopAnimation(nil)
    }
    override func close() {
        cleanup(); super.close()
    }
    func windowWillClose(_ notification: Notification) { cleanup() }
    private func cleanup() {
        savePanel?.cancel(nil); savePanel = nil
        cancelWork(); setRunning(false)
    }
    @objc func copyText(_ sender: Any?) {
        guard !isRunning, !textView.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
    @objc private func saveText(_ sender: Any?) {
        guard let window, !isRunning, !saving, !textView.string.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "OCR") + ".txt"
        panel.message = L10n.text("ocr.save_note")
        let text = textView.string, ticket = generation
        savePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.generation == ticket else { return }
            self.savePanel = nil
            guard response == .OK, let url = panel.url else { return }
            self.saving = true; self.updateControls()
            Task { [weak self] in
                do {
                    try await Self.exportText(text, to: url)
                    guard let self else { return }
                    self.saving = false; self.updateControls()
                    if self.generation == ticket { self.showStatus("ocr.saved") }
                } catch {
                    guard let self else { return }
                    self.saving = false; self.updateControls()
                    if self.generation == ticket { self.showStatus("ocr.save_failed") }
                }
            }
        }
    }
    @objc private func saveSearchablePDF(_ sender: Any?) {
        guard let window, let sourceURL, !isRunning, !saving, savePanel == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-OCR.pdf"
        panel.message = L10n.text("ocr.pdf_note")
        let ticket = generation
        savePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.generation == ticket else { return }
            self.savePanel = nil
            guard response == .OK, let url = panel.url else { return }
            self.startPDFExport(to: url)
        }
    }
    /// Re-read the source: edits in the plain-text view have no page geometry.
    func startPDFExport(to destination: URL) {
        guard let sourceURL, !isRunning, !saving else { return }
        cancelWork()
        let selected = languagePicker.selectedItem?.representedObject as? String
        let request = SearchablePDFRequest(sourceURL: sourceURL, destinationURL: destination,
                                          languages: selected.map { [$0] } ?? [])
        let ticket = generation
        activeExportURL = destination
        exportedPDFURL = nil; lastProgress = nil
        exportingPDF = true; setRunning(true); showStatus("ocr.pdf_preparing")
        task = Task { [weak self] in
            do {
                let result = try await AppAutomation.files.searchablePDF(request, progress: { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == ticket, self.isRunning else { return }
                        self.lastProgress = value; self.renderStatus()
                    }
                })
                guard let self, self.generation == ticket else { return }
                self.exportedPDFURL = result.destinationURL
                self.activeExportURL = nil; self.lastProgress = nil; self.exportingPDF = false; self.cancellationRequested = false
                self.setRunning(false); self.showStatus("ocr.pdf_saved")
            } catch {
                guard let self, self.generation == ticket else { return }
                self.activeExportURL = nil; self.lastProgress = nil; self.exportingPDF = false; self.cancellationRequested = false
                self.setRunning(false); self.showPDFError(error)
            }
        }
    }
    private func showPDFError(_ error: Error) {
        if let failure = error as? SearchablePDFFailure {
            switch failure.reason {
            case .destinationExists: showStatus("ocr.pdf_exists")
            case .unsupportedDocument: showStatus("ocr.pdf_unsupported")
            case .publicationIndeterminate: showStatus("ocr.pdf_indeterminate")
            case .cancelled: showStatus("cloud.error.cancelled")
            case .limitExceeded: showStatus("ocr.pdf_limit")
            case .timedOut: showStatus("ocr.error.timeout")
            case .sourceChanged: showStatus("ocr.error.changed")
            case .busy: showStatus("ocr.error.busy")
            default: showStatus("ocr.pdf_failed")
            }
        } else if error is CancellationError { showStatus("cloud.error.cancelled") }
        else if error is OCRFailure { showError(error) }
        else { showStatus("ocr.pdf_failed") }
    }
    /// Exclusive creation protects the input and every existing destination, including symlinks.
    nonisolated static func exportText(_ text: String, to url: URL) async throws {
        guard url.isFileURL, url.user == nil, url.password == nil, url.port == nil,
              url.host == nil || url.host == "" || url.host == "localhost", url.query == nil, url.fragment == nil,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.utf8.contains(0), text.utf8.count <= 128 * 1024 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportQueue.async {
                do {
                    guard !LocalTransferRecovery.isProtected(url) else { throw CocoaError(.fileWriteNoPermission) }
                    let staging = url.deletingLastPathComponent().appendingPathComponent(".my-explorer-ocr-export-\(UUID().uuidString)", isDirectory: true)
                    guard mkdir(staging.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let payload = staging.appendingPathComponent("text.txt")
                    try Data(text.utf8).write(to: payload, options: .withoutOverwriting)
                    guard chmod(payload.path, 0o600) == 0, !LocalTransferRecovery.isProtected(url) else { throw CocoaError(.fileWriteNoPermission) }
                    // A completed UTF-8 copy becomes visible in one exclusive rename.
                    guard renamex_np(payload.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func textDidChange(_ notification: Notification) { updateControls() }

    private func setRunning(_ value: Bool) {
        isRunning = value
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        updateControls()
    }
    private func updateControls() {
        startButton.isEnabled = !isRunning && sourceURL != nil
        languagePicker.isEnabled = !isRunning && !languages.isEmpty
        cancelButton.isEnabled = isRunning && !cancellationRequested
        copyButton.isEnabled = !isRunning && !textView.string.isEmpty
        saveButton.isEnabled = !isRunning && !saving && !textView.string.isEmpty
        pdfButton.isEnabled = !isRunning && !saving && sourceURL != nil && !languages.isEmpty
        textView.isEditable = !isRunning && result != nil
    }
    private func showStatus(_ key: String) { statusKey = key; renderStatus() }
    private func renderStatus() {
        if cancellationRequested {
            status.stringValue = L10n.text("operation.cancelling")
        } else if let value = lastProgress, isRunning, value.totalPages > 0 {
            status.stringValue = L10n.format("ocr.progress", L10n.current.number(value.completedPages), L10n.current.number(value.totalPages))
        } else if statusKey == "ocr.completed", let result {
            let recognized = result.pages.filter { $0.source == .recognized }.count
            status.stringValue = L10n.current.text("ocr.completed", L10n.current.number(result.pages.count),
                L10n.current.number(recognized), L10n.current.number(result.pages.count - recognized))
        } else { status.stringValue = L10n.text(statusKey) }
    }
    private func showError(_ error: Error) {
        lastProgress = nil
        guard let failure = error as? OCRFailure else { showStatus("ocr.error.unavailable"); return }
        switch failure.reason {
        case .cancelled: showStatus("cloud.error.cancelled")
        case .needsDownload: showStatus("preview.needs_download")
        case .limitExceeded: showStatus("ocr.error.limit")
        case .invalidRequest: showStatus("ocr.error.options")
        case .timedOut: showStatus("ocr.error.timeout")
        case .sourceChanged: showStatus("ocr.error.changed")
        case .busy: showStatus("ocr.error.busy")
        default: showStatus("ocr.error.unavailable")
        }
    }
    private func rebuildLanguages() {
        let selected = languagePicker.selectedItem?.representedObject as? String
        languagePicker.removeAllItems()
        languagePicker.addItem(withTitle: L10n.text("ocr.automatic"))
        for identifier in languages {
            let title = L10n.current.locale.localizedString(forIdentifier: identifier) ?? identifier
            languagePicker.addItem(withTitle: "\(title) (\(identifier))")
            languagePicker.lastItem?.representedObject = identifier
        }
        if let selected, let item = languagePicker.itemArray.first(where: { $0.representedObject as? String == selected }) {
            languagePicker.select(item)
        }
    }
    func reloadAppearance() {
        window?.title = sourceURL.map { "\($0.lastPathComponent) — \(L10n.text("ocr.title"))" } ?? L10n.text("ocr.title")
        languageLabel.stringValue = L10n.text("ocr.language")
        note.stringValue = L10n.text("ocr.note")
        pdfButton.toolTip = L10n.text("ocr.pdf_note")
        for (button, key) in [(startButton, "ocr.extract"), (cancelButton, "dialog.cancel"), (copyButton, "ocr.copy"), (saveButton, "ocr.save"), (pdfButton, "ocr.pdf_save")] {
            button.title = L10n.text(key); button.font = ExplorerStyle.font(.bars)
        }
        for label in [filename, languageLabel, status, note] { label.font = ExplorerStyle.font(.bars) }
        textView.font = ExplorerStyle.font(.files)
        textView.setAccessibilityLabel(L10n.text("ocr.result"))
        languagePicker.setAccessibilityLabel(L10n.text("ocr.language"))
        rebuildLanguages(); renderStatus()
    }
    private func buildInterface() {
        let root = ExplorerSurface(); window?.contentView = root
        filename.lineBreakMode = .byTruncatingMiddle
        filename.setAccessibilityIdentifier("explorer.ocr.filename")
        languagePicker.setAccessibilityIdentifier("explorer.ocr.language")
        languagePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        for (button, action, id) in [(startButton, #selector(startRecognition), "start"), (cancelButton, #selector(cancelRecognition), "cancel"),
                                     (copyButton, #selector(copyText), "copy"), (saveButton, #selector(saveText), "save"),
                                     (pdfButton, #selector(saveSearchablePDF), "pdf")] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("explorer.ocr.\(id)")
        }
        let controls = ExplorerStyle.stack([languageLabel, languagePicker, startButton, cancelButton])
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let state = ExplorerStyle.stack([progress, status])
        status.setAccessibilityIdentifier("explorer.ocr.status")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        textView.isRichText = false; textView.allowsUndo = true; textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false; textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 10, height: 10); textView.delegate = self
        textView.setAccessibilityIdentifier("explorer.ocr.text")
        scroll.documentView = textView
        note.textColor = .secondaryLabelColor
        let actions = ExplorerStyle.stack([copyButton, saveButton])
        let stack = NSStackView(views: [filename, controls, state, scroll, note, actions, pdfButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            filename.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160), note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            state.widthAnchor.constraint(equalTo: stack.widthAnchor), controls.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        updateControls()
    }
}
