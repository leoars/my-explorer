// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A thread-safe control for the synchronous native copy worker; pausing never blocks the UI actor.
public final class LocalTransferControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    public init() {}
    public var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }; return paused
    }
    public func pause() { condition.lock(); paused = true; condition.unlock() }
    public func resume() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    public func cancel() { condition.lock(); cancelled = true; paused = false; condition.broadcast(); condition.unlock() }
    func checkpoint() throws {
        condition.lock(); defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        if cancelled || Task.isCancelled { throw LocalTransferFailure(.cancelled) }
    }
}

public enum LocalTransferKind: Sendable { case copy, move, trash }
public struct LocalTransferFailure: Error, Sendable {
    public enum Reason: String, Sendable {
        case invalidSource, invalidDestination, recursive, unsupportedEntry, changed, copyVerificationFailed, conflict
        case cancelled, io, undoUnavailable, trashUnavailable, busy, limitExceeded, recoveryRequired
    }
    public let reason: Reason
    public let completed: [URL]
    public let recoveryLocations: [URL]
    public init(_ reason: Reason, completed: [URL] = [], recoveryLocations: [URL] = []) {
        self.reason = reason; self.completed = completed; self.recoveryLocations = recoveryLocations
    }
}
