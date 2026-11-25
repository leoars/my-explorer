// SPDX-License-Identifier: Apache-2.0
#if !APP_STORE
import AppKit
import ExplorerCore

private enum UpdateError: Error { case access, invalid }

private class UpdateRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https",
              let host = url.host, host.hasSuffix(".githubusercontent.com") else { completionHandler(nil); return }
        var stripped = URLRequest(url: url)
        stripped.httpMethod = "GET"
        completionHandler(stripped)
    }
}

// Use the same redirect policy for the download as for release metadata.
private final class DownloadProgressObserver: UpdateRedirects, @unchecked Sendable {
    private let received: @Sendable (Int64) -> Void
    private var observation: NSKeyValueObservation?

    init(received: @escaping @Sendable (Int64) -> Void) { self.received = received }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.completedUnitCount, options: [.new]) { [received] progress, _ in
            received(progress.completedUnitCount)
        }
    }
}

@MainActor
final class GitHubUpdater {
    private let preferences: UpdateCheckPreferences
    private let app: URL
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var staged: URL?
    private var progress: UpdateProgressController?
    private weak var prompt: NSAlert?
    var requestRestart: (() -> Void)?
    var changed: (() -> Void)?
    private(set) var status = "updates.idle" { didSet { changed?() } }
    var canChangePreference: Bool { status != "updates.installing" && status != "updates.reopening" }
    var canCheckNow: Bool { status != "updates.checking" && progress == nil }
    var enabled: Bool { preferences.enabled }

    init(defaults: UserDefaults = .standard, app: URL = Bundle.main.bundleURL) {
        preferences = UpdateCheckPreferences(defaults: defaults)
        self.app = app
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: UpdateRedirects(), delegateQueue: nil)
    }
    func start() {
        guard canCheckNow, enabled else { return }
        if preferences.isDeferred(at: Date()) { status = "updates.deferred"; return }
        check(manualWindow: nil)
    }

    func checkNow(from window: NSWindow) {
        guard canCheckNow else { return }
        check(manualWindow: window)
    }

    private func check(manualWindow: NSWindow?) {
        let minimumBuild = manualWindow == nil ? preferences.skippedBuild : 0
        status = "updates.checking"
        task = Task {
            do {
                try Task.checkCancellation()
                let candidate = try await newest(after: minimumBuild)
                try Task.checkCancellation()
                guard let candidate else { status = "updates.current"; return }
                guard let owner = manualWindow ?? DialogPlacement.explorerWindow, owner.isVisible else {
                    status = "updates.idle"
                    return
                }
                let alert = NSAlert()
                alert.messageText = L10n.format("updates.offer", Self.label(version: candidate.version, build: candidate.build))
                alert.informativeText = L10n.text("updates.explanation") + "\n\n"
                    + L10n.format("updates.installed", Self.label(version: Self.installedVersion(app), build: try UpdateInstaller.build(app)))
                alert.addButton(withTitle: L10n.text("updates.install"))
                if manualWindow != nil {
                    alert.addButton(withTitle: L10n.text("dialog.cancel")).keyEquivalent = "\u{1b}"
                } else {
                    alert.addButton(withTitle: L10n.text("updates.later")).keyEquivalent = "\u{1b}"
                    alert.addButton(withTitle: L10n.text("updates.skip"))
                }
                prompt = alert
                let response = await alert.beginSheetModal(for: owner)
                try Task.checkCancellation()
                prompt = nil
                switch response {
                case .alertSecondButtonReturn where manualWindow == nil:
                    preferences.remindLater(from: Date())
                    status = "updates.deferred"
                case .alertThirdButtonReturn where manualWindow == nil:
                    preferences.skip(build: candidate.build)
                    status = "updates.skipped"
                case .alertFirstButtonReturn:
                    let panel = UpdateProgressController(version: Self.label(version: candidate.version, build: candidate.build), totalBytes: candidate.asset.size)
                    progress = panel
                    status = "updates.downloading"
                    panel.showWindow(nil)
                    let result = try await download(candidate, panel: panel)
                    if Task.isCancelled {
                        try? FileManager.default.removeItem(at: result.deletingLastPathComponent())
                        return
                    }
                    staged = result
                    if FileCommands.shared.isBusy { showPhase("updates.waiting") }
                    while let operation = FileCommands.shared.task {
                        await operation.value
                        try Task.checkCancellation()
                    }
                    showPhase("updates.installing")
                    requestRestart?()
                default: status = "updates.idle"
                }
            } catch {
                guard !Task.isCancelled else { return }
                let wasUpdating = progress != nil
                dismissProgress()
                status = (error as? UpdateError) == .access ? "updates.access" : "updates.failed"
                if wasUpdating { reportFailure() }
            }
        }
    }

    func setEnabled(_ value: Bool) {
        guard canChangePreference else { return }
        cancel()
        preferences.enabled = value
        start()
    }

    func cancel() {
        dismissProgress()
        task?.cancel()
        if let window = prompt?.window { window.sheetParent?.endSheet(window, returnCode: .cancel) }
        prompt = nil
        if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        staged = nil
        status = "updates.idle"
    }

    private func dismissProgress() {
        progress?.close()
        progress = nil
    }

    private func showPhase(_ key: String) {
        progress?.showPhase(key)
        status = key
    }

    private let api = "https://api.github.com/repos/leoars/my-explorer/releases"

    private func request(_ url: URL, asset: Bool = false) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(asset ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        return req
    }

    private func validate(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode
        if [401, 403, 404].contains(code) { throw UpdateError.access }
        guard code == 200 else { throw UpdateError.invalid }
    }

    private typealias Candidate = (build: Int, asset: GitHubUpdateRelease.Asset, version: String?)

    /// "1.0.2 (build 66)": the version people know, with the build the updater compares. A release
    /// whose tag is not a version shows the build alone.
    static func label(version: String?, build: Int) -> String {
        guard let version else { return String(build) }
        return L10n.format("updates.version_build", version, String(build))
    }

    static func installedVersion(_ app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private func newest(after minimumBuild: Int) async throws -> Candidate? {
        let current = max(try UpdateInstaller.build(app), minimumBuild)
        var best: Candidate?
        var page = 1
        while true {
            let url = URL(string: api + "?per_page=100&page=\(page)")!
            let (data, response) = try await session.data(for: request(url))
            try validate(response)
            let releases = try JSONDecoder().decode([GitHubUpdateRelease].self, from: data)
            if let candidate = GitHubUpdateRelease.newest(in: releases, after: best?.build ?? current) { best = candidate }
            if releases.count < 100 { break }
            page += 1
        }
        return best
    }

    private func download(_ best: Candidate, panel: UpdateProgressController) async throws -> URL {
        let observer = DownloadProgressObserver { [weak panel] bytes in
            Task { @MainActor in panel?.received(bytes) }
        }
        let (file, response) = try await session.download(for: request(URL(string: api + "/assets/\(best.asset.id)")!, asset: true), delegate: observer)
        defer { try? FileManager.default.removeItem(at: file) }
        try validate(response)
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == best.asset.size else { throw UpdateError.invalid }
        try Task.checkCancellation()
        showPhase("updates.verifying")
        let app = self.app
        return try await Task.detached {
            let image = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
            try FileManager.default.moveItem(at: file, to: image)
            defer { try? FileManager.default.removeItem(at: image) }
            return try UpdateInstaller.stage(image: image, number: best.build, current: app)
        }.value
    }
    func installForRestart() async throws {
        guard let staged else { throw UpdateError.invalid }
        let app = self.app
        try await Task.detached { try UpdateInstaller.install(staged, over: app) }.value
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        self.staged = nil
        showPhase("updates.reopening")
    }

    func reportFailure() {
        status = "updates.failed"
        guard let window = DialogPlacement.explorerWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("updates.failed")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
#endif
