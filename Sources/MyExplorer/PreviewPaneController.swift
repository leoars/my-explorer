// SPDX-License-Identifier: Apache-2.0
import AppKit
import Quartz
import UniformTypeIdentifiers
import ExplorerCore
import ExplorerLocalization

/// Embeds native Quick Look without opening another window or fetching remote objects.
/// https://developer.apple.com/documentation/quicklookui/qlpreviewview
@MainActor
final class PreviewPaneController: NSViewController {
    private let heading = ExplorerStyle.label(L10n.text("preview.title"))
    private let fileName = ExplorerStyle.label("", color: .secondaryLabelColor, area: .files)
    private let placeholder = NSTextField(wrappingLabelWithString: L10n.text("preview.empty"))
    private let previewContainer = NSView()
    private let ocrButton = OutlinedButton()
    private let actionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let actionsStack = NSStackView()
    var onExtractText: ((URL) -> Void)?
    private var quickLook: QLPreviewView?
    private let imageView = NSImageView()
    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    var previewImageLoaded: Bool { imageView.image != nil && !imageView.isHidden }
    private var displayedEntry: FileEntry?
    private(set) var previewedURL: URL?
    var message: String { placeholder.isHidden ? "" : placeholder.stringValue }

    private let imageLoader: PreviewImageLoader

    init(imageLoader: PreviewImageLoader = .shared) {
        self.imageLoader = imageLoader
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        view.setAccessibilityIdentifier("explorer.preview.pane")
        view.setAccessibilityLabel(L10n.text("preview.title"))
        heading.font = ExplorerStyle.font(.bars, weight: .semibold)
        fileName.lineBreakMode = .byTruncatingMiddle
        fileName.setAccessibilityIdentifier("explorer.preview.filename")
        placeholder.font = ExplorerStyle.font(.files)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 0
        placeholder.setAccessibilityIdentifier("explorer.preview.message")
        ocrButton.title = L10n.text("ocr.title")
        ocrButton.font = ExplorerStyle.font(.bars)
        ocrButton.setContentHuggingPriority(.required, for: .vertical)
        ocrButton.target = self; ocrButton.action = #selector(extractText)
        ocrButton.isEnabled = false
        ocrButton.setAccessibilityIdentifier("explorer.preview.ocr")
        actionsStack.orientation = .vertical
        actionsStack.alignment = .leading
        actionsStack.spacing = 4
        actionsStack.setContentHuggingPriority(.required, for: .vertical)
        actionsStack.addArrangedSubview(ocrButton)
        actionsStack.addArrangedSubview(actionsButton)
        actionsButton.font = ExplorerStyle.font(.bars)
        actionsButton.bezelStyle = .regularSquare
        actionsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(actionsButton.font!.ascender - actionsButton.font!.descender) + 12).isActive = true
        actionsButton.setAccessibilityLabel(L10n.text("quick.title"))
        actionsButton.isHidden = true
        for child in [heading, fileName, actionsStack, previewContainer, placeholder] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isHidden = true
        imageView.setAccessibilityIdentifier("explorer.preview.image")
        previewContainer.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            fileName.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fileName.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            fileName.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            actionsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            actionsStack.topAnchor.constraint(equalTo: fileName.bottomAnchor, constant: 6),
            actionsStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            previewContainer.topAnchor.constraint(equalTo: actionsStack.bottomAnchor, constant: 10),
            previewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            placeholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    func update(entries: [FileEntry]) {
        loadViewIfNeeded()
        defer {
            if let menu = QuickActionCommands.menu(for: entries, in: view.window) {
                menu.insertItem(withTitle: L10n.text("quick.title"), action: nil, keyEquivalent: "", at: 0)
                actionsButton.menu = menu
                actionsButton.isHidden = false
            } else {
                actionsButton.menu = nil
                actionsButton.isHidden = true
            }
        }
        guard entries.count == 1, let entry = entries.first else {
            clear(messageKey: entries.isEmpty ? "preview.empty" : "preview.multiple")
            return
        }
        guard entry.url.isFileURL else { clear(messageKey: "preview.remote"); return }
        guard !entry.isDirectory else { clear(messageKey: "preview.folder"); return }
        fileName.stringValue = entry.displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions)
        fileName.toolTip = entry.name
        guard displayedEntry != entry || previewedURL != entry.url else { return }
        closePreview()
        displayedEntry = entry
        previewedURL = entry.url
        ocrButton.isEnabled = ExplorerWindowController.canExtractText([entry])
        imageView.setAccessibilityLabel(fileName.stringValue)
        placeholder.stringValue = L10n.text("status.loading")
        placeholder.isHidden = false
        let expectedGeneration = generation
        let isImage = UTType(filenameExtension: entry.url.pathExtension)?.conforms(to: .image) == true
        let pointEdge = max(previewContainer.bounds.width, previewContainer.bounds.height)
        let rawEdge = pointEdge * (view.window?.backingScaleFactor ?? 2)
        let pixelEdge = rawEdge.isFinite ? Int(ceil(min(1600, max(320, rawEdge)))) : 640
        let loader = imageLoader
        // Coalesce keyboard navigation before opening any payload or starting Quick Look.
        loadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                await loader.prepare(entry, image: isImage, maximumEdge: pixelEdge)
            }
            let prepared = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.generation == expectedGeneration,
                  self.previewedURL == entry.url else { return }
            self.loadTask = nil
            self.timeoutTask?.cancel(); self.timeoutTask = nil
            switch prepared {
            case .image(let thumbnail):
                self.imageView.image = NSImage(cgImage: thumbnail.image, size: NSSize(width: thumbnail.image.width, height: thumbnail.image.height))
                self.imageView.isHidden = false
                self.placeholder.isHidden = true
            case .quickLook(let url): self.installQuickLook(url)
            case .needsDownload: self.clear(messageKey: "preview.needs_download")
            case .unavailable: self.clear(messageKey: "preview.unavailable")
            }
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.generation == expectedGeneration else { return }
            self.clear(messageKey: "preview.unavailable")
        }
    }

    private func installQuickLook(_ url: URL) {
        guard let preview = QLPreviewView(frame: previewContainer.bounds, style: .compact) else {
            clear(messageKey: "preview.unavailable"); return
        }
        preview.autostarts = false
        preview.shouldCloseWithWindow = false // This controller owns explicit cancellation/teardown.
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.setAccessibilityIdentifier("explorer.preview.content")
        previewContainer.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])
        quickLook = preview
        preview.previewItem = url as NSURL
        placeholder.isHidden = true
    }

    func closePreview() {
        actionsButton.menu = nil
        actionsButton.isHidden = true
        ocrButton.isEnabled = false
        generation &+= 1
        loadTask?.cancel(); loadTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        imageView.image = nil
        imageView.isHidden = true
        quickLook?.previewItem = nil
        quickLook?.close()
        quickLook?.removeFromSuperview()
        quickLook = nil
        displayedEntry = nil
        previewedURL = nil
    }

    @objc private func extractText(_ sender: Any?) {
        guard let displayedEntry, ExplorerWindowController.canExtractText([displayedEntry]) else { return }
        onExtractText?(displayedEntry.url)
    }

    private func clear(messageKey: String) {
        closePreview()
        fileName.stringValue = ""
        fileName.toolTip = nil
        placeholder.stringValue = L10n.text(messageKey)
        placeholder.isHidden = false
    }
}
