// SPDX-License-Identifier: Apache-2.0
import AppKit
import CoreText
import CryptoKit
import Darwin
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ExplorerCore

/// Opt-in, disposable-fixture acceptance campaign; never used during normal startup.
@MainActor
enum BetaStabilitySmoke {
    struct Failure: Error { let message: String }
    struct Fixture: Sendable {
        let sources: [URL]
        let tokens: [String]
        let pages: [Int]
        let hashes: [URL: Data]
        let output: URL
        let existing: URL
    }
    static func run(root: URL, browser: ExplorerWindowController) async throws {
        let area = root.appendingPathComponent("BetaStability-\(UUID())", isDirectory: true)
        let fixture = try await Task.detached { try makeFixture(area) }.value
        let batch = OCRBatchWindowController()
        defer { batch.close() }
        let clipboard = NSPasteboard.general.changeCount
        let clipboardTypes = NSPasteboard.general.types
        batch.open(fixture.sources)
        try await wait("language discovery") { batch.languagePicker.numberOfItems > 1 }
        batch.setDestination(fixture.output)
        var previousOutputs: [URL: Data] = [:]
        for cycle in 1...2 {
            let metric = Probe(); metric.start()
            batch.startBatch(nil)
            // Reading/navigation remains available while the mutation gate is occupied.
            browser.navigate(.visit(root.appendingPathComponent("Documents")))
            try await wait("navigation during OCR") { !browser.session.isLoading }
            browser.filter.stringValue = "Notes"
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filter))
            guard browser.table.numberOfRows == 1 else { throw Failure(message: "Navigation/filter blocked during batch") }
            browser.filter.stringValue = ""
            browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: browser.filter))
            browser.window?.makeKeyAndOrderFront(nil)
            batch.window?.makeKeyAndOrderFront(nil)
            try await wait("50-file batch cycle \(cycle)") { !batch.isRunning }
            let measurement = await metric.stop(label: "complete-\(cycle)")
            guard measurement < 1 else { throw Failure(message: "Batch main-thread interval exceeded one second") }
            guard let report = batch.report else { throw Failure(message: "Missing report") }
            let before = previousOutputs
            previousOutputs = try await Task.detached {
                try verify(report, fixture: fixture, prior: before, complete: true)
            }.value
            try await Task.sleep(for: .milliseconds(300))
            print("STABILITY MEMORY: cycle=\(cycle) idleRSSMiB=\(rssMiB())")
        }
        let cancelled = area.appendingPathComponent("Cancelled")
        try FileManager.default.createDirectory(at: cancelled, withIntermediateDirectories: false)
        batch.setDestination(cancelled)
        let metric = Probe(); metric.start(); batch.startBatch(nil)
        try await wait("five published files before cancellation") {
            (try? FileManager.default.contentsOfDirectory(atPath: cancelled.path).filter { $0.hasSuffix(".pdf") }.count) ?? 0 >= 5
        }
        guard batch.isRunning else { throw Failure(message: "Cancellation did not exercise running batch") }
        batch.cancelBatch(nil)
        try await wait("mid-batch cancellation") { !batch.isRunning }
        _ = await metric.stop(label: "cancel-after-five")
        guard let report = batch.report, report.items.filter({ $0.state == .succeeded }).count >= 5,
              report.items.contains(where: { $0.state == .notStarted && $0.reason == .cancelled }) else {
            throw Failure(message: "Cancellation discarded receipts or did not stop remainder")
        }
        let prior = previousOutputs
        _ = try await Task.detached { try verify(report, fixture: fixture, prior: prior, complete: false) }.value
        let expected = Set(report.items.filter { $0.state == .succeeded }.compactMap { $0.destinationURL?.lastPathComponent })
        try await awaitStagingCleanup(cancelled)
        let actual = Set(try FileManager.default.contentsOfDirectory(atPath: cancelled.path))
        guard expected == actual else { throw Failure(message: "Cancellation left unreported/partial output") }

        // Close a genuinely active window, then reopen for a different selection.
        let closed = area.appendingPathComponent("Closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: false)
        batch.setDestination(closed); batch.startBatch(nil)
        try await wait("five outputs before closing") {
            (try? FileManager.default.contentsOfDirectory(atPath: closed.path).filter { $0.hasSuffix(".pdf") }.count) ?? 0 >= 5
        }
        guard batch.isRunning else { throw Failure(message: "Close did not exercise running batch") }
        let started = ContinuousClock.now; batch.close()
        guard started.duration(to: .now) < .milliseconds(250) else { throw Failure(message: "Batch close blocked UI") }
        // Allow the cancelled worker to settle; reopened window must not receive its callbacks.
        try await awaitStagingCleanup(closed)
        try await Task.sleep(for: .milliseconds(200))
        let closedBefore = try await Task.detached { try outputHashes(closed) }.value
        let reopened = area.appendingPathComponent("Reopened")
        try FileManager.default.createDirectory(at: reopened, withIntermediateDirectories: false)
        batch.open(Array(fixture.sources.prefix(3)))
        try await wait("reopened discovery") { batch.languagePicker.numberOfItems > 1 }
        batch.setDestination(reopened); batch.startBatch(nil)
        try await wait("reopened batch") { !batch.isRunning }
        guard batch.report?.items.count == 3, batch.report?.items.allSatisfy({ $0.state == .succeeded }) == true,
              batch.table.numberOfRows == 3 else { throw Failure(message: "Closed batch contaminated reopened window or gate remained busy") }
        let closedAfter = try await Task.detached { try outputHashes(closed) }.value
        guard closedBefore == closedAfter else { throw Failure(message: "Closed batch continued writing after settling") }
        guard NSPasteboard.general.changeCount == clipboard, NSPasteboard.general.types == clipboardTypes else {
            throw Failure(message: "Searchable PDF batch changed external clipboard")
        }
        try await Task.detached { try verifyHashes(fixture.hashes); try verifyHashes(prior) }.value
        browser.navigate(.visit(root))
        try await wait("return to root") { !browser.session.isLoading }
        print("STABILITY VERIFIED: 50 sources, 48 searchable outputs per complete cycle, 2 controlled failures, repeat/cancel/close/reopen, hashes and clipboard intact")
    }
    private static func awaitStagingCleanup(_ folder: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            let pending = try await Task.detached {
                try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".my-explorer-pdf-") }
            }.value
            if !pending { return }
            guard ContinuousClock.now < deadline else { throw Failure(message: "Staging did not retire after cancellation") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private static func wait(_ description: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Timed out: \(description)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor private final class Probe {
        var task: Task<Void, Never>?
        var started = ContinuousClock.now
        var maxGap = Duration.zero
        var maxRSS = 0.0
        func start() {
            started = .now; maxRSS = rssMiB()
            task = Task { @MainActor [weak self] in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    let now = ContinuousClock.now
                    self?.maxGap = max(self?.maxGap ?? .zero, last.duration(to: now))
                    self?.maxRSS = max(self?.maxRSS ?? 0, rssMiB()); last = now
                }
            }
        }
        func stop(label: String) async -> Double {
            task?.cancel(); await task?.value
            let gap = Double(maxGap.components.seconds) + Double(maxGap.components.attoseconds) / 1e18
            print("STABILITY METRIC: \(label), elapsed=\(started.duration(to: .now)), maxMainIntervalSeconds=\(gap), peakRSSMiB=\(maxRSS), endRSSMiB=\(rssMiB())")
            return gap
        }
        deinit { task?.cancel() }
    }
    private nonisolated static func rssMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    private nonisolated static func makeFixture(_ root: URL) throws -> Fixture {
        let fm = FileManager.default
        let output = root.appendingPathComponent("Results")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        var sources: [URL] = [], tokens: [String] = [], pages: [Int] = []
        for index in 0..<50 {
            try autoreleasepool {
                let folder = root.appendingPathComponent(String(format: "Source-%02d", index))
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                let token = "REFERENCE \(1000 + index)"
                let kind = index % 4
                let name = index % 3 == 0 ? "Relatório 日本語" : "Document"
                let url = folder.appendingPathComponent(name + (kind == 0 ? ".png" : ".pdf"))
                let numberOfPages = kind == 3 ? 3 : 1
                sources.append(url); tokens.append(token); pages.append(numberOfPages)
                if index == 17 || index == 38 {
                    try Data("deliberately invalid document".utf8).write(to: url); return
                }
                let image = try raster(token)
                if kind == 0 {
                    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure(message: "PNG fixture") }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw Failure(message: "PNG fixture write") }
                } else {
                    var bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
                    guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw Failure(message: "PDF fixture") }
                    for page in 0..<numberOfPages {
                        context.beginPDFPage(nil)
                        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
                        if kind == 1 || (kind == 3 && page == 0) { draw(token, in: context, fontSize: 32, y: 350) }
                        else { context.draw(image, in: bounds) }
                        context.endPDFPage()
                    }
                    context.closePDF()
                    if index % 7 == 0, let document = PDFDocument(url: url), let page = document.page(at: 0) {
                        page.rotation = 90
                        guard document.write(to: url) else { throw Failure(message: "Rotated fixture") }
                    }
                }
            }
        }
        let existing = output.appendingPathComponent("Document-OCR.pdf")
        try Data("existing file must never be replaced".utf8).write(to: existing)
        let hashes = try Dictionary(uniqueKeysWithValues: (sources + [existing]).map { ($0, try hash($0)) })
        return Fixture(sources: sources, tokens: tokens, pages: pages, hashes: hashes, output: output, existing: existing)
    }
    private nonisolated static func draw(_ text: String, in context: CGContext, fontSize: CGFloat, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, fontSize, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        context.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
    private nonisolated static func raster(_ token: String) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure(message: "Raster fixture") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        draw(token, in: context, fontSize: 64, y: 700)
        draw("My Explorer stability acceptance document", in: context, fontSize: 38, y: 580)
        draw("Searchable copy preserves the original.", in: context, fontSize: 38, y: 480)
        guard let image = context.makeImage() else { throw Failure(message: "Raster image") }; return image
    }
    private nonisolated static func hash(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }
    private nonisolated static func verifyHashes(_ hashes: [URL: Data]) throws {
        for (url, original) in hashes { guard try hash(url) == original else { throw Failure(message: "Changed fixture: \(url.lastPathComponent)") } }
    }
    private nonisolated static func outputHashes(_ folder: URL) throws -> [URL: Data] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: urls.map { url in
            guard let document = PDFDocument(url: url), document.pageCount > 0, !(document.string ?? "").isEmpty else { throw Failure(message: "Partial or invalid published PDF") }
            return (url, try hash(url))
        })
    }
    private nonisolated static func verify(_ report: SearchablePDFBatchResult, fixture: Fixture, prior: [URL: Data], complete: Bool) throws -> [URL: Data] {
        guard report.items.count == 50, report.items.map(\.sourceURL) == fixture.sources else { throw Failure(message: "Incomplete/out-of-order batch report") }
        try verifyHashes(fixture.hashes); try verifyHashes(prior)
        var outputs = prior
        for (index, item) in report.items.enumerated() {
            try autoreleasepool {
                if item.state == .succeeded {
                    guard let url = item.destinationURL, prior[url] == nil, let document = PDFDocument(url: url), document.pageCount == fixture.pages[index] else { throw Failure(message: "Missing/reused output or page count") }
                    for page in 0..<document.pageCount {
                        guard document.page(at: page)?.string?.contains(fixture.tokens[index]) == true else { throw Failure(message: "Missing search token in output \(index), page \(page)") }
                    }
                    outputs[url] = try hash(url)
                } else if complete {
                    guard [17, 38].contains(index), item.state == .failed else { throw Failure(message: "Unexpected failure at \(index): \(String(describing: item.reason))") }
                }
            }
        }
        if complete, report.items.filter({ $0.state == .succeeded }).count != 48 { throw Failure(message: "Expected 48 successful outputs") }
        return outputs
    }
}
