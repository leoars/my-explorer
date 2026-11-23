// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import ExplorerClipboard

@MainActor
final class FolderOutlineView: NSOutlineView {
    var contextMenuForRow: ((Int) -> NSMenu?)?
    var onDragEnded: (() -> Void)?
    private var dragInside = false { didSet { if oldValue && !dragInside { onDragEnded?() } } }
    /// True only while a drag hovers the tree with the button still held, so a missed
    /// end-of-drag event can never leave manual expansion blocked.
    var dragActive: Bool { dragInside && NSEvent.pressedMouseButtons != 0 }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragInside = true
        return super.draggingEntered(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragInside = false
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragInside = false
        super.draggingEnded(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragInside = false
        return super.performDragOperation(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuForRow?(row(at: point))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift),
           selectedRow >= 0, let menu = contextMenuForRow?(selectedRow) {
            let rect = rect(ofRow: selectedRow)
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 20, y: rect.maxY), in: self)
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class FolderNode: NSObject {
    let url: URL
    var title: String
    let symbol: String
    var volume: VolumeMount?
    var savedSearch: ExplorerSavedSearch?
    var volumeLink = false
    let isGroup: Bool
    var children: [FolderNode]?
    var loading = false
    var needsRefresh = false
    var failure: DirectoryFailure?
    var request = 0
    var task: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var watcher: DirectoryWatcher?

    init(url: URL, title: String? = nil, symbol: String = "folder", isGroup: Bool = false) {
        self.url = url
        self.title = title ?? url.lastPathComponent
        self.symbol = symbol
        self.isGroup = isGroup
    }

    func stopObserving() {
        request += 1
        task?.cancel(); task = nil
        refreshTask?.cancel(); refreshTask = nil
        watcher?.stop(); watcher = nil
        loading = false
        needsRefresh = false
        children?.forEach { $0.stopObserving() }
    }
}

@MainActor
final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = FolderOutlineView()
    let scrollView = NSScrollView()
    var onNavigate: ((URL) -> Void)?
    var onDisconnectCloud: ((UUID) -> Void)?
    var onRemoveMount: ((VolumeMount) -> Void)?
    var onVolumeProperties: ((URL, VolumeMount?) -> Void)?
    var onShowTrash: (() -> Void)?
    private let trashRoot = FolderNode(url: URL(string: "myexplorer-trash:///")!, title: L10n.text("trash.title"), symbol: "trash", isGroup: true)
    var onManageCloud: (() -> Void)?
    private var roots: [FolderNode]
    private let mobileRoot = FolderNode(url: URL(string: "myexplorer-devices:///")!, title: L10n.text("devices.title"), symbol: "iphone", isGroup: true)
    private var mobileDevices: AppleMobileDevices?
    var onSavedSearch: ((ExplorerSavedSearch) -> Void)?
    private let searchLibrary = ExplorerSearchLibrary()
    private let searchRoot = FolderNode(url: URL(string: "myexplorer-search:///")!,
                                        title: L10n.text("search.saved"), symbol: "folder.badge.gearshape", isGroup: true)
    private let cloudRoot: FolderNode
    private var hidden = false
    private var generation = 0
    private var selecting = false
    /// Hover time over one folder before a drag expands it; AppKit's own spring-loading is far too eager.
    static let dragExpandDelay: TimeInterval = 1.0
    /// Tall enough for the tree's font and for icons the same size as the file list's.
    private static var rowHeight: CGFloat {
        max(30, ExplorerStyle.preferences.fontSize(for: .tree) + 12, FileTypeIcon.listIconSide + 7)
    }
    /// The folder the tree is opening its way to, while branches are still being read.
    private var revealTarget: URL?
    private var dragHoverNode: FolderNode?
    private var dragHoverTimer: Timer?
    private var dragExpansionAllowed = false
    private var gitSnapshot: GitStatusSnapshot?
    private var gitRoots: Set<String> = []
    func updateGit(snapshot: GitStatusSnapshot?, roots: Set<String>) {
        gitSnapshot = snapshot; gitRoots = roots
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    init(home: URL) {
        cloudRoot = FolderNode(url: URL(string: "myexplorer-cloud:///")!, title: L10n.text("cloud.title"), symbol: "cloud.fill", isGroup: true)
        roots = [
            FolderNode(url: home, title: L10n.text("tree.home"), symbol: "house"),
            FolderNode(url: home.appendingPathComponent("Desktop"), title: L10n.text("tree.desktop"), symbol: "desktopcomputer"),
            FolderNode(url: home.appendingPathComponent("Downloads"), title: L10n.text("tree.downloads"), symbol: "arrow.down.circle"),
            FolderNode(url: home.appendingPathComponent("Documents"), title: L10n.text("tree.documents"), symbol: "doc"),
            FolderNode(url: home.appendingPathComponent("Pictures"), title: L10n.text("tree.pictures"), symbol: "photo.fill"),
            FolderNode(url: home.appendingPathComponent("Music"), title: L10n.text("tree.music"), symbol: "music.note"),
            FolderNode(url: home.appendingPathComponent("Movies"), title: L10n.text("tree.videos"), symbol: "film.fill"),
            FolderNode(url: URL(fileURLWithPath: "/"), title: L10n.text("tree.computer"), symbol: "internaldrive"),
            FolderNode(url: URL(fileURLWithPath: "/Volumes"), title: L10n.text("tree.volumes"), symbol: "externaldrive")
        ]
        roots.append(cloudRoot)
        roots.append(searchRoot)
        roots.append(mobileRoot)
        roots.append(trashRoot)
        super.init()
        outline.contextMenuForRow = { [weak self] row in self?.contextMenu(for: row) }
        outline.onDragEnded = { [weak self] in self?.cancelDragHover() }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 16
        outline.style = .plain
        outline.backgroundColor = .windowBackgroundColor
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes(FileClipboard.dragTypes)
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityLabel(L10n.text("tree.accessibility"))
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        outline.setAccessibilityIdentifier("explorer.tree")
        reloadCloudConnections()
        reloadSavedSearches()
        CloudAccounts.shared.onChange = { [weak self] in self?.reloadCloudConnections() }
    }

    func saveSearch(_ search: ExplorerSavedSearch) throws {
        try searchLibrary.add(search)
        reloadSavedSearches()
    }

    private func reloadSavedSearches() {
        searchRoot.children = searchLibrary.searches.map { search in
            let node = FolderNode(url: searchRoot.url.appendingPathComponent(search.id.uuidString), title: search.title, symbol: "magnifyingglass")
            node.savedSearch = search
            return node
        }
        selecting = true
        outline.reloadItem(searchRoot, reloadChildren: true)
        if searchRoot.children?.isEmpty == false { expandFromCode { outline.expandItem(searchRoot) } }
        selecting = false
    }

    @objc private func forgetSavedSearch(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        do { try searchLibrary.remove(id); reloadSavedSearches() }
        catch { if let window = outline.window { SearchTagEditor.showError(error.localizedDescription, owner: window) } }
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        if row >= 0, let node = outline.item(atRow: row) as? FolderNode,
           let location = RemoteLocation.parse(node.url), location.key.isEmpty {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: L10n.text("volume.disconnect"), action: #selector(disconnectCloud(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = location.connectionID
            ExplorerStyle.configureMenu(menu)
            return menu
        }
        if row >= 0, let search = (outline.item(atRow: row) as? FolderNode)?.savedSearch {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: L10n.text("search.forget"), action: #selector(forgetSavedSearch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = search.id
            return menu
        }
        guard row >= 0, let node = outline.item(atRow: row) as? FolderNode,
              node.volume != nil || node.url.path == "/" && node.url.isFileURL else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: L10n.text("command.properties"), action: #selector(volumeProperties(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = (node.url, node.volume)
        if let mount = node.volume, let removal = mount.removal {
            let remove = menu.addItem(withTitle: L10n.text(removal == .eject ? "volume.eject" : "volume.disconnect"),
                                      action: #selector(removeMount(_:)), keyEquivalent: "")
            remove.representedObject = mount
            remove.target = self
        }
        ExplorerStyle.configureMenu(menu)
        return menu
    }

    @objc private func disconnectCloud(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onDisconnectCloud?(id) }
    }

    @objc private func removeMount(_ sender: NSMenuItem) {
        if let mount = sender.representedObject as? VolumeMount { onRemoveMount?(mount) }
    }

    @objc private func volumeProperties(_ sender: NSMenuItem) {
        guard let (url, mount) = sender.representedObject as? (URL, VolumeMount?) else { return }
        onVolumeProperties?(url, mount)
    }

    private func reloadCloudConnections() {
        let previous = Dictionary((cloudRoot.children ?? []).map { ($0.url.explorerIdentity, $0) }, uniquingKeysWith: { first, _ in first })
        cloudRoot.children = CloudAccounts.shared.connections.map { connection in
            let url = RemoteLocation.url(connectionID: connection.id)
            let node = previous[url.explorerIdentity] ?? FolderNode(url: url, symbol: "cloud.\(connection.provider.rawValue)")
            node.title = connection.name
            return node
        }
        selecting = true
        outline.reloadItem(cloudRoot, reloadChildren: true)
        if !(cloudRoot.children?.isEmpty ?? true) { expandFromCode { outline.expandItem(cloudRoot) } }
        selecting = false
    }

    func setShowHidden(_ value: Bool) {
        guard hidden != value else { return }
        hidden = value
        resetListing()
    }

    func resetListing() {
        generation += 1
        roots.forEach { $0.stopObserving() }
        for root in roots { root.children = nil; root.loading = false; root.failure = nil }
        reloadCloudConnections()
        reloadSavedSearches()
        selecting = true
        outline.collapseItem(nil, collapseChildren: true)
        outline.reloadData()
        selecting = false
    }

    func relocalize() {
        let keys = ["tree.home", "tree.desktop", "tree.downloads", "tree.documents", "tree.pictures", "tree.music", "tree.videos", "tree.computer", "tree.volumes"]
        for (node, key) in zip(roots, keys) { node.title = L10n.text(key) }
        mobileDevices?.relocalize()
        mobileRoot.title = L10n.text("devices.title")
        searchRoot.title = L10n.text("search.saved")
        cloudRoot.title = L10n.text("cloud.title")
        trashRoot.title = L10n.text("trash.title")
        outline.setAccessibilityLabel(L10n.text("tree.accessibility"))
        outline.rowHeight = Self.rowHeight
        outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    /// Follows the folder open in the list: selects it and, when the option is on, first opens the
    /// branches that lead to it.
    func show(_ url: URL) {
        // The graphical tests drive the tree by hand and expect it to stay as they left it.
        if ExplorerStyle.browserPreferences.expandTreeToOpenFolder, url.isFileURL,
           !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            revealTarget = url
            continueReveal()
        } else {
            revealTarget = nil
            selectIfVisible(url)
        }
    }

    private static func contains(_ ancestor: URL, _ url: URL) -> Bool {
        let base = ancestor.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    /// One step of the way to `revealTarget`: expands the deepest loaded ancestor and waits for its
    /// folders when they are still being read; `load` calls back here when they arrive.
    private func continueReveal() {
        guard let target = revealTarget else { return }
        // Start from the most specific location of the tree that holds the folder (Documents before
        // the home folder, the home folder before the computer).
        let candidates = roots.filter { !$0.isGroup && $0.savedSearch == nil && $0.url.isFileURL && Self.contains($0.url, target) }
        guard var node = candidates.max(by: { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }) else {
            revealTarget = nil
            selectIfVisible(target)
            return
        }
        while node.url.standardizedFileURL.path != target.standardizedFileURL.path {
            if !outline.isItemExpanded(node) {
                guard outline.isExpandable(node) else { break }
                expandFromCode { outline.expandItem(node) }
                // Not expanded yet means its folders are still being read: resume from `load`.
                if !outline.isItemExpanded(node) { if node.loading { return } else { break } }
            }
            guard let next = node.children?.first(where: { Self.contains($0.url, target) }) else { break }
            node = next
        }
        revealTarget = nil
        let row = outline.row(forItem: node)
        guard row >= 0 else { selectIfVisible(target); return }
        selecting = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selecting = false
        outline.scrollRowToVisible(row)
    }

    func selectIfVisible(_ url: URL) {
        selecting = true
        defer { selecting = false }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FolderNode, node.url.explorerIdentity == url.explorerIdentity {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderNode)?.children?.count ?? (item == nil ? roots.count : 0)
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FolderNode, !node.isGroup, node.savedSearch == nil, !node.url.explorerIsRoot else { return nil }
        return FileClipboard.pasteboardWriter(for: node.url)
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        trackDragHover(info)
        guard let node = item as? FolderNode, !node.isGroup, node.savedSearch == nil else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return FileDrop.operation(for: FileDrop.readURLs(from: info), to: node.url,
                                  allowed: FileDrop.allowedOperations(for: info))
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? FolderNode, !node.isGroup, node.savedSearch == nil else { return false }
        let urls = FileDrop.readURLs(from: info)
        let action = FileDrop.operation(for: urls, to: node.url, allowed: FileDrop.allowedOperations(for: info))
        guard action == .copy || action == .move else { return false }
        FileCommands.shared.transfer(urls, to: node.url, move: action == .move)
        return FileCommands.shared.task != nil
    }

    private func cancelDragHover() {
        dragHoverTimer?.invalidate()
        dragHoverTimer = nil
        dragHoverNode = nil
    }

    /// Expands a folder only after the drag rests on that same row for `dragExpandDelay`.
    private func trackDragHover(_ info: any NSDraggingInfo) {
        let row = outline.row(at: outline.convert(info.draggingLocation, from: nil))
        let node = row >= 0 ? outline.item(atRow: row) as? FolderNode : nil
        guard node !== dragHoverNode else { return }
        cancelDragHover()
        dragHoverNode = node
        guard let node, outline.isExpandable(node), !outline.isItemExpanded(node) else { return }
        let timer = Timer(timeInterval: Self.dragExpandDelay, repeats: false) { [weak self, weak node] _ in
            MainActor.assumeIsolated {
                guard let self, let node, self.outline.dragActive, self.dragHoverNode === node else { return }
                self.dragHoverTimer = nil
                self.expandFromCode { self.outline.expandItem(node) }
            }
        }
        dragHoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func expandFromCode(_ body: () -> Void) {
        let previous = dragExpansionAllowed
        dragExpansionAllowed = true
        body()
        dragExpansionAllowed = previous
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FolderNode { return node.children![index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? FolderNode, node === mobileRoot || node.savedSearch != nil { return false }
        // Empty folders can receive new children; keep them retryable and observable.
        return (item as? FolderNode).map { $0 !== trashRoot && !$0.volumeLink } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        // While a drag hovers the tree, only our delayed hover timer (or a pending reload) may expand.
        if outline.dragActive && !dragExpansionAllowed { return false }
        if node === trashRoot || node === mobileRoot || node.savedSearch != nil || node.volumeLink { return false }
        if node.isGroup { return true }
        if node.children != nil {
            let stale = node.url.isFileURL && node.watcher == nil
            observe(node)
            if stale { load(node, expand: false) }
            return true
        }
        guard !node.loading else { return false }
        load(node, expand: true)
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? FolderNode)?.stopObserving()
        return true
    }

    private func observe(_ node: FolderNode) {
        guard node.url.isFileURL else { return }
        guard node.watcher == nil else { return }
        let watcher = DirectoryWatcher()
        node.watcher = watcher
        watcher.watch(node.url) { [weak self, weak node] in
            guard let self, let node, self.outline.isItemExpanded(node) || node.loading, node.refreshTask == nil else { return }
            node.refreshTask = Task { [weak self, weak node] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let node else { return }
                node.refreshTask = nil
                guard self.outline.isItemExpanded(node) || node.loading else { return }
                self.load(node, expand: !self.outline.isItemExpanded(node))
            }
        }
    }

    private func expandedNodes(under nodes: [FolderNode]) -> [FolderNode] {
        nodes.flatMap { node in
            (outline.isItemExpanded(node) ? [node] : []) + expandedNodes(under: node.children ?? [])
        }
    }

    /// Refresh expanded nodes and invalidate collapsed caches without losing valid expansion identities.
    func refresh() {
        func refreshNode(_ node: FolderNode) {
            if node.isGroup { node.children?.forEach { refreshNode($0) }; return }
            if outline.isItemExpanded(node) {
                load(node, expand: false)
                node.children?.forEach { refreshNode($0) }
            } else {
                node.stopObserving()
                node.children = nil
            }
        }
        roots.forEach { refreshNode($0) }
    }

    private func load(_ node: FolderNode, expand: Bool) {
        // Watcher installation and rapid events may request another read while open() is
        // blocked. Keep one active read per node and reconcile once after it completes.
        guard !node.loading else { node.needsRefresh = true; return }
        node.task?.cancel()
        node.request += 1
        let nodeRequest = node.request
        node.loading = true
        observe(node)
        let request = generation, showHidden = hidden, url = node.url
        node.task = Task { [weak self, weak node] in
            do {
                let entries = try await ApplicationDirectoryReader(purpose: .background).entries(at: url, showHidden: showHidden)
                var mounts: [String: VolumeMount] = [:]
                if url.isFileURL && url.path == "/Volumes" {
                    mounts = await Task.detached(priority: .utility) {
                        var found: [String: VolumeMount] = [:]
                        for entry in entries where entry.canNavigate {
                            if let mount = try? VolumeMount.identify(at: entry.url) { found[entry.id] = mount }
                        }
                        return found
                    }.value
                }
                guard let self, let node, request == self.generation, nodeRequest == node.request else { return }
                let expanded = self.expandedNodes(under: [node])
                let selectedURL = (self.outline.item(atRow: self.outline.selectedRow) as? FolderNode)?.url
                let previous = Dictionary((node.children ?? []).map { ($0.url.explorerIdentity, $0) }, uniquingKeysWith: { first, _ in first })
                // Directory symlinks remain navigable in Details, but never recursively expand the tree.
                node.children = entries.filter { $0.canNavigate && (!$0.isSymbolicLink || mounts[$0.id] != nil) }
                    .map { entry in
                        let child = previous[entry.id] ?? FolderNode(url: entry.url)
                        child.volume = mounts[entry.id]
                        child.volumeLink = entry.isSymbolicLink
                        return child
                    }
                let remaining = Set(node.children?.map { $0.url.explorerIdentity } ?? [])
                for child in previous.values where !remaining.contains(child.url.explorerIdentity) { child.stopObserving() }
                node.loading = false
                node.failure = nil
                if expand || !expanded.isEmpty { self.observe(node) }
                self.selecting = true
                self.outline.reloadItem(node, reloadChildren: true)
                self.expandFromCode {
                    if expand { self.outline.expandItem(node) }
                    for item in expanded where item === node || self.outline.row(forItem: item) >= 0 {
                        self.outline.expandItem(item)
                        if item.watcher == nil && item.url.isFileURL {
                            self.observe(item)
                            self.load(item, expand: false)
                        }
                    }
                }
                self.selecting = false
                if let selectedURL { self.selectIfVisible(selectedURL) }
                if self.outline.isItemExpanded(node) { self.observe(node) }
                if node.needsRefresh {
                    node.needsRefresh = false
                    self.load(node, expand: false)
                }
                self.continueReveal()
            } catch {
                guard let self, let node, request == self.generation, nodeRequest == node.request else { return }
                node.loading = false
                node.needsRefresh = false
                node.failure = DirectoryFailure(path: url.explorerIdentity, error: error)
                self.outline.reloadItem(node)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("folder"), owner: self)
                    as? FileNameCell) ?? FileNameCell()
        cell.identifier = NSUserInterfaceItemIdentifier("folder")
        cell.label.stringValue = node.title
        cell.label.font = ExplorerStyle.font(.tree)
        let icon: ExplorerIcon
        switch node.symbol {
        case "magnifyingglass", "folder.badge.gearshape": icon = .search
        case "house": icon = .home
        case "desktopcomputer": icon = .desktop
        case "arrow.down.circle": icon = .downloads
        case "doc": icon = .document
        case "photo.fill": icon = .image
        case "music.note": icon = .audio
        case "film.fill": icon = .video
        case "iphone": icon = .iphone
        case "internaldrive": icon = .computer
        case "externaldrive": icon = .disk
        case "trash": icon = .trash
        case "cloud.s3": icon = .cloudOrange
        case "cloud.azure": icon = .cloudBlue
        case "cloud.gcs": icon = .cloudGreen
        case "cloud.fill": icon = .cloud
        default: icon = .folder
        }
        // Same icon size as the file list, so the two panes read as one.
        let side = FileTypeIcon.listIconSide
        cell.setIconSize(side)
        cell.icon.imageScaling = .scaleProportionallyUpOrDown
        cell.icon.imageAlignment = .alignCenter
        if node.failure == nil {
            cell.icon.image = PremiumIcons.image(icon, side: side, description: node.title)
            cell.icon.contentTintColor = nil
        } else {
            let warning = ExplorerStyle.symbol("exclamationmark.triangle.fill", description: node.title)
            cell.icon.image = warning?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side, weight: .regular)) ?? warning
            cell.icon.contentTintColor = .systemOrange
        }
        cell.shortcutBadge.isHidden = true
        GitDecoration.apply(to: cell, url: node.url, directory: true, snapshot: gitSnapshot, roots: gitRoots,
            baseTooltip: L10n.directoryError(node.failure) ?? CloudAccounts.shared.address(for: node.url))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let node = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
        if node === trashRoot {
            selecting = true; outline.deselectAll(nil); selecting = false
            onShowTrash?()
            return
        }
        if node === mobileRoot {
            selecting = true; outline.deselectAll(nil); selecting = false
            if mobileDevices == nil { mobileDevices = AppleMobileDevices() }
            mobileDevices?.showWindow(nil)
            return
        }
        if node === searchRoot { outline.expandItem(node); return }
        if let saved = node.savedSearch { onSavedSearch?(saved); return }
        if node.isGroup { onNavigate?(node.url); return }
        onNavigate?(node.url)
    }
}
