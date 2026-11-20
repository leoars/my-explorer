// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import ExplorerLocalization
import ExplorerClipboard
import UniformTypeIdentifiers

@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSMenuDelegate, NSSplitViewDelegate {
    let workspace: ExplorerWorkspace
    var session: DirectorySession { workspace.activeTab!.session }
    let table = ExplorerTableView()
    let fileScroll = NSScrollView()
    let address = NSTextField()
    let addressSuggestions = AddressSuggestions()
    let filter = NSSearchField()
    let breadcrumbs = NSStackView()
    let status = ExplorerStyle.label("", color: .secondaryLabelColor)
    let message = ExplorerStyle.label("", size: 13, color: .secondaryLabelColor)
    let errorLabel = ExplorerStyle.label("", color: .systemRed)
    let progress = NSProgressIndicator()
    private(set) var vaultPresentationGeneration = 0
    private var gitReview: GitReviewController?
    private let gitState = GitBrowserState()
    private let gitSummary = ExplorerStyle.label("", color: .secondaryLabelColor)
    var gitSummaryText: String { gitSummary.stringValue }
    var gitSnapshot: GitStatusSnapshot? { gitState.snapshot }
    private var forceGitRefresh = false
    let tree: FolderTreeController
    weak var secureFolders: SecureFolderCommands?
    let sidebarHome: URL?
    var onLanguageChange: ((AppLanguage) -> Void)?
    var onShowFontSettings: (() -> Void)?
    var onManageCloud: (() -> Void)?
    var onShowOptions: (() -> Void)?
    var onClose: ((URL) -> Void)?
    var onSessionChange: (() -> Void)?
    var restorationFallbackTabs: Set<UUID> = []
    var onOpenMedia: (([FileEntry], URL) -> Void)?
    var onExtractText: ((URL) -> Void)?
    var onBatchOCR: (([URL]) -> Void)?
    private(set) var lastLocation: URL
    let languagePicker = NSPopUpButton()
    let tabStrip = NSStackView()
    private let tabScroll = NSScrollView()
    private let split = NSSplitView()
    private let previewPane = PreviewPaneController()
    let previewButton = OutlinedButton()
    private var lastPreviewWidth: CGFloat = 300
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var upButton: NSButton!
    private var hiddenButton: NSButton!
    private var openButton: NSButton!
    private var copyButton: NSButton!
    private var visibleEntries: [FileEntry] = []
    private var inlineRename: (entry: FileEntry, field: NSTextField)?
    private var contextEntries: [FileEntry] = []
    private var renderedTabID: UUID?
    private var renderedPath: String?
    private var rendering = false
    private var restoringLayout = true
    private var presentationSaveTask: Task<Void, Never>?
    private var keyMonitor: Any?
    var fileSharing = FileSharingController()
    init(initialURL: URL, sidebarHome: URL? = nil, existingWorkspace: ExplorerWorkspace? = nil,
         existingTree: FolderTreeController? = nil) {
        let workspace = existingWorkspace ?? ExplorerWorkspace(reader: ApplicationDirectoryReader(), observerFactory: { DirectoryWatcher() })
        let preferences = ExplorerStyle.browserPreferences
        if workspace.tabs.isEmpty {
            workspace.addTab(at: initialURL, sortKey: preferences.sortKey, sortAscending: preferences.sortAscending, showHidden: preferences.showHidden)
        }
        self.workspace = workspace
        lastLocation = initialURL
        self.sidebarHome = sidebarHome
        tree = existingTree ?? FolderTreeController(home: sidebarHome ?? FileManager.default.homeDirectoryForCurrentUser)
        tree.relocalize()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "My Explorer"
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = ExplorerSurface(frame: NSRect(x: 0, y: 0, width: 1160, height: 740))
        super.init(window: window)
        window.delegate = self
        FileCommands.shared.owner = self
        gitState.onChange = { [weak self] in self?.renderGit() }
        gitState.shouldPoll = { [weak self] in self?.window?.isVisible == true && NSApp.isActive }
        buildInterface()
        window.contentView?.layoutSubtreeIfNeeded()
        restoreWindowFrame()
        lastPreviewWidth = preferences.previewWidth
        split.setPosition(max(165, min(preferences.sidebarWidth, split.bounds.width - 431)), ofDividerAt: 0)
        updatePreviewVisibility()
        applySavedColumns()
        workspace.onChange = { [weak self] changedID in
            guard let self else { return }
            guard self.workspace.activeTab != nil else { self.window?.performClose(nil); return }
            self.onSessionChange?()
            self.renderTabs()
            if changedID == nil || changedID == self.workspace.activeID { self.renderSession() }
        }
        workspace.onWillAutoRefresh = { [weak self] id in
            guard let self, self.workspace.activeID == id else { return }
            self.rememberView()
            self.forceGitRefresh = true
        }
        tree.onNavigate = { [weak self] url in self?.navigate(.visit(url)) }
        tree.onVolumeProperties = { [weak self] url, mount in self?.showVolumeProperties(at: url, mount: mount) }
        tree.onManageCloud = { [weak self] in self?.onManageCloud?() }
        previewPane.onExtractText = { [weak self] url in self?.onExtractText?(url) }
        table.openSelection = { [weak self] in self?.openSelected(nil) }
        table.goBack = { [weak self] in self?.goBack(nil) }
        installKeyboardNavigation()
        renderTabs()
        renderSession()
        restoringLayout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        tabStrip.orientation = .horizontal
        tabStrip.alignment = .centerY
        tabStrip.spacing = 6
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.documentView = tabStrip
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false
        tabScroll.heightAnchor.constraint(equalToConstant: 36 + max(0, ExplorerStyle.preferences.fontSize(for: .bars) - 12)).isActive = true
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStrip.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor),
            tabStrip.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.contentView.widthAnchor)
        ])
        let newTab = ExplorerStyle.button("plus", title: L10n.text("tab.new_tooltip"), target: self, action: #selector(newTab), outlined: true)
        addBar(ExplorerStyle.stack([tabScroll, newTab], spacing: 6), to: root, height: 44)
        addLine(to: root)

        backButton = ExplorerStyle.button("arrow.left", title: L10n.text("navigation.back"), target: self, action: #selector(goBack), outlined: true)
        forwardButton = ExplorerStyle.button("arrow.right", title: L10n.text("navigation.forward"), target: self, action: #selector(goForward), outlined: true)
        upButton = ExplorerStyle.button("arrow.up", title: L10n.text("navigation.up"), target: self, action: #selector(goUp), outlined: true)
        let refresh = ExplorerStyle.button("arrow.clockwise", title: L10n.text("navigation.refresh"), target: self, action: #selector(refresh), outlined: true)
        address.placeholderString = L10n.text("address.placeholder")
        address.font = .systemFont(ofSize: 13)
        address.bezelStyle = .roundedBezel
        address.delegate = self
        addressSuggestions.submit = { [weak self] in self?.addressSubmitted(nil) }
        address.target = self; address.action = #selector(addressSubmitted)
        address.setAccessibilityLabel(L10n.text("address.accessibility"))
        address.setAccessibilityIdentifier("explorer.address")
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filter.placeholderString = L10n.text("filter.placeholder")
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityLabel(L10n.text("filter.accessibility"))
        filter.setAccessibilityIdentifier("explorer.filter")
        filter.widthAnchor.constraint(equalToConstant: 225).isActive = true
        let navigation = ExplorerStyle.stack([backButton, forwardButton, upButton, refresh, address, filter], spacing: 6)
        addBar(navigation, to: root, height: 54)

        breadcrumbs.orientation = .horizontal; breadcrumbs.alignment = .centerY; breadcrumbs.spacing = 2
        breadcrumbs.setAccessibilityLabel(L10n.text("breadcrumbs.accessibility"))
        addBar(breadcrumbs, to: root, height: 32)
        addLine(to: root)

        openButton = OutlinedButton(title: L10n.text("command.open"), image: ExplorerStyle.symbol("arrow.up.forward.square", description: L10n.text("command.open"))!,
                              target: self, action: #selector(openSelected))
        copyButton = OutlinedButton(title: L10n.text("command.copy_path"), image: ExplorerStyle.symbol("doc.on.doc", description: L10n.text("command.copy_path"))!,
                              target: self, action: #selector(copyPath))
        openButton.setAccessibilityIdentifier("explorer.command.open")
        copyButton.setAccessibilityIdentifier("explorer.command.copyPath")
        previewButton.title = L10n.text("preview.title")
        previewButton.image = ExplorerStyle.symbol("sidebar.right", description: previewButton.title)
        previewButton.imagePosition = .imageOnly
        previewButton.setButtonType(.pushOnPushOff)
        previewButton.showsSelection = true
        previewButton.target = self; previewButton.action = #selector(togglePreviewPane)
        previewButton.toolTip = previewButton.title
        previewButton.setAccessibilityLabel(previewButton.title)
        previewButton.setAccessibilityIdentifier("explorer.preview.toggle")
        previewButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        previewButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        hiddenButton = NSButton(checkboxWithTitle: L10n.text("view.hidden"), target: self, action: #selector(toggleHidden))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let mode = NSPopUpButton(frame: .zero, pullsDown: true)
        mode.addItem(withTitle: L10n.text("menu.view"))
        mode.menu?.addItem(withTitle: L10n.text("view.extensions"), action: #selector(toggleFileExtensions), keyEquivalent: "").target = self
        mode.menu?.addItem(withTitle: L10n.text("preview.title"), action: #selector(togglePreviewPane), keyEquivalent: "").target = self
        mode.menu?.addItem(withTitle: L10n.text("font.title"), action: #selector(showFontSettings), keyEquivalent: "").target = self
        mode.menu?.addItem(withTitle: L10n.text("options.title"), action: #selector(showOptions), keyEquivalent: "").target = self
        mode.menu?.addItem(withTitle: L10n.text("cloud.manage"), action: #selector(manageCloud), keyEquivalent: "").target = self
        mode.setAccessibilityLabel(L10n.text("menu.view"))
        mode.setAccessibilityIdentifier("explorer.viewMenu")
        if let menu = mode.menu { ExplorerStyle.configureMenu(menu) }
        languagePicker.addItems(withTitles: AppLanguage.allCases.map { $0 == .system ? L10n.text("language.system") : $0.nativeName })
        languagePicker.selectItem(at: AppLanguage.allCases.firstIndex(of: L10n.preferences.selection) ?? 0)
        languagePicker.target = self; languagePicker.action = #selector(languageChanged)
        languagePicker.setAccessibilityLabel(L10n.text("language.accessibility"))
        languagePicker.toolTip = L10n.text("language.label")
        languagePicker.widthAnchor.constraint(equalToConstant: max(160, ExplorerStyle.preferences.fontSize(for: .bars) * 12)).isActive = true
        if ExplorerStyle.preferences.fontSize(for: .bars) > 16 {
            addBar(ExplorerStyle.stack([openButton, copyButton, spacer, previewButton]), to: root, height: 43)
            let optionSpacer = NSView(); optionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            addBar(ExplorerStyle.stack([languagePicker, optionSpacer, hiddenButton, mode], spacing: 14), to: root, height: 43)
        } else {
            addBar(ExplorerStyle.stack([openButton, copyButton, spacer, languagePicker, hiddenButton, mode, previewButton], spacing: 14), to: root, height: 43)
        }
        addLine(to: root)

        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        root.addArrangedSubview(errorLabel)
        errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16).isActive = true
        errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16).isActive = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        let sidebar = NSView()
        sidebar.wantsLayer = true
        let heading = ExplorerStyle.label(L10n.text("view.navigation"), size: 10, color: .secondaryLabelColor)
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        for view in [heading, tree.scrollView] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            tree.scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            tree.scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 4),
            tree.scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
            tree.scrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 165)
        ])
        let details = NSView()
        configureTable()
        fileScroll.documentView = table
        fileScroll.hasVerticalScroller = true; fileScroll.hasHorizontalScroller = true
        fileScroll.autohidesScrollers = true
        fileScroll.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(fileScroll)
        message.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(message)
        NSLayoutConstraint.activate([
            fileScroll.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            fileScroll.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            fileScroll.topAnchor.constraint(equalTo: details.topAnchor),
            fileScroll.bottomAnchor.constraint(equalTo: details.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: details.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: details.centerYAnchor),
            details.widthAnchor.constraint(greaterThanOrEqualToConstant: 430)
        ])
        split.addArrangedSubview(sidebar); split.addArrangedSubview(details)
        root.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        sidebar.frame.size.width = 230

        addLine(to: root)
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let badge = ExplorerStyle.label(L10n.text("view.prototype"), size: 11, color: .secondaryLabelColor)
        gitSummary.lineBreakMode = .byTruncatingTail
        gitSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gitSummary.setAccessibilityIdentifier("explorer.git.summary")
        gitSummary.isHidden = true
        addBar(ExplorerStyle.stack([progress, status, statusSpacer, gitSummary, badge]), to: root, height: 30)
        applyBarFonts(to: root)
    }

    private func applyBarFonts(to view: NSView) {
        guard view !== split else { return }
        if let field = view as? NSTextField { field.font = ExplorerStyle.font(.bars) }
        if let button = view as? NSButton { button.font = ExplorerStyle.font(.bars) }
        if let picker = view as? NSPopUpButton, let font = picker.font {
            picker.bezelStyle = .regularSquare
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(font.ascender - font.descender) + 12).isActive = true
            picker.setContentCompressionResistancePriority(.required, for: .vertical)
            if let menu = picker.menu { ExplorerStyle.configureMenu(menu) }
        }
        for child in view.subviews { applyBarFonts(to: child) }
    }

    private func addBar(_ bar: NSView, to root: NSStackView, height: CGFloat) {
        let wrapper = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(bar)
        root.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: root.widthAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: height + max(0, ExplorerStyle.preferences.fontSize(for: .bars) - 12)),
            bar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            bar.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
        ])
    }

    private func applySavedColumns() {
        let preferences = ExplorerStyle.browserPreferences
        for (index, identifier) in preferences.columnOrder.enumerated() {
            let current = table.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
            if current >= 0 { table.moveColumn(current, toColumn: index) }
        }
        for column in table.tableColumns {
            if let width = preferences.columnWidths[column.identifier.rawValue] { column.width = width }
        }
    }

    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        DialogPlacement.sheetAnchor(sheet, in: window)
    }

    private func restoreWindowFrame() {
        guard let window else { return }
        guard var frame = ExplorerStyle.browserPreferences.windowFrame,
              let main = NSScreen.main else { window.center(); return }
        let screen = NSScreen.screens.max { left, right in
            let a = left.visibleFrame.intersection(frame), b = right.visibleFrame.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        let visible = screen.flatMap { $0.visibleFrame.intersects(frame) ? $0.visibleFrame : nil } ?? main.visibleFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func schedulePresentationSave() {
        guard !restoringLayout else { return }
        presentationSaveTask?.cancel()
        presentationSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.savePresentation()
        }
    }

    func savePresentation() {
        presentationSaveTask?.cancel(); presentationSaveTask = nil
        guard !restoringLayout else { return }
        let preferences = ExplorerStyle.browserPreferences
        preferences.setColumns(order: table.tableColumns.map { $0.identifier.rawValue },
            widths: Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) }))
        preferences.sidebarWidth = sidebarWidth
        preferences.previewWidth = previewPaneWidth
        if let window, !window.styleMask.contains(.fullScreen) { preferences.setWindowFrame(window.frame) }
    }

    func tableViewColumnDidMove(_ notification: Notification) { positionRenameField(); schedulePresentationSave() }
    func tableViewColumnDidResize(_ notification: Notification) { positionRenameField(); schedulePresentationSave() }
    func splitViewDidResizeSubviews(_ notification: Notification) { schedulePresentationSave() }
    func windowDidMove(_ notification: Notification) { schedulePresentationSave() }
    func windowDidResize(_ notification: Notification) { schedulePresentationSave() }

    private func addLine(to root: NSStackView) {
        let separator = ExplorerStyle.separator()
        root.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat)] = [("name", L10n.text("column.name"), 390), ("modified", L10n.text("column.modified"), 165),
                                                   ("kind", L10n.text("column.kind"), 150), ("size", L10n.text("column.size"), 95)]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = 75
            column.headerToolTip = title
            column.headerCell.alignment = .left
            column.headerCell.lineBreakMode = .byTruncatingTail
            column.headerCell.font = ExplorerStyle.font(.files)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail
            column.headerCell.attributedStringValue = NSAttributedString(string: title,
                attributes: [.font: ExplorerStyle.font(.files), .foregroundColor: NSColor.headerTextColor,
                             .paragraphStyle: paragraph])
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.style = .plain
        table.rowHeight = max(29, ExplorerStyle.preferences.fontSize(for: .files) + 14)
        table.headerView?.frame.size.height = max(24, ExplorerStyle.preferences.fontSize(for: .files) + 12)
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes(FileClipboard.dragTypes)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.renameCandidate = { [weak self] point in self?.renameCandidate(at: point) }
        table.action = #selector(completedTableClick)
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel(L10n.text("table.accessibility"))
        table.setAccessibilityIdentifier("explorer.files")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        ExplorerStyle.configureMenu(menu)
    }

    func navigate(_ action: NavigationAction) {
        endInlineRename()
        // Prevent accidental actions on stale rows while a new destination is pending.
        if !session.blocksInteraction { rememberView() }
        workspace.activeTab?.prepareForUserNavigation()
        if let id = workspace.activeID { restorationFallbackTabs.remove(id) }
        session.navigate(action)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard !session.blocksInteraction, visibleEntries.indices.contains(row) else { return nil }
        return FileClipboard.pasteboardWriter(for: visibleEntries[row].url)
    }
    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, visibleEntries.indices.contains(row), visibleEntries[row].secureFolderURL != nil { return nil }
        if operation == .on, visibleEntries.indices.contains(row), visibleEntries[row].canNavigate {
            return visibleEntries[row].url
        }
        return session.history.current.url
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !session.blocksInteraction else { return [] }
        guard let destination = dropDestination(row: row, operation: operation) else { return [] }
        if !(operation == .on && visibleEntries.indices.contains(row) && visibleEntries[row].canNavigate) {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return FileDrop.operation(for: FileDrop.readURLs(from: info), to: destination,
                                  allowed: FileDrop.allowedOperations(for: info))
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard !session.blocksInteraction else { return false }
        let urls = FileDrop.readURLs(from: info)
        guard let destination = dropDestination(row: row, operation: operation) else { return false }
        let action = FileDrop.operation(for: urls, to: destination, allowed: FileDrop.allowedOperations(for: info))
        guard action == .copy || action == .move else { return false }
        FileCommands.shared.transfer(urls, to: destination, move: action == .move)
        return FileCommands.shared.task != nil
    }

    private func rememberView() {
        guard let tab = workspace.activeTab else { return }
        tab.filterQuery = filter.stringValue
        session.remember(selection: selectedPaths(), scrollOffset: fileScroll.contentView.bounds.origin.y)
    }

    private func selectedPaths() -> Set<String> {
        Set(table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0].id : nil })
    }

    private func renderSession() {
        guard let tab = workspace.activeTab else { return }
        lastLocation = tab.session.history.current.url
        let changedTab = renderedTabID != tab.id
        if changedTab || tab.session.blocksInteraction { endInlineRename() }
        if tab.session.blocksInteraction { gitState.stop() }
        else { gitState.beginNavigation(to: tab.session.history.current.url) }
        renderedTabID = tab.id
        rendering = true
        filter.stringValue = tab.filterQuery
        table.sortDescriptors = [NSSortDescriptor(key: tab.sortKey.rawValue, ascending: tab.sortAscending)]
        rendering = false
        backButton.isEnabled = !session.history.back.isEmpty
        forwardButton.isEnabled = !session.history.forward.isEmpty
        upButton.isEnabled = !session.history.current.url.explorerIsRoot
        table.isEnabled = !session.blocksInteraction
        let restoredFallback = tab.restorationUnavailableURL != nil || restorationFallbackTabs.contains(tab.id)
        errorLabel.stringValue = L10n.directoryError(session.failure) ?? (restoredFallback ? L10n.text("options.restore_unavailable") : "")
        errorLabel.toolTip = errorLabel.stringValue
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        hiddenButton.state = session.showHidden ? .on : .off
        tree.setShowHidden(session.showHidden)
        let url = session.history.current.url
        if changedTab || renderedPath != url.explorerIdentity { addressSuggestions.dismiss() }
        let editingAddress = (window?.firstResponder as? NSTextView)?.delegate as? NSTextField === address
        if changedTab || renderedPath != url.explorerIdentity || !editingAddress { address.stringValue = CloudAccounts.shared.address(for: url) }
        renderedPath = url.explorerIdentity
        window?.title = L10n.format("window.title", url.isFileURL ? (url.path == "/" ? L10n.text("tree.computer") : url.lastPathComponent) : CloudAccounts.shared.title(for: url))
        window?.representedURL = url.isFileURL ? url : nil
        rebuildBreadcrumbs(url)
        if changedTab || !session.isLoading {
            rebuildRows(selection: session.history.current.selectedPaths, scroll: session.history.current.scrollOffset)
            tree.selectIfVisible(url)
        }
        filter.isEnabled = !session.blocksInteraction
        updatePreviewSelection()
        if session.isLoading {
            progress.startAnimation(nil)
            if session.blocksInteraction {
                status.stringValue = L10n.text("status.loading")
                openButton.isEnabled = false; copyButton.isEnabled = false
                message.isHidden = true
            }
            return
        }
        progress.stopAnimation(nil)
        gitState.update(directory: url, entries: session.entries, force: forceGitRefresh)
        forceGitRefresh = false
    }

    private func renderGit() {
        gitSummary.stringValue = GitDecoration.summary(gitState.result)
        gitSummary.isHidden = gitSummary.stringValue.isEmpty
        gitSummary.toolTip = gitSummary.stringValue
        gitSummary.setAccessibilityLabel(gitSummary.stringValue)
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        if column >= 0 {
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: column))
        }
        tree.updateGit(snapshot: gitState.snapshot, roots: gitState.repositoryRootPaths)
    }

    private func rebuildRows(selection: Set<String>, scroll: Double? = nil) {
        let query = filter.stringValue
        let entries = session.entries.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        let descriptor = table.sortDescriptors.first
        let localization = L10n.current
        visibleEntries = EntryOrdering.sorted(entries, by: EntrySortKey(rawValue: descriptor?.key ?? "name") ?? .name,
                                              ascending: descriptor?.ascending ?? true, kindName: localization.fileKind)
        rendering = true
        table.reloadData()
        let indexes = IndexSet(visibleEntries.indices.filter { selection.contains(visibleEntries[$0].id) })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if let scroll {
            table.layoutSubtreeIfNeeded()
            let top = -fileScroll.contentView.contentInsets.top
            let maximum = max(top, table.bounds.height - fileScroll.contentView.bounds.height)
            fileScroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(top, scroll == 0 ? top : scroll))))
            fileScroll.reflectScrolledClipView(fileScroll.contentView)
            if scroll == 0, let first = indexes.first { table.scrollRowToVisible(first) }
        }
        rendering = false
        positionRenameField()
        let location = session.history.current.url
        let cloudOverview = location.scheme == RemoteLocation.scheme && (location.host == nil || location.host == "")
        message.stringValue = query.isEmpty ? L10n.text(cloudOverview ? "cloud.empty" : "empty.folder") : L10n.text("empty.filter")
        message.isHidden = !visibleEntries.isEmpty || session.errorMessage != nil
        updateStatus()
    }

    private func rebuildBreadcrumbs(_ url: URL) {
        for view in breadcrumbs.arrangedSubviews { breadcrumbs.removeArrangedSubview(view); view.removeFromSuperview() }
        var paths: [URL] = [], current = url
        while true {
            paths.insert(current, at: 0)
            if current.explorerIsRoot { break }
            current = current.explorerParent
        }
        let shown = paths.count > 5 ? [paths[0]] + Array(paths.suffix(4)) : paths
        for (index, path) in shown.enumerated() {
            if index > 0 { breadcrumbs.addArrangedSubview(ExplorerStyle.label(index == 1 && paths.count > 5 ? "› … ›" : "›", color: .tertiaryLabelColor)) }
            let title = path.isFileURL ? (path.path == "/" ? L10n.text("tree.computer") : path.lastPathComponent) : CloudAccounts.shared.title(for: path)
            let button = BreadcrumbButton(title: title,
                                          target: self, action: #selector(breadcrumbClicked))
            button.destination = path; button.isBordered = false
            button.font = ExplorerStyle.font(.bars, weight: path == url ? .semibold : .regular)
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = CloudAccounts.shared.address(for: path)
            button.setAccessibilityLabel(L10n.format("breadcrumbs.go_to", CloudAccounts.shared.address(for: path)))
            breadcrumbs.addArrangedSubview(button)
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbs.addArrangedSubview(spacer)
    }

    private func updateStatus() {
        let count = table.selectedRowIndexes.count
        status.stringValue = L10n.current.listingStatus(visible: visibleEntries.count, total: session.entries.count,
                                                     filtered: !filter.stringValue.isEmpty, selected: count)
        openButton.isEnabled = count == 1 && !session.blocksInteraction
        copyButton.isEnabled = count > 0 && !session.blocksInteraction
        updatePreviewSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        visibleEntries.indices.contains(row) ? visibleEntries[row].displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions) : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row), let column = tableColumn else { return nil }
        let entry = visibleEntries[row]
        if column.identifier.rawValue == "name" {
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? FileNameCell) ?? FileNameCell()
            cell.identifier = column.identifier
            cell.label.isHidden = inlineRename?.entry.id == entry.id
            cell.label.stringValue = entry.displayName(showExtensions: ExplorerStyle.preferences.showFileExtensions)
            cell.label.font = ExplorerStyle.font(.files)
            FileTypeIcon.configure(cell, for: entry, rowHeight: tableView.rowHeight)
            GitDecoration.apply(to: cell, url: entry.url, directory: entry.canNavigate,
                snapshot: gitState.snapshot, roots: gitState.repositoryRootPaths, baseTooltip: CloudAccounts.shared.address(for: entry.url))
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField) ?? ExplorerStyle.label("", area: .files)
        cell.identifier = column.identifier
        cell.font = ExplorerStyle.font(.files)
        cell.textColor = .secondaryLabelColor
        switch column.identifier.rawValue {
        case "modified": cell.stringValue = entry.modified.map { L10n.current.date($0) } ?? "—"
        case "kind": cell.stringValue = L10n.current.fileKind(entry)
        case "size":
            cell.alignment = .left
            cell.stringValue = entry.isDirectory ? "—" : entry.size.map { L10n.current.bytes($0) } ?? "—"
        default: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !rendering, let tab = workspace.activeTab else { return }
        tab.sortKey = EntrySortKey(rawValue: table.sortDescriptors.first?.key ?? "name") ?? .name
        tab.sortAscending = table.sortDescriptors.first?.ascending ?? true
        if !restoringLayout {
            ExplorerStyle.browserPreferences.sortKey = tab.sortKey
            ExplorerStyle.browserPreferences.sortAscending = tab.sortAscending
        }
        rebuildRows(selection: selectedPaths())
        onSessionChange?()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rendering else { return }
        endInlineRename()
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === address {
            addressSuggestions.update(address, base: session.history.current.url, showHidden: session.showHidden)
            return
        }
        guard (obj.object as? NSSearchField) === filter else { return }
        workspace.activeTab?.filterQuery = filter.stringValue
        rebuildRows(selection: selectedPaths(), scroll: 0)
    }

    @objc func goBack(_ sender: Any?) { navigate(.back) }
    @objc func goForward(_ sender: Any?) { navigate(.forward) }
    @objc func goUp(_ sender: Any?) { navigate(.up) }
    @objc func refresh(_ sender: Any?) { forceGitRefresh = true; tree.refresh(); navigate(.reload) }
    @objc func toggleFileExtensions(_ sender: Any?) {
        ExplorerStyle.preferences.setShowFileExtensions(!ExplorerStyle.preferences.showFileExtensions)
    }
    @objc func togglePreviewPane(_ sender: Any?) {
        ExplorerStyle.preferences.setShowPreviewPane(!ExplorerStyle.preferences.showPreviewPane)
        updatePreviewVisibility()
    }

    func updatePreviewVisibility() {
        let show = ExplorerStyle.preferences.showPreviewPane
        previewButton.state = show ? .on : .off
        guard show != previewPaneVisible else { updatePreviewSelection(); return }
        let sidebar = sidebarWidth
        let scroll = fileScroll.contentView.bounds.origin
        if show {
            previewPane.view.frame.size.width = lastPreviewWidth
            split.addArrangedSubview(previewPane.view)
            window?.contentView?.layoutSubtreeIfNeeded()
            let availableSidebar = split.bounds.width - 430 - 220 - 2 * split.dividerThickness
            split.setPosition(max(165, min(sidebar, availableSidebar)), ofDividerAt: 0)
            previewPaneWidth = lastPreviewWidth
        } else {
            lastPreviewWidth = previewPane.view.frame.width
            if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: previewPane.view) {
                window?.makeFirstResponder(table)
            }
            previewPane.closePreview()
            split.removeArrangedSubview(previewPane.view)
            previewPane.view.removeFromSuperview()
            window?.contentView?.layoutSubtreeIfNeeded()
            split.setPosition(sidebar, ofDividerAt: 0)
        }
        split.adjustSubviews()
        fileScroll.contentView.scroll(to: scroll)
        fileScroll.reflectScrolledClipView(fileScroll.contentView)
        updatePreviewSelection()
    }

    var previewPaneVisible: Bool { previewPane.isViewLoaded && previewPane.view.superview === split }
    var previewedURL: URL? { previewPane.previewedURL }
    var previewImageLoaded: Bool { previewPane.previewImageLoaded }
    var previewMessage: String { previewPane.message }
    var previewPaneWidth: CGFloat {
        get { previewPaneVisible ? previewPane.view.frame.width : lastPreviewWidth }
        set {
            lastPreviewWidth = max(220, newValue)
            guard previewPaneVisible else { return }
            let maximum = max(220, split.bounds.width - sidebarWidth - 430 - 2 * split.dividerThickness)
            let width = min(lastPreviewWidth, maximum)
            split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 1)
        }
    }

    private func updatePreviewSelection() {
        guard previewPaneVisible else { return }
        let entries = session.blocksInteraction ? [] : table.selectedRowIndexes.compactMap {
            visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil
        }
        previewPane.update(entries: entries)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        splitView.subviews.count > 1 && view === splitView.subviews[1]
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { return max(proposedMinimumPosition, 165) }
        return max(proposedMinimumPosition, sidebarWidth + splitView.dividerThickness + 430)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 {
            let reserved: CGFloat = previewPaneVisible ? 430 + 220 + 2 * splitView.dividerThickness : 430 + splitView.dividerThickness
            return min(proposedMaximumPosition, splitView.bounds.width - reserved)
        }
        return min(proposedMaximumPosition, splitView.bounds.width - 220 - splitView.dividerThickness)
    }

    @objc private func showFontSettings(_ sender: Any?) { onShowFontSettings?() }
    @objc private func manageCloud(_ sender: Any?) { onManageCloud?() }
    func refreshFileNames() {
        if !session.blocksInteraction { rememberView() }
        renderSession()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFileExtensions) {
            menuItem.state = ExplorerStyle.preferences.showFileExtensions ? .on : .off
        }
        if menuItem.action == #selector(togglePreviewPane) {
            menuItem.state = ExplorerStyle.preferences.showPreviewPane ? .on : .off
        }
        let entries = commandEntries(menuItem)
        let local = entries.allSatisfy { $0.url.isFileURL }
        switch menuItem.action {
        case #selector(undoFileOperation):
            menuItem.title = FileCommands.shared.undoTitle
            return !FileCommands.shared.isBusy && FileCommands.shared.undoKind != nil
        case #selector(cutFiles), #selector(compressFiles):
            return local && !entries.isEmpty && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(trashFiles): return !entries.isEmpty && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(copyFiles): return !entries.isEmpty && !session.blocksInteraction
        case #selector(shareFiles): return FileSharingController.supports(entries.map(\.url)) && !session.blocksInteraction
        case #selector(extractText): return !session.blocksInteraction && Self.canExtractText(entries)
        case #selector(batchOCR): return !session.blocksInteraction && Self.canBatchOCR(entries)
        case #selector(renameFile): return local && entries.count == 1 && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(pasteFiles):
            guard menuItem.menu === table.menu || acceptsFileListCommands else { return false }
            let destination = menuItem.menu === table.menu && entries.count == 1 && entries[0].canNavigate ? entries[0].url : session.history.current.url
            return FileCommands.shared.canPaste(into: destination) && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(newFolder): return (menuItem.menu === table.menu || acceptsFileListCommands) && session.history.current.url.isFileURL && !session.blocksInteraction && !FileCommands.shared.isBusy
        case #selector(extractFile): return local && entries.count == 1 && !entries[0].isDirectory && entries[0].url.pathExtension.lowercased() == "zip" && !FileCommands.shared.isBusy
        case #selector(properties), #selector(openSelected): return entries.count == 1 && !session.blocksInteraction
        case #selector(openWith): return local && !entries.isEmpty && entries.allSatisfy { !$0.canNavigate }
        case #selector(openSelectedInNewTab): return entries.count == 1 && entries[0].canNavigate
        case #selector(copyPath): return !entries.isEmpty
        default: return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        endInlineRename()
        if table.clickedRow >= 0, visibleEntries.indices.contains(table.clickedRow) {
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            contextEntries = table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil }
        } else { contextEntries = [] }
        rebuildContextMenu(menu, entries: contextEntries)
    }

    func rebuildContextMenu(_ menu: NSMenu, entries: [FileEntry]) {
        contextEntries = entries
        menu.removeAllItems()
        func item(_ key: String, _ action: Selector, _ symbol: String) {
            let entry = menu.addItem(withTitle: L10n.text(key), action: action, keyEquivalent: "")
            entry.target = self
            entry.image = ExplorerStyle.symbol(symbol, description: entry.title)
        }
        if !contextEntries.isEmpty {
            item("command.cut_files", #selector(cutFiles), "scissors")
            item("command.copy_files", #selector(copyFiles), "doc.on.doc")
            item("command.share", #selector(shareFiles), "square.and.arrow.up")
            if contextEntries.count == 1 && contextEntries[0].canNavigate {
                item("command.paste_files", #selector(pasteFiles), "doc.on.clipboard")
            }
            if contextEntries.count == 1, let entry = contextEntries.first, entry.url.isFileURL {
                if let vault = entry.secureFolderURL {
                    if secureFolders?.isUnlocked(vault) == true {
                        item("vault.lock_one", #selector(lockVault), "lock")
                    }
                    item("vault.unlock", #selector(unlockVault), "lock.open")
                    item("vault.reset", #selector(resetVault), "key")
                } else if entry.isDirectory && !entry.isSymbolicLink && !entry.isPackage {
                    item("vault.protect", #selector(protectFolder), "lock")
                }
            }
            item("command.rename", #selector(renameFile), "pencil")
            item(contextEntries.allSatisfy { $0.url.isFileURL } ? "command.trash" : "command.delete", #selector(trashFiles), "trash")
            menu.addItem(.separator())
            item(contextEntries.count == 1 && !contextEntries[0].url.isFileURL && !contextEntries[0].canNavigate ? "cloud.open_copy" : "command.open", #selector(openSelected), "arrow.up.forward.square")
            item("command.open_new_tab", #selector(openSelectedInNewTab), "plus.square.on.square")
            item("command.open_with", #selector(openWith), "app")
            item("ocr.title", #selector(extractText), "text.viewfinder")
            item("ocr.batch.title", #selector(batchOCR), "doc.on.doc")
            menu.addItem(.separator())
            item("command.compress", #selector(compressFiles), "archivebox")
            if contextEntries.count == 1 && contextEntries[0].url.pathExtension.lowercased() == "zip" {
                item("command.extract", #selector(extractFile), "shippingbox")
            }
            item("command.copy_path", #selector(copyPath), "link")
            menu.addItem(.separator())
            item("command.properties", #selector(properties), "info.circle")
        } else {
            item("command.new_folder", #selector(newFolder), "folder.badge.plus")
            item("command.paste_files", #selector(pasteFiles), "doc.on.clipboard")
            item("command.undo_files", #selector(undoFileOperation), "arrow.uturn.backward")
            menu.addItem(.separator())
            item("command.refresh", #selector(refresh), "arrow.clockwise")
        }
        addGitMenu(to: menu, entries: entries)
        ExplorerStyle.configureMenu(menu)
    }

    private func addGitMenu(to menu: NSMenu, entries: [FileEntry]) {
        let directory = session.history.current.url
        guard directory.isFileURL, !session.blocksInteraction else { return }
        let childRoots = entries.filter { gitState.repositoryRootPaths.contains($0.url.standardizedFileURL.path) }
        let root: URL
        if let child = childRoots.first {
            guard entries.count == 1 else { return }
            root = child.url
        } else if let active = gitSnapshot?.rootURL { root = active }
        else { return }
        guard let selection = GitSelection(root: root, urls: entries.isEmpty ? [directory] : entries.map(\.url)) else { return }
        let submenu = NSMenu(title: "Git")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Git", action: nil, keyEquivalent: "").submenu = submenu
        for command in ["changes", "history", "copy_branch", "terminal", "root"] + GitInteractiveAction.allCases.map(\.rawValue) {
            if ["stage", "createBranch", "fetch"].contains(command) { submenu.addItem(.separator()) }
            let item = submenu.addItem(withTitle: L10n.text("git." + command), action: #selector(openGitAction(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(command)
            item.representedObject = selection
        }
    }

    @objc private func openGitAction(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? GitSelection else { return }
        let command = sender.identifier?.rawValue
        if command == "history" || command == "changes" {
            gitReview?.close()
            gitReview = GitReviewController(selection: selection, history: command == "history")
            gitReview?.showWindow(self)
            return
        }
        if let command, let action = GitInteractiveAction(rawValue: command) {
            prepareGitOperation(action, selection: selection)
            return
        }
        let generation = vaultPresentationGeneration
        Task {
            let result = await GitStatusService().inspect(directory: selection.root, force: true)
            guard generation == vaultPresentationGeneration else { return }
            guard case .repository(let snapshot) = result, snapshot.rootURL.path == selection.root.path else {
                showGitMessage(L10n.text("git.unavailable")); return
            }
            switch command {
            case "copy_branch":
                guard let branch = snapshot.branch else { showGitMessage(L10n.text("git.detached")); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(branch, forType: .string)
            case "terminal":
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    showGitMessage(L10n.text("git.reason.commandFailed")); return
                }
                do { _ = try await NSWorkspace.shared.open([selection.root], withApplicationAt: terminal, configuration: .init()) }
                catch { showGitMessage(error.localizedDescription) }
            case "root": navigate(.visit(selection.root))
            default: break
            }
        }
    }

    private func showVolumeProperties(at url: URL, mount: VolumeMount?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = url.path == "/" ? L10n.text("command.properties") : url.lastPathComponent
        alert.informativeText = L10n.text("status.loading")
        alert.addButton(withTitle: L10n.text("dialog.confirm"))
        let query = Task {
            let result = await Task.detached(priority: .userInitiated) {
                let capacity = try (mount ?? VolumeMount.identify(at: url)).capacity()
                let name = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
                return (capacity, name)
            }.result
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let (capacity, name)):
                if let name { alert.messageText = name }
                alert.informativeText = [("volume.total", capacity.total), ("volume.used", capacity.used), ("volume.free", capacity.free)]
                    .map { L10n.text($0.0) + "   " + L10n.current.bytes($0.1) }
                    .joined(separator: "\n")
            case .failure: alert.informativeText = L10n.text("volume.unavailable")
            }
            alert.layout()
        }
        alert.beginSheetModal(for: window) { _ in query.cancel() }
    }

    func showGitMessage(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Git"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    /// File-list shortcuts must never act on its retained selection while the tree or
    /// another control is focused. An explicitly clicked table context menu is separate.
    var acceptsFileListCommands: Bool {
        guard let responder = window?.firstResponder, !(responder is NSTextView) else { return false }
        return responder === table || (responder as? NSView)?.isDescendant(of: table) == true
    }

    private func commandEntries(_ sender: Any?) -> [FileEntry] {
        if let item = sender as? NSMenuItem, item.menu === table.menu { return contextEntries }
        guard acceptsFileListCommands else { return [] }
        return table.selectedRowIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil }
    }
    @objc func cutFiles(_ sender: Any?) {
        let entries = commandEntries(sender)
        if entries.allSatisfy({ $0.url.isFileURL }) { FileCommands.shared.copy(entries, cut: true) }
    }
    @objc func copyFiles(_ sender: Any?) { FileCommands.shared.copy(commandEntries(sender), cut: false) }
    static func canExtractText(_ entries: [FileEntry]) -> Bool {
        entries.count == 1 && !entries[0].isDirectory && !entries[0].isPackage && !entries[0].isAlias
            && !entries[0].isSymbolicLink && OCRService.canRecognize(entries[0].url)
    }
    static func canBatchOCR(_ entries: [FileEntry]) -> Bool {
        (1...50).contains(entries.count) && entries.allSatisfy { canExtractText([$0]) }
    }
    @objc func batchOCR(_ sender: Any?) {
        let entries = commandEntries(sender)
        guard !session.blocksInteraction, Self.canBatchOCR(entries) else { return }
        onBatchOCR?(entries.map(\.url))
    }
    @objc func extractText(_ sender: Any?) {
        let entries = commandEntries(sender)
        guard !session.blocksInteraction, Self.canExtractText(entries) else { return }
        onExtractText?(entries[0].url)
    }
    private(set) var sharingTask: Task<Void, Never>?
    @objc func shareFiles(_ sender: Any?) {
        let urls = commandEntries(sender).map(\.url)
        guard !session.blocksInteraction, FileSharingController.supports(urls) else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        let anchor = row >= 0 ? table.rect(ofRow: row).intersection(table.visibleRect) : table.visibleRect
        sharingTask?.cancel()
        sharingTask = Task {
            do {
                try await fileSharing.share(urls, relativeTo: anchor.isEmpty ? table.visibleRect : anchor, of: table)
            } catch is CancellationError {
                return
            } catch {
                errorLabel.stringValue = L10n.text("share.unavailable")
                errorLabel.toolTip = errorLabel.stringValue
                errorLabel.isHidden = false
            }
        }
    }

    @objc func pasteFiles(_ sender: Any?) {
        let entries = commandEntries(sender)
        let insideFolder = (sender as? NSMenuItem)?.menu === table.menu && entries.count == 1 && entries[0].canNavigate
        FileCommands.shared.paste(into: insideFolder ? entries[0].url : session.history.current.url)
    }
    @objc func moveFilesHere(_ sender: Any?) { FileCommands.shared.paste(into: session.history.current.url, move: true) }
    @objc func undoFileOperation(_ sender: Any?) { FileCommands.shared.undo() }
    @objc private func completedTableClick() { table.completedClick() }

    private func nameCell(at row: Int) -> FileNameCell? {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, row >= 0, row < table.numberOfRows else { return nil }
        return table.view(atColumn: column, row: row, makeIfNecessary: true) as? FileNameCell
    }

    private func renameCandidate(at point: NSPoint) -> (() -> Void)? {
        let row = table.row(at: point)
        guard row >= 0, table.selectedRowIndexes == IndexSet(integer: row),
              visibleEntries.indices.contains(row), let cell = nameCell(at: row),
              visibleEntries[row].url.isFileURL else { return nil }
        let label = cell.label
        var textRect = label.bounds
        textRect.size.width = min(textRect.width, label.intrinsicContentSize.width)
        guard textRect.contains(label.convert(point, from: table)) else { return nil }
        let entry = visibleEntries[row]
        let tabID = workspace.activeID
        return { [weak self] in
            guard let self, self.workspace.activeID == tabID, self.window?.isKeyWindow == true,
                  self.acceptsFileListCommands, self.window?.attachedSheet == nil,
                  !self.session.blocksInteraction, !FileCommands.shared.isBusy,
                  self.selectedPaths() == [entry.id] else { return }
            self.beginInlineRename(entry)
        }
    }

    private func beginInlineRename(_ entry: FileEntry) {
        let field = NSTextField(string: entry.name)
        field.font = ExplorerStyle.font(.files)
        field.usesSingleLineMode = true
        field.setAccessibilityLabel(L10n.text("dialog.name"))
        field.delegate = self
        inlineRename = (entry, field)
        fileScroll.contentView.addSubview(field)
        positionRenameField()
        guard inlineRename != nil, window?.makeFirstResponder(field) == true else { endInlineRename(); return }
        let stem = entry.isDirectory ? entry.name : (entry.name as NSString).deletingPathExtension
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
    }

    private func positionRenameField() {
        guard let edit = inlineRename else { return }
        let row = table.selectedRow
        guard table.numberOfSelectedRows == 1, visibleEntries.indices.contains(row),
              visibleEntries[row].id == edit.entry.id, let cell = nameCell(at: row) else { endInlineRename(); return }
        cell.label.isHidden = true
        edit.field.frame = cell.label.convert(cell.label.bounds, to: fileScroll.contentView).insetBy(dx: -2, dy: -2)
    }

    private func endInlineRename() {
        table.cancelRenameClick()
        guard let edit = inlineRename else { return }
        inlineRename = nil
        edit.field.delegate = nil
        edit.field.abortEditing()
        edit.field.removeFromSuperview()
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        if column >= 0, let row = visibleEntries.firstIndex(where: { $0.id == edit.entry.id }), row < table.numberOfRows,
           let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? FileNameCell {
            cell.label.isHidden = false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if control === address {
            return addressSuggestions.handle(command, editor: textView) { path in
                textView.insertText(path, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            }
        }
        guard let edit = inlineRename, control === edit.field, !textView.hasMarkedText() else { return false }
        let confirm = command == #selector(NSResponder.insertNewline(_:))
        guard confirm || command == #selector(NSResponder.cancelOperation(_:)) else { return false }
        let name = textView.string
        endInlineRename()
        window?.makeFirstResponder(table)
        if confirm, name != edit.entry.name { FileCommands.shared.rename(edit.entry, to: name) }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === address { addressSuggestions.dismiss() }
        if let field = inlineRename?.field, notification.object as? NSTextField === field { endInlineRename() }
    }

    @objc func renameFile(_ sender: Any?) { if let entry = commandEntries(sender).first { FileCommands.shared.rename(entry) } }
    @objc func newFolder(_ sender: Any?) { FileCommands.shared.newFolder(in: session.history.current.url) }
    @objc func trashFiles(_ sender: Any?) { FileCommands.shared.trash(commandEntries(sender)) }
    @objc func compressFiles(_ sender: Any?) { FileCommands.shared.compress(commandEntries(sender), in: session.history.current.url) }
    @objc func extractFile(_ sender: Any?) { if let entry = commandEntries(sender).first { FileCommands.shared.extract(entry, in: session.history.current.url) } }
    @objc private func properties(_ sender: Any?) { if let entry = commandEntries(sender).first { FileCommands.shared.properties(entry) } }
    @objc private func openWith(_ sender: Any?) { FileCommands.shared.openWith(commandEntries(sender)) }
    func operationFinished(urls: [URL], tabID: UUID?) {
        tree.refresh()
        guard workspace.activeID == tabID else { return }
        if !session.blocksInteraction { rememberView() }
        let location = session.history.current.url
        let selected = urls.compactMap { url -> URL? in
            if url.isFileURL, location.isFileURL {
                guard url.explorerParent.resolvingSymlinksInPath().standardizedFileURL == location.resolvingSymlinksInPath().standardizedFileURL else { return nil }
                return location.appendingPathComponent(url.lastPathComponent)
            }
            return url.explorerParent.explorerIdentity == location.explorerIdentity ? url : nil
        }
        if !selected.isEmpty { session.remember(selection: Set(selected.map(\.explorerIdentity)), scrollOffset: 0) }
        session.navigate(.reload)
    }
    @objc func focusAddress(_ sender: Any?) { window?.makeFirstResponder(address); address.selectText(nil) }

    @objc private func breadcrumbClicked(_ sender: BreadcrumbButton) {
        if let url = sender.destination { navigate(.visit(url)) }
    }

    @objc private func addressSubmitted(_ sender: Any?) {
        addressSuggestions.dismiss()
        guard let url = CloudAccounts.shared.resolve(address.stringValue) ?? AddressParser.resolve(address.stringValue, relativeTo: session.history.current.url) else {
            errorLabel.stringValue = L10n.text("error.address")
            errorLabel.isHidden = false
            return
        }
        navigate(.visit(url))
        window?.makeFirstResponder(table)
    }

    @objc private func toggleHidden(_ sender: Any?) {
        if !session.blocksInteraction { rememberView() }
        workspace.activeTab?.prepareForUserNavigation()
        session.toggleHidden()
        onSessionChange?()
        ExplorerStyle.browserPreferences.showHidden = session.showHidden
    }

    @objc private func openSelected(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        let row = sender is NSMenuItem && table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard visibleEntries.indices.contains(row) else { return }
        let entry = visibleEntries[row]
        if let vault = entry.secureFolderURL { secureFolders?.unlock(vault) }
        else if entry.canNavigate { navigate(.visit(entry.url)) }
        else if !entry.url.isFileURL { FileCommands.shared.openRemote(entry) }
        else if MediaKind.detect(entry) != nil, let onOpenMedia {
            onOpenMedia(visibleEntries, entry.url)
        }
        else if !NSWorkspace.shared.open(entry.url) {
            errorLabel.stringValue = L10n.format("error.open_file", entry.name)
            errorLabel.isHidden = false
        }
    }

    @objc func openSelectedInNewTab(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        let row = sender is NSMenuItem && table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard visibleEntries.indices.contains(row), visibleEntries[row].canNavigate else { return }
        addTab(at: visibleEntries[row].url)
    }

    @discardableResult
    func addTab(at url: URL) -> ExplorerTab {
        if !session.blocksInteraction { rememberView() }
        let preferences = ExplorerStyle.browserPreferences
        return workspace.addTab(at: url, sortKey: preferences.sortKey, sortAscending: preferences.sortAscending, showHidden: preferences.showHidden)
    }

    func selectTab(id: UUID) {
        if !session.blocksInteraction { rememberView() }
        workspace.select(id)
        window?.makeFirstResponder(table)
    }

    func closeTab(id: UUID) {
        if !session.blocksInteraction { rememberView() }
        workspace.close(id)
    }

    @objc func newTab(_ sender: Any?) { addTab(at: session.history.current.url) }
    @objc func closeCurrentTab(_ sender: Any?) {
        if let id = workspace.activeID { closeTab(id: id) }
    }

    func cycleTab(backwards: Bool = false) {
        if !session.blocksInteraction { rememberView() }
        workspace.selectNext(backwards: backwards)
        window?.makeFirstResponder(table)
    }

    var activeTabIsVisible: Bool {
        guard let index = workspace.tabs.firstIndex(where: { $0.id == workspace.activeID }),
              tabStrip.arrangedSubviews.indices.contains(index) else { return false }
        let view = tabStrip.arrangedSubviews[index]
        return view.visibleRect.width >= view.bounds.width - 1
    }

    var sidebarWidth: CGFloat {
        get { split.subviews.first?.frame.width ?? 230 }
        set { split.setPosition(newValue, ofDividerAt: 0) }
    }

    @objc private func tabSelected(_ sender: TabActionButton) {
        if let id = sender.tabID { selectTab(id: id) }
    }

    @objc private func tabClosed(_ sender: TabActionButton) {
        if let id = sender.tabID { closeTab(id: id) }
    }

    private func renderTabs() {
        for view in tabStrip.arrangedSubviews { tabStrip.removeArrangedSubview(view); view.removeFromSuperview() }
        var selectedSurface: NSView?
        for tab in workspace.tabs {
            let url = tab.session.history.current.url
            let title = url.isFileURL ? (url.path == "/" ? L10n.text("tree.computer") : url.lastPathComponent) : CloudAccounts.shared.title(for: url)
            let select = TabActionButton(title: title, target: self, action: #selector(tabSelected))
            select.tabID = tab.id; select.isBordered = false
            select.lineBreakMode = .byTruncatingMiddle
            select.alignment = .left
            select.font = ExplorerStyle.font(.bars)
            select.image = ExplorerStyle.symbol(tab.session.isLoading ? "clock" : url.isFileURL ? "folder" : "cloud", description: L10n.text("kind.folder"))
            select.imagePosition = .imageLeading
            select.toolTip = CloudAccounts.shared.address(for: url)
            select.setAccessibilityLabel(L10n.format(tab.id == workspace.activeID ? "tab.selected_accessibility" : "tab.accessibility", title))
            let close = TabActionButton(image: ExplorerStyle.symbol("xmark", description: L10n.text("command.close_tab"))!, target: self, action: #selector(tabClosed))
            close.tabID = tab.id; close.isBordered = false
            close.setAccessibilityLabel(L10n.format("tab.close_accessibility", title))
            close.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let row = ExplorerStyle.stack([select, close], spacing: 6)
            let surface = TabSurface()
            surface.selected = tab.id == workspace.activeID
            if surface.selected { selectedSurface = surface }
            row.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(row)
            NSLayoutConstraint.activate([
                surface.widthAnchor.constraint(equalToConstant: 210),
                surface.heightAnchor.constraint(equalToConstant: 32 + max(0, ExplorerStyle.preferences.fontSize(for: .bars) - 12)),
                row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
                row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
                row.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
            ])
            tabStrip.addArrangedSubview(surface)
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStrip.addArrangedSubview(spacer)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let selectedSurface { selectedSurface.scrollToVisible(selectedSurface.bounds) }
    }

    @objc private func copyPath(_ sender: Any?) {
        guard !session.blocksInteraction else { return }
        var indexes = table.selectedRowIndexes
        if sender is NSMenuItem, table.clickedRow >= 0, !indexes.contains(table.clickedRow) {
            indexes = IndexSet(integer: table.clickedRow)
        }
        let paths = indexes.compactMap { visibleEntries.indices.contains($0) ? CloudAccounts.shared.address(for: visibleEntries[$0].url) : nil }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func focusFilter(_ sender: Any?) {
        guard filter.isEnabled, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              (window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        window?.makeFirstResponder(filter)
        filter.selectText(nil)
    }

    private func installKeyboardNavigation() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard self.workspace.activeTab != nil else { return event }
            self.table.cancelRenameClick()
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if (flags == .control || flags == [.control, .shift]),
               self.window?.attachedSheet == nil, NSApp.modalWindow == nil,
               (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                if key == "+" || key == "=" {
                    ExplorerStyle.preferences.adjustAllFontSizes(by: 1); return nil
                }
                if key == "-" {
                    ExplorerStyle.preferences.adjustAllFontSizes(by: -1); return nil
                }
            }
            if flags == .command || flags == .control {
                if key == "t" { self.newTab(nil); return nil }
                if key == "w" { self.closeCurrentTab(nil); return nil }
            }
            if event.keyCode == 48 && (flags == .control || flags == [.control, .shift]) {
                self.cycleTab(backwards: flags.contains(.shift)); return nil
            }
            if (flags == .command || flags == .control) && key == "l" { self.focusAddress(nil); return nil }
            let editor = self.window?.firstResponder as? NSTextView
            let searchShortcut = ((flags == .command || flags == .control) && key == "f")
                || (event.keyCode == 99 && flags.isEmpty) // F3
            let browserFieldEditor = editor?.delegate as? NSTextField === self.address
                || editor?.delegate as? NSTextField === self.filter
            if searchShortcut, self.filter.isEnabled, self.window?.attachedSheet == nil, NSApp.modalWindow == nil,
               editor?.hasMarkedText() != true,
               editor == nil || (browserFieldEditor && flags != .control) {
                self.focusFilter(nil)
                return nil
            }
            // Ctrl+F and other editing commands remain native in text views, including IME.
            if editor != nil { return event }
            if flags == [.command, .option] && key == "v" {
                if self.acceptsFileListCommands { self.moveFilesHere(nil) }
                return nil
            }
            if flags == .command || flags == .control {
                if key == "z" { FileCommands.shared.undo(); return nil }
                if key == "c" { if self.acceptsFileListCommands { self.copyFiles(nil) }; return nil }
                if key == "x" { if self.acceptsFileListCommands { self.cutFiles(nil) }; return nil }
                if key == "v" { if self.acceptsFileListCommands { self.pasteFiles(nil) }; return nil }
            }
            if event.keyCode == 120 && flags.isEmpty {
                if self.acceptsFileListCommands { self.renameFile(nil) }
                return nil
            }
            if event.keyCode == 117 && flags.isEmpty {
                if self.acceptsFileListCommands { self.trashFiles(nil) }
                return nil
            }
            if flags == .option {
                switch event.keyCode {
                case 123: self.goBack(nil); return nil
                case 124: self.goForward(nil); return nil
                case 126: self.goUp(nil); return nil
                default: break
                }
            }
            if event.keyCode == 96 && flags.isEmpty { self.refresh(nil); return nil }
            if flags == .control && key == "a" {
                if self.acceptsFileListCommands { self.table.selectAll(nil) }
                return nil
            }
            return event
        }
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard AppLanguage.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        onLanguageChange?(AppLanguage.allCases[sender.indexOfSelectedItem])
    }

    @objc private func protectFolder(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.url { secureFolders?.protect(url) }
    }

    @objc private func unlockVault(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.secureFolderURL { secureFolders?.unlock(url) }
    }

    @objc private func lockVault(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.secureFolderURL { secureFolders?.lock(url) }
    }

    @objc private func resetVault(_ sender: NSMenuItem) {
        if let url = commandEntries(sender).first?.secureFolderURL { secureFolders?.reset(url) }
    }

    func concealSecureFolders(_ roots: [URL]) {
        vaultPresentationGeneration += 1
        for sheet in window?.sheets ?? [] {
            if let url = sheet.representedURL, roots.contains(where: { SecureFolderCommands.contains(url, in: $0) }) {
                window?.endSheet(sheet, returnCode: .cancel)
            }
        }
        if let review = gitReview, roots.contains(where: { SecureFolderCommands.contains(review.repositoryRoot, in: $0) }) {
            review.close()
            gitReview = nil
        }
        let affected = workspace.tabs.filter { tab in
            if tab.session.isLoading { return true }
            let history = tab.session.history
            return ([history.current] + history.back + history.forward).contains { snapshot in
                roots.contains { SecureFolderCommands.contains(snapshot.url, in: $0) }
            }
        }
        if !affected.isEmpty {
            window?.makeFirstResponder(table)
            if affected.count == workspace.tabs.count {
                workspace.addTab(at: sidebarHome ?? FileManager.default.homeDirectoryForCurrentUser)
            }
            for tab in affected { workspace.close(tab.id) }
        }
        contextEntries.removeAll()
        previewPane.closePreview()
        tree.resetListing()
    }

    func prepareForLanguageChange() {
        addressSuggestions.dismiss()
        gitReview?.close()
        gitState.stop()
        savePresentation()
        restoringLayout = true // The retired window must not overwrite its replacement.
        previewPane.closePreview()
        sharingTask?.cancel(); sharingTask = nil
        fileSharing.closePicker()
        onClose = nil // Closing a replaced window must not quit the application.
        if !session.blocksInteraction { rememberView() }
        onSessionChange = nil
        workspace.onChange = nil
        workspace.onWillAutoRefresh = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    func windowDidResignKey(_ notification: Notification) { addressSuggestions.dismiss(); endInlineRename() }

    func windowWillClose(_ notification: Notification) {
        addressSuggestions.dismiss()
        endInlineRename()
        gitState.stop()
        savePresentation()
        previewPane.closePreview()
        sharingTask?.cancel(); sharingTask = nil
        fileSharing.closePicker()
        onClose?(workspace.activeTab?.session.history.current.url ?? lastLocation)
    }

    @objc private func showOptions(_ sender: Any?) { onShowOptions?() }

    func restorePresentation(from previous: ExplorerWindowController) {
        restoringLayout = true
        defer { restoringLayout = false; schedulePresentationSave() }
        let editor = previous.window?.firstResponder as? NSTextView
        let textSelection = editor?.selectedRange()
        window?.contentView?.layoutSubtreeIfNeeded()
        split.setPosition(previous.split.subviews.first?.frame.width ?? 230, ofDividerAt: 0)
        previewPaneWidth = previous.previewPaneWidth
        for (index, column) in previous.table.tableColumns.enumerated() {
            let current = table.column(withIdentifier: column.identifier)
            if current >= 0 {
                table.moveColumn(current, toColumn: index)
                table.tableColumns[index].width = column.width
            }
        }
        renderSession()
        if table.rowHeight != previous.table.rowHeight {
            let offset = previous.fileScroll.contentView.bounds.minY / previous.table.rowHeight * table.rowHeight
            fileScroll.contentView.scroll(to: NSPoint(x: 0, y: max(-fileScroll.contentView.contentInsets.top, offset)))
            fileScroll.reflectScrolledClipView(fileScroll.contentView)
        }
        if editor?.delegate as? NSTextField === previous.address {
            address.stringValue = previous.address.stringValue
            window?.makeFirstResponder(address)
        } else if editor?.delegate as? NSTextField === previous.filter {
            window?.makeFirstResponder(filter)
        } else { window?.makeFirstResponder(table) }
        if let textSelection, let restoredEditor = window?.firstResponder as? NSTextView {
            restoredEditor.setSelectedRange(textSelection)
        }
    }

    /// Renders the application's own content view, without accessing other windows or the desktop.
    func savePreview(to url: URL) throws {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
