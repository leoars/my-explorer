// SPDX-License-Identifier: Apache-2.0
import Foundation

extension OCRExecutor {
    /// Unlike cancellable preparation, a committed publication must return its receipt.
    func publish<T: Sendable>(timeout: TimeInterval,
        _ operation: @escaping @Sendable (OCRCancellation, @Sendable () throws -> Void) throws -> T) async throws -> T {
        guard timeout > 0 else { throw SearchablePDFFailure(.timedOut) }
        let state = PDFPublicationWork<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard !state.control.isCancelled else { return }
                let admitted = lock.withLock { if pending >= capacity { return false }; pending += 1; return true }
                guard admitted else { state.finish(.failure(SearchablePDFFailure(.busy))); return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { state.cancel(timeout: true) }
                queue.addOperation { [self] in
                    defer { lock.withLock { pending -= 1 } }
                    do {
                        try state.control.check()
                        let result = try operation(state.control) { try state.beginCommit() }
                        state.finish(.success(result))
                    } catch { state.finish(.failure(SearchablePDFFailure(error))) }
                }
            }
        } onCancel: { state.cancel(timeout: false) }
    }
}
private final class PDFPublicationWork<T: Sendable>: @unchecked Sendable {
    let control = OCRCancellation()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var early: Result<T, any Error>?
    private var finished = false
    private var committing = false
    func install(_ value: CheckedContinuation<T, any Error>) {
        let result = lock.withLock { () -> Result<T, any Error>? in
            if finished { defer { early = nil }; return early }; continuation = value; return nil
        }
        if let result { value.resume(with: result) }
    }
    func beginCommit() throws {
        try lock.withLock {
            guard !finished else { throw SearchablePDFFailure(.cancelled) }
            committing = true
        }
    }
    func finish(_ value: Result<T, any Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<T, any Error>? in
            guard !finished else { return nil }; finished = true
            let waiter = continuation; continuation = nil
            if waiter == nil { early = value }; return waiter
        }
        waiter?.resume(with: value)
    }
    func cancel(timeout: Bool) {
        let outcome = lock.withLock { () -> (CheckedContinuation<T, any Error>?, SearchablePDFFailure)? in
            guard !finished, timeout || !committing else { return nil }
            let error = SearchablePDFFailure(committing ? .publicationIndeterminate : (timeout ? .timedOut : .cancelled))
            finished = true; let waiter = continuation; continuation = nil
            if waiter == nil { early = .failure(error) }; return (waiter, error)
        }
        guard let outcome else { return }; outcome.0?.resume(throwing: outcome.1); control.cancel()
    }
}
