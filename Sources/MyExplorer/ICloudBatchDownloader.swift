// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerCore

/// Downloads a list of iCloud items in order, a few at a time, and stops before the disk's
/// reserve would be touched. The space is read again before every item: other programs use the
/// disk too, and the sizes known beforehand are only what iCloud announced.
@MainActor
final class ICloudBatchDownloader {
    struct Progress: Equatable {
        var done = 0, total = 0, failed = 0
        var doneBytes: Int64 = 0, totalBytes: Int64 = 0
    }
    enum End: Equatable {
        case finished(failed: Int)
        case stopped
        /// Stopped to keep the reserve: how many items were left, and the space at that moment.
        case outOfSpace(remaining: Int, volume: ICloudBatch.Volume)
        /// The free space could not be read, so nothing more was asked for.
        case spaceUnknown(remaining: Int)
    }

    static let simultaneous = 3
    private let monitor: ICloudDownloadMonitor
    private let volume: @Sendable (URL) -> ICloudBatch.Volume?
    private var queue: [ICloudBatchItem] = []
    private var inFlight: [String: ICloudBatchItem] = [:]
    private var starting = false
    private var run = 0
    private(set) var isRunning = false
    private(set) var progress = Progress()
    /// The folder the batch was started from: the one worth reading again as it advances.
    private(set) var folder: URL?
    var onProgress: (() -> Void)?
    var onEnd: ((End) -> Void)?

    init(monitor: ICloudDownloadMonitor, volume: @escaping @Sendable (URL) -> ICloudBatch.Volume? = { ICloudBatch.volume(at: $0) }) {
        self.monitor = monitor
        self.volume = volume
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func start(_ items: [ICloudBatchItem], folder: URL) {
        guard !isRunning, !items.isEmpty else { return }
        run += 1
        queue = items
        inFlight = [:]
        starting = false
        self.folder = folder
        progress = Progress(total: items.count, totalBytes: ICloudBatch.totalSize(items))
        isRunning = true
        onProgress?()
        pump()
    }

    /// Stops asking for more. What is already downloading goes on to its end in iCloud, and the
    /// download monitor keeps counting its bytes against the disk.
    func stop() {
        guard isRunning else { return }
        end(.stopped)
    }

    /// The window's download monitor reports every item it stops following. True when the item
    /// belonged to this batch, which then counts it; false leaves it to whoever asked for it.
    @discardableResult
    func itemFinished(_ url: URL, downloaded: Bool) -> Bool {
        guard isRunning, let item = inFlight.removeValue(forKey: Self.key(url)) else { return false }
        count(item, downloaded: downloaded)
        pump()
        return true
    }

    private func count(_ item: ICloudBatchItem, downloaded: Bool) {
        progress.done += 1
        if downloaded { progress.doneBytes += max(0, item.size) } else { progress.failed += 1 }
        onProgress?()
    }

    private func end(_ result: End) {
        isRunning = false
        run += 1
        queue = []
        inFlight = [:]
        starting = false
        onProgress?()
        onEnd?(result)
    }

    /// Starts the next item when there is a free place, one start at a time so each one is
    /// checked against the space the others are still going to take.
    private func pump() {
        guard isRunning, !starting else { return }
        guard !queue.isEmpty else {
            if inFlight.isEmpty { end(.finished(failed: progress.failed)) }
            return
        }
        guard inFlight.count < Self.simultaneous else { return }
        let listed = queue.removeFirst()
        let current = run, url = listed.url, readVolume = volume
        // A download that ends while the disk is being read has left the monitor, but the disk
        // figure may predate its last bytes: the larger of the two counts is used.
        let pendingBefore = monitor.pendingBytes
        starting = true
        Task { [weak self] in
            let (space, downloaded, size) = await Task.detached {
                (readVolume(url.deletingLastPathComponent()), ICloudAvailability.isDownloaded(at: url), ICloudBatch.currentSize(of: url))
            }.value
            guard let self, self.isRunning, self.run == current else { return }
            self.starting = false
            // Brought down meanwhile by other means, or no longer an iCloud item: nothing to ask.
            if downloaded != false {
                self.count(listed, downloaded: downloaded == true)
                self.pump()
                return
            }
            // An item whose size cannot be read cannot be weighed against the disk.
            guard let size else {
                self.count(listed, downloaded: false)
                self.pump()
                return
            }
            let item = ICloudBatchItem(url: url, size: max(listed.size, size))
            guard let space else {
                self.queue.insert(listed, at: 0)
                self.end(.spaceUnknown(remaining: self.queue.count))
                return
            }
            // Everything on its way, from this batch or not, is counted in full until it ends.
            let pending = max(pendingBefore, self.monitor.pendingBytes)
            guard space.fits(pending + item.size) else {
                self.queue.insert(listed, at: 0)
                // With downloads still arriving the count above may be too cautious: wait for
                // them and look again. With none, the disk really is at the reserve.
                if self.inFlight.isEmpty { self.end(.outOfSpace(remaining: self.queue.count, volume: space)) }
                return
            }
            self.inFlight[Self.key(url)] = item
            let began = self.monitor.begin(url, size: item.size)
            do { try await Task.detached { try ICloudAvailability.request(.download, at: url) }.value }
            catch {
                if began { self.monitor.cancel(url) }
                guard self.isRunning, self.run == current else { return }
                if let failed = self.inFlight.removeValue(forKey: Self.key(url)) { self.count(failed, downloaded: false) }
            }
            guard self.isRunning, self.run == current else { return }
            self.pump()
        }
    }
}
