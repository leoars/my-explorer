// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import NetFS

@MainActor
final class SystemVolumeController: NSObject {
    private weak var browser: ExplorerWindowController?
    private var mountRequest: AsyncRequestID?
    private var ejecting = Set<String>()
    private var disconnected: [UUID: String] = [:]
    private let center = NSWorkspace.shared.notificationCenter
    private let recentKey = "network.recentServers"

    init(browser: ExplorerWindowController) { self.browser = browser }

    func start() {
        center.addObserver(self, selector: #selector(unmounted(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        center.addObserver(self, selector: #selector(mounted(_:)), name: NSWorkspace.didMountNotification, object: nil)
    }

    func stop() {
        center.removeObserver(self)
        if let mountRequest { NetFSMountURLCancel(mountRequest); self.mountRequest = nil }
    }

    func notice(for id: UUID) -> String? {
        disconnected[id].map { L10n.format("volume.removed", $0) }
    }
    func clearNotice(for id: UUID) { disconnected.removeValue(forKey: id) }

    @objc private func mounted(_ note: Notification) { browser?.tree.refresh() }

    @objc private func unmounted(_ note: Notification) {
        guard let root = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL, let browser else { return }
        browser.tree.refresh()
        for tab in browser.workspace.tabs {
            let url = tab.session.history.current.url
            guard url.isFileURL, url.path == root.path || url.path.hasPrefix(root.path + "/") else { continue }
            disconnected[tab.id] = root.lastPathComponent
            tab.prepareForUserNavigation()
            tab.session.navigate(.visit(URL(fileURLWithPath: "/Volumes", isDirectory: true)))
        }
    }

    func remove(_ mount: VolumeMount) {
        guard let browser, let removal = mount.removal else { return }
        if FileCommands.shared.isBusy {
            inform(L10n.text("volume.busy"))
            return
        }
        guard ejecting.insert(mount.url.path).inserted else { return }
        Task {
            defer { ejecting.remove(mount.url.path) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard try VolumeMount.identify(at: mount.url) == mount else { throw CocoaError(.fileReadNoSuchFile) }
                    try NSWorkspace.shared.unmountAndEjectDevice(at: mount.url)
                }.value
                browser.tree.refresh()
                inform(L10n.format(removal == .disconnect ? "volume.disconnected" : "volume.ejected", mount.url.lastPathComponent))
            } catch { inform(error.localizedDescription) }
        }
    }

    func promptForServer() {
        guard let window = browser?.window else { return }
        if mountRequest != nil { inform(L10n.text("server.connecting")); return }
        let alert = NSAlert()
        alert.messageText = L10n.text("server.connect")
        alert.informativeText = L10n.text("server.address")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        field.placeholderString = "smb://server/share"
        field.setAccessibilityLabel(alert.informativeText)
        field.addItems(withObjectValues: recentServers)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("server.connect"))
        alert.addButton(withTitle: L10n.text("dialog.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.connect(field.stringValue) }
        }
    }

    private var recentServers: [String] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).compactMap { SMBAddress.parse($0)?.absoluteString }
    }

    func connect(_ text: String) {
        guard let url = SMBAddress.parse(text) else { inform(L10n.text("server.address")); return }
        guard mountRequest == nil else { inform(L10n.text("server.connecting")); return }
        let options = NSMutableDictionary(dictionary: [kNAUIOptionKey as String: kNAUIOptionAllowUI])
        let result = NetFSMountURLAsync(url as CFURL, nil, nil, nil, options, nil, &mountRequest, .main) {
            [weak self] status, request, paths in
            MainActor.assumeIsolated {
                guard let self, self.mountRequest == request else { return }
                self.mountRequest = nil
                if status == -128 || status == ECANCELED { return }
                var mounts = (paths as? [String] ?? []).filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
                if status == EEXIST && mounts.isEmpty, let existing = Self.existingShare(url) { mounts = [existing] }
                guard !mounts.isEmpty, status == 0 || status == EEXIST else {
                    self.reportConnectionError(status)
                    return
                }
                let recent = [url.absoluteString] + self.recentServers.filter { $0 != url.absoluteString }
                UserDefaults.standard.set(Array(recent.prefix(10)), forKey: self.recentKey)
                self.browser?.tree.refresh()
                for mount in mounts { self.browser?.addTab(at: mount) }
            }
        }
        if result != 0 { mountRequest = nil; reportConnectionError(result) }
    }

    private static func existingShare(_ server: URL) -> URL? {
        let key: URLResourceKey = .volumeURLForRemountingKey
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [key])?.first { mount in
            guard let remote = try? mount.resourceValues(forKeys: [key]).volumeURLForRemounting,
                  var parts = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return false }
            parts.user = nil; parts.password = nil
            return parts.url.flatMap { SMBAddress.parse($0.absoluteString) } == server
        }
    }

    private func reportConnectionError(_ status: Int32) {
        let error = NSError(domain: status > 0 ? NSPOSIXErrorDomain : NSOSStatusErrorDomain, code: Int(status))
        inform(L10n.format("server.failed", error.localizedDescription))
    }

    private func inform(_ text: String) {
        guard let window = browser?.window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
