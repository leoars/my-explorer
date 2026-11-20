// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ExplorerCore

final class SearchablePDFPublicationTests: XCTestCase, @unchecked Sendable {
    func testCancellationBeforeCommitPreventsEffectAndReleasesCaller() async throws {
        let executor = OCRExecutor(concurrency: 1, capacity: 2), started = expectation(description: "started")
        let gate = DispatchSemaphore(value: 0), effects = PDFPublicationProbe()
        let task = Task {
            try await executor.publish(timeout: 5) { _, claim in
                started.fulfill(); gate.wait(); try claim(); effects.record(); return "published"
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") }
        catch { XCTAssertEqual((error as? SearchablePDFFailure)?.reason, .cancelled) }
        XCTAssertEqual(effects.count, 0)
        gate.signal()
        let drained = try await executor.run(timeout: 2) { _ in true }
        XCTAssertTrue(drained); XCTAssertEqual(effects.count, 0)
    }
    func testCancellationAfterCommitReturnsConfirmedReceipt() async throws {
        let executor = OCRExecutor(concurrency: 1, capacity: 2), started = expectation(description: "claimed")
        let gate = DispatchSemaphore(value: 0), effects = PDFPublicationProbe()
        let task = Task {
            try await executor.publish(timeout: 5) { _, claim in
                try claim(); started.fulfill(); gate.wait(); effects.record(); return "confirmed"
            }
        }
        await fulfillment(of: [started], timeout: 2); task.cancel(); gate.signal()
        let value = try await task.value
        XCTAssertEqual(value, "confirmed"); XCTAssertEqual(effects.count, 1)
    }
    func testDeadlineDuringCommitReportsIndeterminateAndRetainsWorkerUntilRealCompletion() async throws {
        let executor = OCRExecutor(concurrency: 1, capacity: 1), started = expectation(description: "claimed")
        let gate = DispatchSemaphore(value: 0), effects = PDFPublicationProbe()
        let task = Task {
            try await executor.publish(timeout: 0.2) { _, claim in
                try claim(); started.fulfill(); gate.wait(); effects.record(); return "confirmed"
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await task.value; XCTFail("Should report uncertainty") }
        catch { XCTAssertEqual((error as? SearchablePDFFailure)?.reason, .publicationIndeterminate) }
        do { _ = try await executor.run(timeout: 1) { _ in true }; XCTFail("Occupied slot must remain retained") }
        catch { XCTAssertEqual((error as? OCRFailure)?.reason, .busy) }
        XCTAssertEqual(effects.count, 0); gate.signal()
        for _ in 0..<100 where effects.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.count, 1)
    }
    func testAlreadyCancelledPublicationNeverDispatches() async throws {
        let executor = OCRExecutor(concurrency: 1, capacity: 1), effects = PDFPublicationProbe()
        let start = PDFTestAsyncGate()
        let task = Task {
            await start.wait()
            return try await executor.publish(timeout: 1) { _, claim in try claim(); effects.record(); return true }
        }
        task.cancel(); await start.open()
        do { _ = try await task.value; XCTFail("Cancelled") }
        catch { XCTAssertEqual((error as? SearchablePDFFailure)?.reason, .cancelled) }
        XCTAssertEqual(effects.count, 0)
        let result = try await executor.run(timeout: 1) { _ in true }; XCTAssertTrue(result)
    }
}
private final class PDFPublicationProbe: @unchecked Sendable {
    let lock = NSLock(); private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
private actor PDFTestAsyncGate {
    private var ready = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if ready { return }; await withCheckedContinuation { continuation = $0 } }
    func open() { ready = true; continuation?.resume(); continuation = nil }
}
