// SPDX-License-Identifier: Apache-2.0
import Foundation
import AVFoundation

/// Owns every AV resource until the UI has detached it. AVFoundation cancellation and
/// final release can wait on filesystem I/O, so neither is allowed on the main actor.
/// At most three sessions (including unfinished retirements) exist at once.
final class MediaPlaybackSession: @unchecked Sendable {
    enum Outcome: Sendable, Equatable { case ready, unavailable, timedOut, cancelled }
    typealias Loader = @Sendable (AVURLAsset) async throws -> Bool
    typealias Completion = @Sendable (MediaPlaybackSession, Outcome) -> Void

    private static let registry = MediaPlaybackRegistry()
    static var activeSessionCount: Int { registry.count }
    static let maximumSessionCount = 3

    private let id = UUID()
    private let queue = DispatchQueue(label: "io.github.leoars.myexplorer.media-session", qos: .userInitiated)
    private let lock = NSLock()
    private var outcome: Outcome?
    private var retirementRequested = false
    private var retirementFinished = false
    private var completion: Completion?
    // Resources below are created, mutated and destroyed on `queue`. The only exception
    // is a MainActor borrow of the player after .ready and before retireAfterDetachingUI().
    private var asset: AVURLAsset?
    private var item: AVPlayerItem?
    private var ownedPlayer: AVPlayer?
    private var loadingTask: Task<Void, Never>?
    private var loadingFinished = false
    private var cancellationSent = false
    private var timeoutWork: DispatchWorkItem?
    private let beforeRelease: (@Sendable () -> Void)?

    private init(completion: @escaping Completion, beforeRelease: (@Sendable () -> Void)?) {
        self.completion = completion
        self.beforeRelease = beforeRelease
    }

    /// Returns nil immediately when all bounded slots are occupied. Tests can inject a
    /// delayed loader/release barrier without touching personal files or blocking the UI.
    static func start(url: URL, timeout: TimeInterval = 15,
                      loader: @escaping Loader = { try await $0.load(.isPlayable) },
                      beforeRelease: (@Sendable () -> Void)? = nil,
                      completion: @escaping Completion) -> MediaPlaybackSession? {
        let session = MediaPlaybackSession(completion: completion, beforeRelease: beforeRelease)
        guard registry.insert(session, id: session.id, maximum: maximumSessionCount) else { return nil }
        let timer = DispatchWorkItem { [weak session] in session?.expirePreparation() }
        session.timeoutWork = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
        session.queue.async { session.begin(url: url, loader: loader) }
        return session
    }

    var hasFinishedRetirement: Bool { lock.withLock { retirementFinished } }

    /// The caller must hold this session until all UI references to the returned player
    /// are gone. A timeout applies only during preparation, never to an attached player.
    @MainActor func playerForAttachment() -> AVPlayer? {
        lock.withLock {
            guard outcome == .ready, !retirementRequested else { return nil }
            return ownedPlayer
        }
    }

    /// Call only after playerView.player, controller.player and KVO references are cleared.
    /// This schedules work only: Task cancellation must never run AV cancellation inline.
    @MainActor func retireAfterDetachingUI() {
        requestRetirement(result: .cancelled)
    }

    private func begin(url: URL, loader: @escaping Loader) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !lock.withLock({ retirementRequested }) else {
            loadingFinished = true
            finishRetirementIfPossible()
            return
        }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        self.asset = asset
        loadingTask = Task.detached(priority: .userInitiated) { [self] in
            let playable = await loadOffMain(loader: loader)
            queue.async { [self] in finishLoading(playable: playable) }
        }
    }

    private func loadOffMain(loader: @escaping Loader) async -> Bool {
        // This async scope must unwind its asset reference before notifying the owner queue.
        // A blocked final release therefore still occupies its bounded registry slot.
        guard let asset else { return false }
        do { return try await loader(asset) } catch { return false }
    }

    private func finishLoading(playable: Bool) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        loadingFinished = true
        loadingTask = nil
        guard !lock.withLock({ retirementRequested }) else { finishRetirementIfPossible(); return }
        guard playable, let asset else { requestRetirement(result: .unavailable); return }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.pause()
        self.item = item
        // Publish the player under the same lock used by the MainActor borrow.
        lock.withLock { ownedPlayer = player }
        let callback = lock.withLock { () -> Completion? in
            guard !retirementRequested, outcome == nil else { return nil }
            outcome = .ready
            let callback = completion
            completion = nil
            return callback
        }
        timeoutWork?.cancel()
        timeoutWork = nil
        callback?(self, .ready)
        if lock.withLock({ retirementRequested }) {
            // Let the strong asset/item/player locals above unwind before final release
            // can release the registry slot. The owner retains them until this block.
            queue.async { [self] in finishRetirementIfPossible() }
        }
    }

    private func expirePreparation() {
        // Only a preparing session can time out; an attached/ready player stays owned.
        requestRetirement(result: .timedOut, onlyIfPreparing: true)
    }

    private func requestRetirement(result: Outcome, onlyIfPreparing: Bool = false) {
        let callback = lock.withLock { () -> Completion? in
            guard !retirementRequested, (!onlyIfPreparing || outcome == nil) else { return nil }
            retirementRequested = true
            guard outcome == nil else { return nil }
            outcome = result
            let callback = completion
            completion = nil
            return callback
        }
        callback?(self, result)
        queue.async { [self] in
            guard lock.withLock({ retirementRequested }) else { return }
            finishRetirementIfPossible()
        }
    }

    private func finishRetirementIfPossible() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard lock.withLock({ retirementRequested && !retirementFinished }) else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        if !cancellationSent {
            cancellationSent = true
            loadingTask?.cancel()
            ownedPlayer?.pause()
            ownedPlayer?.replaceCurrentItem(with: nil)
            // May wait on slow filesystem/framework work. This is the session's own queue.
            asset?.cancelLoading()
        }
        guard loadingFinished else { return }
        beforeRelease?()
        autoreleasepool {
            let retiringPlayer = lock.withLock { () -> AVPlayer? in
                // Keep a strong local before clearing the slot: the lock must never
                // encompass the potentially blocking final release of an AV object.
                let player = ownedPlayer
                ownedPlayer = nil
                return player
            }
            retiringPlayer?.pause()
            retiringPlayer?.replaceCurrentItem(with: nil)
            withExtendedLifetime(retiringPlayer) {
                item = nil
                asset = nil
            }
        }
        lock.withLock { retirementFinished = true }
        Self.registry.remove(id)
    }
}

private final class MediaPlaybackRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: MediaPlaybackSession] = [:]
    var count: Int { lock.withLock { sessions.count } }
    func insert(_ session: MediaPlaybackSession, id: UUID, maximum: Int) -> Bool {
        lock.withLock {
            guard sessions.count < maximum else { return false }
            sessions[id] = session
            return true
        }
    }
    func remove(_ id: UUID) { _ = lock.withLock { sessions.removeValue(forKey: id) } }
}
