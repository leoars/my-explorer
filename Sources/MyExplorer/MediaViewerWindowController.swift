// SPDX-License-Identifier: Apache-2.0
import AppKit
import AVKit
import AVFoundation
import ImageIO
import Darwin
import ExplorerCore
import ExplorerLocalization

/// Reuses one dedicated local-media window. No remote fetching or automatic playback.
@MainActor
final class MediaViewerWindowController: DialogWindowController {
    private let canvas = MediaViewerCanvas()
    private let imageViewport = MediaImageViewport()
    private var imageView: NSImageView { imageViewport.imageView }
    private var zoomState: ImageZoomState?
    private var zoomInButton: NSButton!
    private var zoomOutButton: NSButton!
    private var fitButton: NSButton!
    private var actualButton: NSButton!
    private var ocrButton: NSButton!
    var onExtractText: ((URL) -> Void)?
    private let zoomLabel = ExplorerStyle.label("", color: .secondaryLabelColor)
    private var zoomBar: NSStackView!
    private var zoomBarHeight: NSLayoutConstraint?
    private var updatingImageLayout = false
    private(set) var nativeResolutionAvailable = false
    var imageZoomFactor: CGFloat { zoomState?.scaleFactor ?? 0 }
    var renderedImageSize: NSSize { imageViewport.renderedSize }
    var sourcePixelSize: NSSize { zoomState?.pixelSize ?? .zero }
    var imageBackingScale: CGFloat { zoomState?.backingScale ?? window?.backingScaleFactor ?? 1 }
    var imageIsFit: Bool { zoomState?.mode == .fit }
    var imageResolutionMessage: String { imageLoaded && !nativeResolutionAvailable ? L10n.text("media.preview_limited") : "" }
    private let playerView = AVPlayerView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let filename = ExplorerStyle.label("", area: .files)
    private let position = ExplorerStyle.label("", color: .secondaryLabelColor)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var barHeight: NSLayoutConstraint?
    private var playlist: MediaPlaylist?
    private var loadTask: Task<Void, Never>?
    private var preparationDeadlineTask: Task<Void, Never>?
    private let preparationTimeout: TimeInterval
    private var statusObservation: NSKeyValueObservation?
    private var playbackSession: MediaPlaybackSession?
    private let availabilityCheck: @Sendable (URL) -> MediaFileAvailability
    private var generation: UInt64 = 0
    private var messageKey: String?
    private(set) var currentURL: URL?
    private(set) var playbackReady = false
    private(set) var player: AVPlayer?
    private var soundObservations: [NSKeyValueObservation] = []
    private var animation: ImageAnimation?
    var imageLoaded: Bool { imageView.image != nil && !imageViewport.isHidden }
    var message: String { placeholder.isHidden ? "" : placeholder.stringValue }
    func usesFiles(where matches: (URL) -> Bool) -> Bool {
        // The playlist may have thousands of entries from the same directory.
        guard let currentURL else { return false }
        return matches(currentURL)
    }
    var canPrevious: Bool { playlist?.canPrevious ?? false }
    var canNext: Bool { playlist?.canNext ?? false }

    init(availability: @escaping @Sendable (URL) -> MediaFileAvailability = { MediaFileAccess.availability(of: $0) }, preparationTimeout: TimeInterval = 15) {
        availabilityCheck = availability
        self.preparationTimeout = preparationTimeout.isFinite ? max(0.01, min(60, preparationTimeout)) : 15
        let window = MediaViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                       backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 340)
        window.delegate = self
        window.setAccessibilityIdentifier("explorer.media.window")
        buildInterface()
        reloadAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(entries: [FileEntry], selectedURL: URL) {
        cleanup()
        playlist = MediaPlaylist(entries: entries, selectedURL: selectedURL)
        if playlist != nil { displayCurrent() }
        else { updateNavigation(); showMessage("media.unsupported") }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focusNavigation()
    }

    @objc func previous() {
        guard playlist?.previous() != nil else { return }
        displayCurrent()
    }

    @objc func next() {
        guard playlist?.next() != nil else { return }
        displayCurrent()
    }

    func focusNavigation() { window?.makeFirstResponder(canvas) }

    @objc private func extractText(_ sender: Any?) {
        guard imageLoaded, let currentURL, OCRService.canRecognize(currentURL) else { return }
        onExtractText?(currentURL)
    }

    @objc func fitImage() {
        guard zoomState != nil else { return }
        zoomState?.fit()
        applyImageZoom(preserveCenter: false)
        focusNavigation()
    }

    @objc func actualSize() {
        guard nativeResolutionAvailable else { return }
        zoomState?.actualSize()
        applyImageZoom(preserveCenter: true)
        focusNavigation()
    }

    @objc func zoomIn() {
        zoomState?.zoomIn()
        applyImageZoom(preserveCenter: true)
        focusNavigation()
    }

    @objc func zoomOut() {
        zoomState?.zoomOut()
        applyImageZoom(preserveCenter: true)
        focusNavigation()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) { updateImageViewport() }
    func windowDidResize(_ notification: Notification) { updateImageViewport() }

    private func updateImageViewport() {
        guard zoomState != nil, !updatingImageLayout else { return }
        zoomState?.updateBackingScale(window?.backingScaleFactor ?? 1)
        zoomState?.updateViewport(imageViewport.viewportSize)
        applyImageZoom(preserveCenter: zoomState?.mode != .fit)
    }

    private func applyImageZoom(preserveCenter: Bool) {
        guard let zoomState, !updatingImageLayout else { return }
        updatingImageLayout = true
        imageViewport.render(size: zoomState.displayedSize, preserveCenter: preserveCenter)
        updatingImageLayout = false
        updateZoomControls()
    }

    private func updateZoomControls() {
        let ready = zoomState != nil && imageLoaded
        ocrButton?.isEnabled = ready && currentURL.map(OCRService.canRecognize) == true
        zoomInButton.isEnabled = ready && imageZoomFactor < ImageZoomState.maximumManualScale
        zoomOutButton.isEnabled = ready && imageZoomFactor > ImageZoomState.minimumManualScale
        fitButton.isEnabled = ready
        actualButton.isEnabled = ready && nativeResolutionAvailable
        if let zoomState {
            let number = Double(zoomState.scaleFactor * 100).formatted(.number.precision(.fractionLength(0...1)).locale(L10n.current.locale))
            zoomLabel.stringValue = L10n.format(nativeResolutionAvailable ? "media.zoom_percent" : "media.preview_zoom_percent", number)
        } else { zoomLabel.stringValue = "—" }
        hint.stringValue = L10n.text("media.navigation_hint") + (imageResolutionMessage.isEmpty ? "" : "\n" + imageResolutionMessage)
    }

    override func close() {
        cleanup()
        playlist = nil
        updateNavigation()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
        playlist = nil
        updateNavigation()
    }

    /// Also usable during application shutdown before window teardown.
    func cleanup() {
        generation &+= 1
        preparationDeadlineTask?.cancel()
        preparationDeadlineTask = nil
        loadTask?.cancel()
        loadTask = nil
        animation?.stop(); animation = nil
        detachPlayback()
        playbackReady = false
        zoomState = nil
        nativeResolutionAvailable = false
        imageViewport.clearImage()
        imageViewport.isHidden = true
        updateZoomControls()
        playerView.isHidden = true
        currentURL = nil
        filename.stringValue = ""
        filename.toolTip = nil
        messageKey = nil
        placeholder.stringValue = ""
        placeholder.isHidden = true
    }

    func reloadAppearance() {
        ocrButton?.toolTip = L10n.text("ocr.title")
        ocrButton?.setAccessibilityLabel(L10n.text("ocr.title"))
        previousButton.toolTip = L10n.text("media.previous")
        previousButton.setAccessibilityLabel(L10n.text("media.previous"))
        nextButton.toolTip = L10n.text("media.next")
        nextButton.setAccessibilityLabel(L10n.text("media.next"))
        filename.font = ExplorerStyle.font(.files)
        position.font = ExplorerStyle.font(.bars)
        hint.font = ExplorerStyle.font(.bars, offset: -2)
        placeholder.font = ExplorerStyle.font(.files)
        let fonts = [ExplorerStyle.font(.files), ExplorerStyle.font(.bars)]
        let lineHeight = fonts.map { ceil($0.ascender - $0.descender + $0.leading) }.max() ?? 28
        barHeight?.constant = max(36, lineHeight + 8)
        zoomBarHeight?.constant = max(36, lineHeight + 8)
        zoomLabel.font = ExplorerStyle.font(.bars)
        for (button, key) in [(zoomInButton, "media.zoom_in"), (zoomOutButton, "media.zoom_out"), (fitButton, "media.fit"), (actualButton, "media.actual_size")] {
            button?.toolTip = L10n.text(key)
            button?.setAccessibilityLabel(L10n.text(key))
        }
        hint.stringValue = L10n.text("media.navigation_hint")
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 0
        canvas.setAccessibilityLabel(L10n.text("media.title"))
        if let messageKey { showMessage(messageKey) }
        updateNavigation()
        updateZoomControls()
    }

    private func buildInterface() {
        guard let window else { return }
        let root = ExplorerSurface()
        window.contentView = root
        previousButton = ExplorerStyle.button("chevron.left", title: L10n.text("media.previous"), target: self, action: #selector(previous))
        nextButton = ExplorerStyle.button("chevron.right", title: L10n.text("media.next"), target: self, action: #selector(next))
        previousButton.setAccessibilityIdentifier("explorer.media.previous")
        nextButton.setAccessibilityIdentifier("explorer.media.next")
        filename.setAccessibilityIdentifier("explorer.media.filename")
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        position.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bar = ExplorerStyle.stack([previousButton, nextButton, filename, position])
        barHeight = bar.heightAnchor.constraint(equalToConstant: 36)
        barHeight?.isActive = true
        hint.setContentHuggingPriority(.required, for: .vertical)
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        zoomInButton = ExplorerStyle.button("plus.magnifyingglass", title: L10n.text("media.zoom_in"), target: self, action: #selector(zoomIn))
        zoomOutButton = ExplorerStyle.button("minus.magnifyingglass", title: L10n.text("media.zoom_out"), target: self, action: #selector(zoomOut))
        fitButton = ExplorerStyle.button("arrow.up.left.and.arrow.down.right", title: L10n.text("media.fit"), target: self, action: #selector(fitImage))
        actualButton = ExplorerStyle.button("1.square", title: L10n.text("media.actual_size"), target: self, action: #selector(actualSize))
        ocrButton = ExplorerStyle.button("text.viewfinder", title: L10n.text("ocr.title"), target: self, action: #selector(extractText))
        ocrButton.setAccessibilityIdentifier("explorer.media.ocr")
        for (button, name) in [(zoomInButton, "in"), (zoomOutButton, "out"), (fitButton, "fit"), (actualButton, "actual")] {
            button?.setAccessibilityIdentifier("explorer.media.zoom.\(name)")
        }
        zoomLabel.setAccessibilityIdentifier("explorer.media.zoom.percent")
        zoomLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        zoomBar = ExplorerStyle.stack([fitButton, actualButton, zoomOutButton, zoomInButton, zoomLabel, ocrButton])
        zoomBarHeight = zoomBar.heightAnchor.constraint(equalToConstant: 36)
        zoomBarHeight?.isActive = true
        imageViewport.viewportChanged = { [weak self] in self?.updateImageViewport() }
        imageViewport.imageClicked = { [weak self] in self?.focusNavigation() }
        imageViewport.magnified = { [weak self] magnification in
            guard let self, let state = self.zoomState, magnification.isFinite, magnification != 0 else { return }
            guard magnification >= 0 || state.scaleFactor > ImageZoomState.minimumManualScale else { return }
            self.zoomState?.setZoom(state.scaleFactor * max(0.01, 1 + magnification))
            self.applyImageZoom(preserveCenter: true)
        }
        let divider = ExplorerStyle.separator()
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.maximumNumberOfLines = 0
        placeholder.setAccessibilityIdentifier("explorer.media.message")
        canvas.setAccessibilityIdentifier("explorer.media.canvas")
        canvas.navigate = { [weak self] direction in
            switch direction { case .previous: self?.previous(); case .next: self?.next() }
        }
        canvas.closeViewer = { [weak self] in self?.close() }
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.showsSharingServiceButton = false
        playerView.setAccessibilityIdentifier("explorer.media.player")
        for child in [bar, zoomBar!, divider, canvas, hint] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        for child in [imageViewport, playerView, placeholder] {
            child.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(child)
        }
        for content in [imageViewport as NSView, playerView as NSView] {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
                content.topAnchor.constraint(equalTo: canvas.topAnchor),
                content.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            zoomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            zoomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            zoomBar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            divider.topAnchor.constraint(equalTo: zoomBar.bottomAnchor, constant: 4),
            canvas.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            canvas.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            placeholder.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -24)
        ])
        imageViewport.isHidden = true
        playerView.isHidden = true
    }

    private func updateNavigation() {
        previousButton.isEnabled = canPrevious
        nextButton.isEnabled = canNext
        if let playlist {
            position.stringValue = L10n.format("media.position", L10n.current.number(playlist.index + 1), L10n.current.number(playlist.count))
        } else { position.stringValue = "" }
        let title = L10n.text("media.title")
        window?.title = currentURL.map { "\($0.lastPathComponent) — \(title)" } ?? title
    }

    private func showMessage(_ key: String) {
        messageKey = key
        placeholder.stringValue = L10n.text(key)
        placeholder.isHidden = false
    }

    /// A file that is only in iCloud is downloaded without asking, as Finder does, and shown when it
    /// arrives. Moving to another file or closing the viewer stops the wait, not the download.
    private func downloadThenDisplay(url: URL, generation expectedGeneration: UInt64) {
        showMessage("media.downloading")
        loadTask = Task { [weak self] in
            do { try await Task.detached { try ICloudAvailability.request(.download, at: url) }.value }
            catch {
                guard !Task.isCancelled, let self, self.generation == expectedGeneration, self.currentURL == url else { return }
                self.loadTask = nil
                self.showMessage("media.needs_download")
                return
            }
            // Half a minute without the download even starting (no network, iCloud paused) gives up;
            // while it is running there is no limit, since a large video can take long.
            var stalled = 0
            while true {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                let (downloaded, state) = await Task.detached {
                    (ICloudAvailability.isDownloaded(at: url), ICloudAvailability.current(at: url))
                }.value
                guard !Task.isCancelled, let self, self.generation == expectedGeneration, self.currentURL == url else { return }
                if downloaded == true {
                    self.loadTask = nil
                    self.displayCurrent(autoDownload: false)
                    return
                }
                stalled = state == .downloading ? 0 : stalled + 1
                if downloaded == nil || state == .failed || stalled >= 60 {
                    self.loadTask = nil
                    self.showMessage("media.download_failed")
                    return
                }
            }
        }
    }

    private func displayCurrent(autoDownload: Bool = true) {
        cleanup()
        guard let entry = playlist?.current, let kind = MediaKind.detect(entry) else { return }
        let url = entry.url
        let expectedGeneration = generation
        currentURL = url
        filename.stringValue = entry.name
        filename.toolTip = url.path
        imageView.setAccessibilityLabel(entry.name)
        updateNavigation()
        showMessage("media.loading")
        focusNavigation()
        let availability = availabilityCheck
        startPreparationDeadline(generation: expectedGeneration)
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                await MediaImageDecoder.shared.prepare(url: url, kind: kind, availability: availability)
            }
            let prepared = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.generation == expectedGeneration, self.currentURL == url else { return }
            guard let prepared else {
                self.loadTask = nil
                self.cancelPreparationDeadline()
                self.showMessage("media.unavailable")
                return
            }
            if prepared.needsDownload {
                self.cancelPreparationDeadline()
                self.loadTask = nil
                if autoDownload { self.downloadThenDisplay(url: url, generation: expectedGeneration) }
                else { self.showMessage("media.needs_download") }
                return
            }
            if let image = prepared.image {
                self.imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                self.nativeResolutionAvailable = prepared.nativeResolutionAvailable
                self.imageViewport.isHidden = false
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.zoomState = ImageZoomState(pixelSize: prepared.sourcePixelSize,
                    backingScale: self.window?.backingScaleFactor ?? 1,
                    viewportSize: self.imageViewport.viewportSize)
                self.applyImageZoom(preserveCenter: false)
                self.cancelPreparationDeadline()
                self.placeholder.isHidden = true
                self.messageKey = nil
                self.loadTask = nil
                self.animateIfAnimated(prepared.resolvedURL, generation: expectedGeneration)
                return
            }
            self.startPlayback(url: prepared.resolvedURL, generation: expectedGeneration)
            self.loadTask = nil
        }
    }

    /// An animated picture (a WhatsApp sticker in WebP, a GIF) plays in place of its first frame;
    /// zoom and panning go on working, since every frame has the size of the first.
    private func animateIfAnimated(_ url: URL, generation expectedGeneration: UInt64) {
        Task { [weak self] in
            guard await Task.detached(priority: .userInitiated, operation: { ImageAnimation.isAnimated(url) }).value,
                  let self, self.generation == expectedGeneration, self.currentURL != nil, self.imageLoaded else { return }
            self.animation = ImageAnimation(url: url) { [weak self] frame in
                guard let self, self.generation == expectedGeneration, self.imageLoaded else { return }
                self.imageView.image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
        }
    }

    private func cancelPreparationDeadline() {
        preparationDeadlineTask?.cancel()
        preparationDeadlineTask = nil
    }

    private func startPreparationDeadline(generation expectedGeneration: UInt64) {
        let timeout = preparationTimeout
        preparationDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == expectedGeneration,
                  !self.imageLoaded, !self.playbackReady else { return }
            self.generation &+= 1
            self.loadTask?.cancel()
            self.loadTask = nil
            self.preparationDeadlineTask = nil
            self.detachPlayback()
            self.playerView.isHidden = true
            self.showMessage("media.loading_timeout")
        }
    }

    private func startPlayback(url: URL, generation expectedGeneration: UInt64) {
        playbackSession = MediaPlaybackSession.start(url: url) { [weak self] session, outcome in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration, self.playbackSession === session else {
                    session.retireAfterDetachingUI()
                    return
                }
                switch outcome {
                case .ready: self.installPlayer(session: session, generation: expectedGeneration)
                case .timedOut:
                    self.cancelPreparationDeadline()
                    self.detachPlayback()
                    self.showMessage("media.loading_timeout")
                case .unavailable:
                    self.cancelPreparationDeadline()
                    self.detachPlayback()
                    self.showMessage("media.unavailable")
                case .cancelled: break
                }
            }
        }
        if playbackSession == nil { cancelPreparationDeadline(); showMessage("media.busy") }
    }

    private func detachPlayback() {
        let session = playbackSession
        playbackSession = nil
        autoreleasepool {
            statusObservation?.invalidate()
            statusObservation = nil
            soundObservations.forEach { $0.invalidate() }
            soundObservations = []
            playerView.player = nil
            player = nil
        }
        // AV owners remain strong throughout UI detach. Their queue does all cancellation,
        // player-item teardown and final release, including failed or timed-out loads.
        session?.retireAfterDetachingUI()
    }

    private func installPlayer(session: MediaPlaybackSession, generation expectedGeneration: UInt64) {
        guard let player = session.playerForAttachment(), let item = player.currentItem else {
            cancelPreparationDeadline()
            detachPlayback()
            showMessage("media.unavailable")
            return
        }
        self.player = player
        MediaSound.apply(to: player)
        soundObservations = MediaSound.follow(player)
        playerView.player = player
        playerView.isHidden = false
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status.rawValue
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration,
                      self.player?.currentItem?.status.rawValue == status else { return }
                if status == AVPlayerItem.Status.readyToPlay.rawValue {
                    let first = !self.playbackReady
                    self.playbackReady = true
                    self.cancelPreparationDeadline()
                    self.placeholder.isHidden = true
                    self.messageKey = nil
                    // Opening a video or a sound is asking to play it, unless the Options say
                    // otherwise; the graphic tests check the player at rest.
                    if first, ExplorerStyle.browserPreferences.autoplayMedia,
                       !ProcessInfo.processInfo.arguments.contains("--smoke-test") { self.player?.play() }
                } else if status == AVPlayerItem.Status.failed.rawValue {
                    self.playbackReady = false
                    self.cancelPreparationDeadline()
                    self.detachPlayback()
                    self.playerView.isHidden = true
                    self.showMessage("media.unavailable")
                }
            }
        }
    }
}

@MainActor
private final class MediaViewerCanvas: NSView {
    var navigate: ((MediaNavigationDirection) -> Void)?
    var closeViewer: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 53 { closeViewer?(); return }
        if let direction = MediaNavigationDirection.direction(keyCode: event.keyCode) { navigate?(direction); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class MediaViewerWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let textEditing = firstResponder is NSTextView
        // Control (or Command) with + and − zooms the picture. Without this the keys reach the
        // menu and change the font size of the window behind.
        if !textEditing, modifiers == .control || modifiers == .command || modifiers == [.control, .shift] || modifiers == [.command, .shift],
           let viewer = windowController as? MediaViewerWindowController,
           let key = event.charactersIgnoringModifiers {
            if key == "+" || key == "=" { viewer.zoomIn(); return true }
            if key == "-" || key == "_" { viewer.zoomOut(); return true }
        }
        if !textEditing && ((event.keyCode == 53 && modifiers.isEmpty)
                            || (event.keyCode == 13 && modifiers == .control)) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
