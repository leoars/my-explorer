// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

/// Listens to the progress the system publishes for one file while iCloud downloads it. Foundation
/// calls back on its own queues, so this lives off the main actor and only forwards the fraction.
private final class ProgressRelay: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var subscriber: Any?
    /// One observation per published progress: the system may publish more than one for a file,
    /// and withdrawing one must not silence the others.
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private let report: @Sendable (Double) -> Void

    init(url: URL, report: @escaping @Sendable (Double) -> Void) {
        self.report = report
        super.init()
        let token = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
            // Uploads of the same file publish progress too; only a download fills this icon.
            guard let self, progress.fileOperationKind == nil || progress.fileOperationKind == .downloading else { return nil }
            let id = ObjectIdentifier(progress)
            let observation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [report = self.report] progress, _ in
                report(progress.fractionCompleted)
            }
            self.lock.withLock { self.observations[id] = observation }
            return { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.observations[id] = nil }
            }
        }
        lock.withLock { subscriber = token }
    }

    func stop() {
        let token: Any? = lock.withLock {
            observations.removeAll()
            defer { subscriber = nil }
            return subscriber
        }
        if let token { Progress.removeSubscriber(token) }
    }

    deinit { stop() }
}

/// The iCloud downloads this window asked for, with the progress of each, so the status column can
/// answer a click at once and keep showing how far a large file has come.
@MainActor
final class ICloudDownloadMonitor {
    enum Status: Equatable {
        /// Asked for; iCloud has not reported any progress yet.
        case waiting
        case fraction(Double)
    }

    private struct Item {
        let url: URL
        let size: Int64
        let relay: ProgressRelay
        var fraction: Double?
        var idleSeconds = 0
    }

    private var items: [String: Item] = [:]
    private var poll: Task<Void, Never>?
    /// The progress of this item changed, or it stopped being followed.
    var onProgress: ((URL) -> Void)?
    /// The download ended: true when the content is on this Mac.
    var onFinish: ((URL, Bool) -> Void)?
    /// Seconds without any sign of the download before it is given up as failed.
    static let idleLimit = 60

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The bytes still expected on this Mac from every download being followed, whoever asked
    /// for it. Counted in full until each one ends, which errs on the side of caution.
    var pendingBytes: Int64 { items.values.reduce(0) { $0 + $1.size } }

    func status(for url: URL) -> Status? {
        items[Self.key(url)].map { $0.fraction.map(Status.fraction) ?? .waiting }
    }

    /// Starts following an item. False when it was already followed, so a second request for the
    /// same item neither restarts nor, if it fails, ends the first one.
    @discardableResult
    func begin(_ url: URL, size: Int64 = 0) -> Bool {
        let key = Self.key(url)
        guard items[key] == nil else { return false }
        let relay = ProgressRelay(url: url) { [weak self] fraction in
            Task { @MainActor in self?.update(key, fraction: fraction) }
        }
        items[key] = Item(url: url, size: max(0, size), relay: relay)
        onProgress?(url)
        startPolling()
        return true
    }

    /// Stops following an item without reporting an outcome, as when the request itself failed.
    func cancel(_ url: URL) {
        guard let item = items.removeValue(forKey: Self.key(url)) else { return }
        item.relay.stop()
        onProgress?(item.url)
    }

    private func update(_ key: String, fraction: Double) {
        guard var item = items[key], fraction.isFinite else { return }
        // Reports hop to the main actor one by one and may arrive out of order: never step back,
        // and redraw only for a visible change.
        let value = max(item.fraction ?? 0, min(1, max(0, fraction)))
        item.idleSeconds = 0
        let visible = item.fraction.map { value - $0 >= 0.01 || (value == 1 && $0 < 1) } ?? true
        if visible { item.fraction = value }
        items[key] = item
        if visible { onProgress?(item.url) }
    }

    private func finish(_ key: String, downloaded: Bool) {
        guard let item = items.removeValue(forKey: key) else { return }
        item.relay.stop()
        onFinish?(item.url, downloaded)
    }

    /// The published progress may never come (it depends on the provider), so the state of each
    /// item is also read once a second: that is what ends the wait.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                await self.check()
                if self.items.isEmpty { self.poll = nil; return }
            }
        }
    }

    private func check() async {
        for (key, item) in Array(items) {
            let url = item.url
            let (downloaded, state) = await Task.detached {
                (ICloudAvailability.isDownloaded(at: url), ICloudAvailability.current(at: url))
            }.value
            guard var current = items[key] else { continue }
            if downloaded == true { finish(key, downloaded: true); continue }
            if downloaded == nil || state == .failed { finish(key, downloaded: false); continue }
            // Queued behind other downloads, or waiting for the network, is still on its way:
            // iCloud finishes it when it can. Only an item nothing is happening to is given up.
            current.idleSeconds = state == .downloading || state == .waiting ? 0 : current.idleSeconds + 1
            if current.idleSeconds >= Self.idleLimit { finish(key, downloaded: false) } else { items[key] = current }
        }
    }
}
