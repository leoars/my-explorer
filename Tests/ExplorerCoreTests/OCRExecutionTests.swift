// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

@MainActor
final class OCRExecutionTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
    func testBlockedWorkersStayBoundedWhileCancellationAndHeartbeatComplete() async throws {
        let executor = OCRExecutor(concurrency: 2, capacity: 2), probe = OCRWorkerProbe(), release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        var returned = 0
        let tasks = (0..<2).map { _ in Task {
            do {
                _ = try await executor.run(timeout: 10) { control in
                    probe.enter(); _ = release.wait(timeout: .now() + 5); probe.exit(); try control.check(); return true
                }
                XCTFail("Expected cancellation")
            } catch let error as OCRFailure { XCTAssertEqual(error.reason, .cancelled); returned += 1 }
        } }
        try await wait { probe.starts == 2 }
        XCTAssertFalse(probe.swiftTask)
        XCTAssertFalse(probe.mainThread)
        let heartbeat = await Task.detached { 42 }.value
        XCTAssertEqual(heartbeat, 42)
        tasks.forEach { $0.cancel() }
        try await wait { returned == 2 }
        XCTAssertEqual(probe.ends, 0)
        do { _ = try await executor.run(timeout: 1) { _ in true }; XCTFail("Blocked workers must retain their slots") }
        catch let error as OCRFailure { XCTAssertEqual(error.reason, .busy) }
        release.signal(); release.signal()
        try await wait { probe.ends == 2 }
        for task in tasks { _ = try await task.value }
    }
    func testTimeoutDoesNotReuseBlockedSlotAndLateResultCannotCompleteTwice() async throws {
        let executor = OCRExecutor(concurrency: 1, capacity: 1), probe = OCRWorkerProbe(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let start = Date()
        do {
            _ = try await executor.run(timeout: 0.05) { _ in probe.enter(); _ = release.wait(timeout: .now() + 5); probe.exit(); return true }
            XCTFail("Expected timeout")
        } catch let error as OCRFailure { XCTAssertEqual(error.reason, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(probe.ends, 0)
        do { _ = try await executor.run(timeout: 1) { _ in true }; XCTFail("Expected busy") }
        catch let error as OCRFailure { XCTAssertEqual(error.reason, .busy) }
        release.signal()
        try await wait { probe.ends == 1 }
        try await Task.sleep(for: .milliseconds(20))
        let recovered = try await executor.run(timeout: 1) { _ in true }
        XCTAssertTrue(recovered)
    }
}
private final class OCRWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0, ended = 0, hadTask = false, hadMain = false
    var starts: Int { lock.withLock { started } }
    var ends: Int { lock.withLock { ended } }
    var swiftTask: Bool { lock.withLock { hadTask } }
    var mainThread: Bool { lock.withLock { hadMain } }
    func enter() { let task = withUnsafeCurrentTask { $0 != nil }; lock.withLock { started += 1; hadTask = hadTask || task; hadMain = hadMain || Thread.isMainThread } }
    func exit() { lock.withLock { ended += 1 } }
}
