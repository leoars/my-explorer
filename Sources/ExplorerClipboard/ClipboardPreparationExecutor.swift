// SPDX-License-Identifier: Apache-2.0
import Foundation

/// File metadata/read calls may block in the kernel. They never occupy Swift's cooperative pool,
/// and a cancelled/timed-out caller does not release the occupied slot until the worker exits.
final class ClipboardPreparationExecutor: @unchecked Sendable {
    static let shared = ClipboardPreparationExecutor()
    private let queue: OperationQueue
    private let lock = NSLock()
    private let capacity: Int
    private var pending = 0
    var pendingCount: Int { lock.withLock { pending } }
    init(concurrency: Int = 2, capacity: Int = 8) {
        queue = OperationQueue(); queue.name = "MyExplorer.ClipboardPreparation"
        queue.qualityOfService = .userInitiated; queue.maxConcurrentOperationCount = max(1, concurrency)
        self.capacity = max(1, capacity)
    }
    func run(timeout: TimeInterval = 15, _ operation: @escaping @Sendable (ClipboardCancellation) -> [PreparedItem]) async -> [PreparedItem] {
        guard timeout > 0, timeout.isFinite else { return [] }
        let work = ClipboardPreparationWork()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.install(continuation)
                guard !work.control.isCancelled else { return }
                let admitted = lock.withLock { if pending >= capacity { return false }; pending += 1; return true }
                guard admitted else { work.finish([]); return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { work.cancel() }
                queue.addOperation { [self] in
                    defer { lock.withLock { pending -= 1 } }
                    guard !work.control.isCancelled else { work.finish([]); return }
                    let prepared = operation(work.control)
                    work.finish(work.control.isCancelled ? [] : prepared)
                }
            }
        } onCancel: { work.cancel() }
        return Task.isCancelled ? [] : result
    }
}

final class ClipboardCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private final class ClipboardPreparationWork: @unchecked Sendable {
    let control = ClipboardCancellation()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[PreparedItem], Never>?
    private var early: [PreparedItem]?
    private var finished = false
    func install(_ value: CheckedContinuation<[PreparedItem], Never>) {
        let ready = lock.withLock { () -> [PreparedItem]? in
            if finished { defer { early = nil }; return early }
            continuation = value; return nil
        }
        if let ready { value.resume(returning: ready) }
    }
    func finish(_ result: [PreparedItem]) {
        let waiting = lock.withLock { () -> CheckedContinuation<[PreparedItem], Never>? in
            guard !finished else { return nil }
            finished = true
            let waiting = continuation; continuation = nil
            if waiting == nil { early = result }
            return waiting
        }
        waiting?.resume(returning: result)
    }
    func cancel() { control.cancel(); finish([]) }
}
