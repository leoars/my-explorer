// SPDX-License-Identifier: Apache-2.0
import Foundation
import Vision

/// Independent blocking workers. Cancellation releases the caller, never an occupied worker slot.
internal final class OCRExecutor: @unchecked Sendable {
    static let shared = OCRExecutor()
    internal let queue: OperationQueue
    internal let lock = NSLock()
    internal let capacity: Int
    internal var pending = 0
    init(concurrency: Int = 2, capacity: Int = 8) {
        queue = OperationQueue(); queue.name = "MyExplorer.OCR"
        queue.qualityOfService = .userInitiated; queue.maxConcurrentOperationCount = max(1, concurrency)
        self.capacity = max(1, capacity)
    }
    func run<T: Sendable>(timeout: TimeInterval, _ operation: @escaping @Sendable (OCRCancellation) throws -> T) async throws -> T {
        guard timeout > 0 else { throw OCRFailure(.timedOut) }
        let state = OCRWork<T>()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard !state.control.isCancelled else { return }
                let admitted = lock.withLock { if pending >= capacity { return false }; pending += 1; return true }
                guard admitted else { state.finish(.failure(OCRFailure(.busy))); return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { state.cancel(.timedOut) }
                queue.addOperation { [self] in
                    defer { lock.withLock { pending -= 1 } }
                    do {
                        try state.control.check()
                        let value = try operation(state.control)
                        try state.control.check()
                        state.finish(.success(value))
                    } catch { state.finish(.failure(error)) }
                }
            }
        } onCancel: { state.cancel(.cancelled) }
        if Task.isCancelled { throw OCRFailure(.cancelled) }
        return result
    }
}
internal final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws { if isCancelled { throw OCRFailure(.cancelled) } }
    func setRequest(_ value: VNRequest?) {
        let prior = lock.withLock { () -> (VNRequest?, Bool) in
            let old = request; request = value; return (old, cancelled)
        }
        withExtendedLifetime(prior.0) { }
        if prior.1 { value?.cancel() }
    }
    func cancel() {
        let active = lock.withLock { cancelled = true; return request }
        // Vision cancellation must never delay the caller's continuation completion.
        if let active {
            let cancellation = OCRVisionCancellation(active)
            DispatchQueue.global(qos: .utility).async { cancellation.cancel() }
        }
    }
}
private final class OCRWork<T: Sendable>: @unchecked Sendable {
    let control = OCRCancellation()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var early: Result<T, any Error>?
    private var finished = false
    func install(_ value: CheckedContinuation<T, any Error>) {
        let ready = lock.withLock { () -> Result<T, any Error>? in
            if finished { defer { early = nil }; return early }
            continuation = value; return nil
        }
        if let ready { value.resume(with: ready) }
    }
    func finish(_ result: Result<T, any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<T, any Error>? in
            guard !finished else { return nil }
            finished = true; let waiting = continuation; continuation = nil
            if waiting == nil { early = result }
            return waiting
        }
        waiting?.resume(with: result)
    }
    func cancel(_ reason: OCRFailure.Reason) {
        let didCancel = lock.withLock { () -> (Bool, CheckedContinuation<T, any Error>?) in
            guard !finished else { return (false, nil) }
            finished = true; let waiting = continuation; continuation = nil
            if waiting == nil { early = .failure(OCRFailure(reason)) }
            return (true, waiting)
        }
        guard didCancel.0 else { return }
        didCancel.1?.resume(throwing: OCRFailure(reason))
        control.cancel()
    }
}

/// VNRequest.cancel() is the cross-thread cancellation API; no request configuration/results
/// are exposed through this wrapper while the recognition worker owns those operations.
private final class OCRVisionCancellation: @unchecked Sendable {
    private let request: VNRequest
    init(_ request: VNRequest) { self.request = request }
    func cancel() { request.cancel() }
}
