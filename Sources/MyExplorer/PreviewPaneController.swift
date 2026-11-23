// SPDX-License-Identifier: Apache-2.0
import AppKit
import AVKit
import PDFKit
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
    private let playerView = AVPlayerView()
    private var playbackSession: MediaPlaybackSession?
    private var playerStatus: NSKeyValueObservation?
    private var soundObservations: [NSKeyValueObservation] = []
    /// The item this pane already asked iCloud for, so a download that leaves it unavailable is
    /// not asked for again and again.
    private var downloadAttempted: URL?
    private var animation: ImageAnimation?
    private var pdfView: PDFView?
    private var pdfBar: NSStackView?
    private var pdfPageLabel: NSTextField?
    private var pdfPageObserver: NSObjectProtocol?
    /// The item whose download this pane is waiting for.
    private var downloading: URL?
    /// Selecting is not opening: above this size a video or sound that is only in iCloud is not downloaded
    /// just because the selection rested on it.
    static let automaticVideoDownloadLimit: Int64 = 200 * 1024 * 1024
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
        // Shown only for what text can be extracted from.
        ocrButton.isHidden = true
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
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.showsSharingServiceButton = false
        playerView.isHidden = true
        playerView.setAccessibilityIdentifier("explorer.preview.player")
        previewContainer.addSubview(playerView)
        // With every action hidden the stack has no height of its own; without this it would
        // stretch and squeeze the preview down to nothing.
        let noActions = actionsStack.heightAnchor.constraint(equalToConstant: 0)
        noActions.priority = .defaultLow
        noActions.isActive = true
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
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
        // Coming back to an item is a new chance to download it.
        if entries.count != 1 || entries.first?.url != downloadAttempted { downloadAttempted = nil }
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
        // The listing reads the item again while it downloads and after it arrives (its iCloud
        // state changes, the file does not): neither may stop the wait or rebuild what is shown.
        let sameFile = previewedURL == entry.url && displayedEntry.map {
            $0.url == entry.url && $0.size == entry.size && $0.modified == entry.modified && $0.isAlias == entry.isAlias } == true
        let showing = !imageView.isHidden || !playerView.isHidden || quickLook != nil || pdfView != nil
        if sameFile, downloading == entry.url || showing { displayedEntry = entry; return }
        guard displayedEntry != entry || previewedURL != entry.url else { return }
        closePreview()
        displayedEntry = entry
        previewedURL = entry.url
        let kind = MediaKind.detect(entry)
        ocrButton.isEnabled = ExplorerWindowController.canExtractText([entry])
        ocrButton.isHidden = !ocrButton.isEnabled
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
                self.animateIfAnimated(entry.url, generation: expectedGeneration)
            case .quickLook(let url):
                if kind == .video || kind == .audio { self.installVideo(url) }
                else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true { self.installPDF(url) }
                else { self.installQuickLook(url) }
            case .needsDownload:
                let small = kind == .image || ((kind == .video || kind == .audio) && (entry.size ?? .max) <= Self.automaticVideoDownloadLimit)
                if small, self.downloadAttempted != entry.url { self.download(entry, generation: expectedGeneration) }
                else { self.clear(messageKey: "preview.needs_download") }
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

    /// An image or a short video that is only in iCloud is downloaded once the selection rests on
    /// it, as the media viewer does, and shown when it arrives. Selecting something else stops
    /// the wait, not the download.
    private func download(_ entry: FileEntry, generation expectedGeneration: UInt64) {
        let url = entry.url
        placeholder.stringValue = L10n.text("media.downloading")
        placeholder.isHidden = false
        downloading = url
        loadTask = Task { [weak self] in
            // Arrow keys running down a list must not download every item they pass.
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == expectedGeneration, self.previewedURL == url else { return }
            self.downloadAttempted = url
            do { try await Task.detached { try ICloudAvailability.request(.download, at: url) }.value }
            catch {
                guard !Task.isCancelled, self.generation == expectedGeneration, self.previewedURL == url else { return }
                self.clear(messageKey: "preview.needs_download")
                return
            }
            var stalled = 0
            while true {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                let (downloaded, state) = await Task.detached {
                    (ICloudAvailability.isDownloaded(at: url), ICloudAvailability.current(at: url))
                }.value
                guard !Task.isCancelled, self.generation == expectedGeneration, self.previewedURL == url else { return }
                if downloaded == true {
                    let fresh = self.displayedEntry ?? entry
                    self.loadTask = nil
                    self.downloading = nil
                    self.displayedEntry = nil
                    self.update(entries: [fresh])
                    return
                }
                // Half a minute without the download even starting (no network) gives up.
                stalled = state == .downloading ? 0 : stalled + 1
                if downloaded == nil || state == .failed || stalled >= 60 {
                    self.clear(messageKey: "media.download_failed")
                    return
                }
            }
        }
    }

    /// A video or a sound plays in the pane itself, with the player's own controls (play, the
    /// progress bar, the sound); it waits for the person to start it.
    private func installVideo(_ url: URL) {
        let expectedGeneration = generation
        placeholder.stringValue = L10n.text("status.loading")
        placeholder.isHidden = false
        playbackSession = MediaPlaybackSession.start(url: url) { [weak self] session, outcome in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration, self.playbackSession === session else {
                    session.retireAfterDetachingUI()
                    return
                }
                guard outcome == .ready, let player = session.playerForAttachment() else {
                    // What this player cannot open (an AVI, say) Quick Look may still show.
                    if outcome != .cancelled { self.detachPlayback(); self.installQuickLook(url) }
                    return
                }
                MediaSound.apply(to: player)
                self.soundObservations = MediaSound.follow(player)
                self.playerView.player = player
                self.playerView.isHidden = false
                self.placeholder.isHidden = true
                self.playerStatus = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == expectedGeneration else { return }
                        self.clear(messageKey: "preview.unavailable")
                    }
                }
            }
        }
        // Every player slot is taken: Quick Look still shows the video.
        if playbackSession == nil { installQuickLook(url) }
    }

    /// For when the same item starts playing elsewhere, as in the media viewer.
    func pausePlayback() { playerView.player?.pause() }

    private func detachPlayback() {
        let session = playbackSession
        playbackSession = nil
        playerStatus?.invalidate(); playerStatus = nil
        soundObservations.forEach { $0.invalidate() }
        soundObservations = []
        playerView.player?.pause()
        playerView.player = nil
        playerView.isHidden = true
        session?.retireAfterDetachingUI()
    }

    private struct PDFBox: @unchecked Sendable { let document: PDFDocument? }

    /// A PDF is read in the pane itself: it scrolls from page to page, and a bar under it steps
    /// through the pages and tells which one is showing. What cannot be opened this way (a locked
    /// document) goes to Quick Look.
    private func installPDF(_ url: URL) {
        let expectedGeneration = generation
        placeholder.stringValue = L10n.text("status.loading")
        placeholder.isHidden = false
        loadTask = Task { [weak self] in
            let box = await Task.detached(priority: .userInitiated) { PDFBox(document: PDFDocument(url: url)) }.value
            guard !Task.isCancelled, let self, self.generation == expectedGeneration, self.previewedURL != nil else { return }
            self.loadTask = nil
            guard let document = box.document, !document.isLocked, document.pageCount > 0 else { self.installQuickLook(url); return }
            let view = PDFView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.displayMode = .singlePageContinuous
            view.displaysPageBreaks = true
            view.autoScales = true
            view.backgroundColor = .clear
            view.setAccessibilityIdentifier("explorer.preview.pdf")
            view.document = document
            let previous = ExplorerStyle.button("chevron.up", title: L10n.text("preview.pdf.previous"), target: self, action: #selector(self.previousPDFPage))
            let next = ExplorerStyle.button("chevron.down", title: L10n.text("preview.pdf.next"), target: self, action: #selector(self.nextPDFPage))
            let label = ExplorerStyle.label("", color: .secondaryLabelColor)
            label.alignment = .center
            label.setAccessibilityIdentifier("explorer.preview.pdf.page")
            let bar = NSStackView(views: [previous, label, next])
            bar.orientation = .horizontal
            bar.spacing = 6
            bar.translatesAutoresizingMaskIntoConstraints = false
            self.previewContainer.addSubview(view)
            self.previewContainer.addSubview(bar)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: self.previewContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: self.previewContainer.trailingAnchor),
                view.topAnchor.constraint(equalTo: self.previewContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4),
                bar.centerXAnchor.constraint(equalTo: self.previewContainer.centerXAnchor),
                bar.bottomAnchor.constraint(equalTo: self.previewContainer.bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: 30)
            ])
            self.pdfView = view; self.pdfBar = bar; self.pdfPageLabel = label
            self.pdfPageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePDFPage() }
            }
            self.placeholder.isHidden = true
            self.updatePDFPage()
        }
    }

    private func updatePDFPage() {
        guard let pdfView, let document = pdfView.document else { return }
        let index = pdfView.currentPage.map { document.index(for: $0) } ?? 0
        let number: (Int) -> String = { $0.formatted(.number.locale(L10n.current.locale)) }
        pdfPageLabel?.stringValue = L10n.format("preview.pdf.page", number(index + 1), number(document.pageCount))
    }

    @objc private func previousPDFPage() { pdfView?.goToPreviousPage(nil) }
    @objc private func nextPDFPage() { pdfView?.goToNextPage(nil) }

    private func closePDF() {
        if let pdfPageObserver { NotificationCenter.default.removeObserver(pdfPageObserver) }
        pdfPageObserver = nil
        pdfView?.document = nil
        pdfView?.removeFromSuperview(); pdfView = nil
        pdfBar?.removeFromSuperview(); pdfBar = nil
        pdfPageLabel = nil
    }

    /// An animated picture plays in the pane, in place of its first frame.
    private func animateIfAnimated(_ url: URL, generation expectedGeneration: UInt64) {
        guard !SecureFolderService.isSessionURL(url) else { return }
        Task { [weak self] in
            guard await Task.detached(priority: .userInitiated, operation: { ImageAnimation.isAnimated(url) }).value,
                  let self, self.generation == expectedGeneration, self.previewedURL == url, !self.imageView.isHidden else { return }
            self.animation = ImageAnimation(url: url) { [weak self] frame in
                guard let self, self.generation == expectedGeneration, !self.imageView.isHidden else { return }
                self.imageView.image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
        }
    }

    func closePreview() {
        animation?.stop(); animation = nil
        closePDF()
        detachPlayback()
        downloading = nil
        actionsButton.menu = nil
        actionsButton.isHidden = true
        ocrButton.isEnabled = false
        // Shown only for what text can be extracted from.
        ocrButton.isHidden = true
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
