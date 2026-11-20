// SPDX-License-Identifier: Apache-2.0
import AppKit
@testable import ExplorerCore
import Foundation
import Darwin
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ExplorerClipboard

@MainActor
struct FileClipboardTests {
    private struct Fixture {
        let root: URL
        let board: NSPasteboard
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MyExplorer.ClipboardTests.\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            board = NSPasteboard(name: NSPasteboard.Name("MyExplorer.ClipboardTests.\(UUID())"))
        }
        func clean() { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
    }

    @Test func localURLsKeepOrderNamesAndLegacyCompatibilityWithoutAPKIcon() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let apk = try fixture.file("Ação 日本語.apk", data: Data([0x50, 0x4b, 3, 4]))
        let text = try fixture.file("readme.txt", data: Data("payload".utf8))
        let clipboard = FileClipboard()
        #expect(await clipboard.write(urls: [apk, text, fixture.root], to: fixture.board))
        #expect(clipboard.lastWriteChangeCount == fixture.board.changeCount)
        #expect(FileClipboard.readURLs(from: fixture.board) == [apk, text, fixture.root])
        #expect(fixture.board.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] == [apk.path, text.path, fixture.root.path])
        let native = fixture.board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(native == [apk, text, fixture.root])
        #expect(fixture.board.pasteboardItems?.count == 3)
        #expect(fixture.board.pasteboardItems?.first?.string(forType: .string) == apk.lastPathComponent)
        for item in fixture.board.pasteboardItems ?? [] {
            #expect(item.data(forType: .png) == nil)
            #expect(item.data(forType: .tiff) == nil)
        }
        #expect(try Data(contentsOf: apk) == Data([0x50, 0x4b, 3, 4]))
    }

    @Test func imagesAndPDFPublishRealOriginalContent() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let clipboard = FileClipboard()
        for (ext, type) in [("png", UTType.png), ("jpg", .jpeg), ("tiff", .tiff), ("gif", .gif)] {
            let bytes = try imageData(type)
            let url = try fixture.file("image.\(ext)", data: bytes)
            #expect(await clipboard.write(urls: [url], to: fixture.board))
            let published = try #require(fixture.board.data(forType: NSPasteboard.PasteboardType(type.identifier)))
            #expect(published == bytes)
            #expect(fixture.board.pasteboardItems?.first?.types.first?.rawValue == type.identifier)
            let source = try #require(CGImageSourceCreateWithData(published as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 2 && image.height == 1)
            #expect(NSImage(pasteboard: fixture.board) != nil)
            #expect(FileClipboard.readURLs(from: fixture.board) == [url])
            #expect((fixture.board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == [url])
        }
        let pdf = Data("%PDF-1.7\nfixture".utf8)
        let url = try fixture.file("report.pdf", data: pdf)
        #expect(await clipboard.write(urls: [url], to: fixture.board))
        #expect(fixture.board.data(forType: .pdf) == pdf)
    }

    @Test func oversizedInvalidAndSymlinkImagesRemainReferencesAndMissingFilesReject() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let image = try fixture.file("large.png", data: imageData(.png))
        let invalid = try fixture.file("not-an-image.png", data: Data("not an image".utf8))
        let missing = fixture.root.appendingPathComponent("missing.png")
        let symlink = fixture.root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: image)
        let clipboard = FileClipboard(contentLimitBytes: 8)
        #expect(await clipboard.write(urls: [image, invalid, symlink], to: fixture.board))
        #expect(FileClipboard.readURLs(from: fixture.board) == [image, invalid, symlink])
        #expect(fixture.board.pasteboardItems?.allSatisfy { $0.data(forType: .png) == nil } == true)
        #expect(await FileClipboard().write(urls: [invalid, symlink], to: fixture.board))
        #expect(fixture.board.pasteboardItems?.allSatisfy { $0.data(forType: .png) == nil } == true)
        let previousCount = fixture.board.changeCount
        #expect(await clipboard.write(urls: [image, missing], to: fixture.board) == false)
        #expect(fixture.board.changeCount == previousCount)
        #expect(clipboard.lastFailure == .rejectedFiles)
    }

    @Test func contentBudgetIsSharedAcrossItems() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let bytes = try imageData(.png)
        let a = try fixture.file("a.png", data: bytes), b = try fixture.file("b.png", data: bytes)
        let clipboard = FileClipboard(contentLimitBytes: bytes.count)
        #expect(await clipboard.write(urls: [a, b], to: fixture.board))
        let items = try #require(fixture.board.pasteboardItems)
        #expect(items[0].data(forType: .png) == bytes)
        #expect(items[1].data(forType: .png) == nil)
        #expect(FileClipboard.readURLs(from: fixture.board) == [a, b])
    }

    @Test func placeholderMetadataPublishesOnlyURLsWithoutOpeningPayload() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let image = try fixture.file("placeholder.png", data: imageData(.png))
        let pdf = try fixture.file("placeholder.pdf", data: Data("%PDF-1.7\nCONTENT SHOULD NOT BE READ".utf8))
        let clipboard = FileClipboard(inspectPayload: { _ in
            .init(mode: mode_t(S_IFREG), flags: UInt32(SF_DATALESS), size: 1024)
        })
        #expect(await clipboard.write(urls: [image, pdf], to: fixture.board))
        #expect(FileClipboard.readURLs(from: fixture.board) == [image, pdf])
        for item in fixture.board.pasteboardItems ?? [] {
            #expect(item.data(forType: .png) == nil)
            #expect(item.data(forType: .pdf) == nil)
        }
        #expect(ClipboardPayloadMetadata(mode: mode_t(S_IFREG), flags: UInt32(SF_DATALESS), size: 1).permitsContentRead(limit: 1024) == false)
        #expect(ClipboardPayloadMetadata(mode: mode_t(S_IFREG), flags: 0, size: 1).permitsContentRead(limit: 1024))
    }

    @Test func blockedPreparationCancellationPreservesClipboardAndNeverPublishesLate() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let prior = try fixture.file("prior.txt", data: Data("PRIOR".utf8))
        let next = try fixture.file("next.txt", data: Data("NEXT".utf8))
        #expect(await FileClipboard().write(urls: [prior], to: fixture.board))
        let previousCount = fixture.board.changeCount
        let executor = ClipboardPreparationExecutor(concurrency: 1, capacity: 1)
        let barrier = BlockingClipboardPreparation()
        defer { barrier.release() }
        let clipboard = FileClipboard(prepareContent: { urls, _ in
            await executor.run { _ in
                barrier.block()
                return urls.map { PreparedItem(url: $0, representations: []) }
            }
        })
        let task = Task { await clipboard.write(urls: [next], to: fixture.board) }
        try await barrier.waitForEntry()
        let clock = ContinuousClock(); let start = clock.now
        task.cancel()
        #expect(await task.value == false)
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(executor.pendingCount == 1)
        #expect(fixture.board.changeCount == previousCount)
        #expect(FileClipboard.readURLs(from: fixture.board) == [prior])
        let denied = await executor.run { _ in [PreparedItem(url: next, representations: [])] }
        #expect(denied.isEmpty) // Cancellation cannot free the occupied syscall slot.
        barrier.release()
        for _ in 0..<200 where executor.pendingCount != 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(executor.pendingCount == 0)
        #expect(fixture.board.changeCount == previousCount)
        #expect(FileClipboard.readURLs(from: fixture.board) == [prior])
    }

    @Test func preparationDeadlineAndQueuedCancellationDoNotReuseBusyWorkers() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let prior = try fixture.file("prior.txt", data: Data("PRIOR".utf8))
        #expect(await FileClipboard().write(urls: [prior], to: fixture.board))
        let previousCount = fixture.board.changeCount
        let executor = ClipboardPreparationExecutor(concurrency: 1, capacity: 2)
        let barrier = BlockingClipboardPreparation(), queued = BlockingClipboardPreparation()
        defer { barrier.release(); queued.release() }
        let clipboard = FileClipboard(prepareContent: { urls, _ in
            await executor.run(timeout: 0.05) { _ in
                barrier.block()
                return urls.map { PreparedItem(url: $0, representations: []) }
            }
        })
        let task = Task { await clipboard.write(urls: [prior], to: fixture.board) }
        try await barrier.waitForEntry()
        let waiting = Task { await executor.run { _ in queued.block(); return [PreparedItem(url: prior, representations: [])] } }
        for _ in 0..<200 where executor.pendingCount != 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(executor.pendingCount == 2)
        waiting.cancel()
        #expect(await waiting.value.isEmpty)
        // A MainActor continuation remains responsive while the real worker is still blocked.
        await Task.yield()
        #expect(await task.value == false)
        #expect(executor.pendingCount == 2)
        #expect(!queued.entered)
        #expect(fixture.board.changeCount == previousCount)
        #expect(clipboard.lastFailure == .rejectedFiles)
        barrier.release()
        for _ in 0..<200 where executor.pendingCount != 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(executor.pendingCount == 0)
        #expect(!queued.entered)
        #expect(fixture.board.changeCount == previousCount)
    }

    @Test func cloudReferencesAndIndividualDragItemsRoundTripWithoutDownloads() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let a = RemoteLocation.url(connectionID: UUID(), key: "Ação 日本語/file.png")
        let b = RemoteLocation.url(connectionID: UUID(), key: "folder/")
        #expect(await FileClipboard().write(urls: [a, b], to: fixture.board))
        #expect(FileClipboard.readURLs(from: fixture.board) == [a, b])
        #expect(fixture.board.data(forType: .fileURL) == nil)
        #expect(fixture.board.data(forType: .png) == nil)
        fixture.board.clearContents()
        #expect(fixture.board.writeObjects([try #require(FileClipboard.pasteboardWriter(for: a)), try #require(FileClipboard.pasteboardWriter(for: b))]))
        #expect(FileClipboard.readURLs(from: fixture.board) == [a, b])
        fixture.board.clearContents()
        fixture.board.setData(try JSONEncoder().encode([a.absoluteString, b.absoluteString]), forType: FileClipboard.locationsType)
        #expect(FileClipboard.readURLs(from: fixture.board) == [a, b])
        #expect(FileClipboard.pasteboardWriter(for: URL(string: "https://example.com/?token=secret")!) == nil)
    }

    @Test func nativeAndLegacyImportsIgnoreConflictingCustomReferences() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let file = fixture.root.appendingPathComponent("local.txt")
        let other = fixture.root.appendingPathComponent("do-not-use.txt")
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setData(try JSONEncoder().encode([other.absoluteString]), forType: FileClipboard.locationsType)
        fixture.board.writeObjects([item])
        #expect(FileClipboard.readURLs(from: fixture.board) == [file])
        fixture.board.clearContents()
        fixture.board.setPropertyList([file.path, other.path], forType: FileClipboard.filenamesType)
        #expect(FileClipboard.readURLs(from: fixture.board) == [file, other])
        fixture.board.clearContents()
        fixture.board.setPropertyList(["relative/path"], forType: FileClipboard.filenamesType)
        #expect(FileClipboard.readURLs(from: fixture.board).isEmpty)
    }

    @Test func externalClipboardChangeDuringPreparationIsPreserved() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let barrier = PreparationBarrier()
        let clipboard = FileClipboard(prepareContent: { urls, _ in
            await barrier.enterOnce()
            return urls.map { PreparedItem(url: $0, representations: []) }
        })
        fixture.board.setString("before", forType: .string)
        let task = Task { await clipboard.write(urls: [fixture.root], to: fixture.board) }
        await barrier.waitForEntry()
        fixture.board.clearContents(); fixture.board.setString("from another app", forType: .string)
        await barrier.release()
        #expect(await task.value == false)
        #expect(fixture.board.string(forType: .string) == "from another app")
        #expect(clipboard.lastWriteChangeCount == nil)
        #expect(clipboard.lastFailure == nil)
    }

    @Test func newestCopyWinsAndExplicitCancellationPreservesExistingClipboard() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let barrier = PreparationBarrier()
        let clipboard = FileClipboard(prepareContent: { urls, _ in
            await barrier.enterOnce()
            return urls.map { PreparedItem(url: $0, representations: []) }
        })
        let first = try fixture.file("first.txt", data: Data("first".utf8))
        let second = try fixture.file("second.txt", data: Data("second".utf8))
        let task = Task { await clipboard.write(urls: [first], to: fixture.board) }
        await barrier.waitForEntry()
        #expect(await clipboard.write(urls: [second], to: fixture.board))
        await barrier.release()
        #expect(await task.value == false)
        #expect(FileClipboard.readURLs(from: fixture.board) == [second])

        let anotherBarrier = PreparationBarrier()
        let cancellable = FileClipboard(prepareContent: { urls, _ in
            await anotherBarrier.enterOnce()
            return urls.map { PreparedItem(url: $0, representations: []) }
        })
        let cancelled = Task { await cancellable.write(urls: [first], to: fixture.board) }
        await anotherBarrier.waitForEntry()
        cancellable.cancelPendingWrite()
        await anotherBarrier.release()
        #expect(await cancelled.value == false)
        #expect(FileClipboard.readURLs(from: fixture.board) == [second])

        let callerBarrier = PreparationBarrier()
        let callerClipboard = FileClipboard(prepareContent: { urls, _ in
            await callerBarrier.enterOnce()
            return urls.map { PreparedItem(url: $0, representations: []) }
        })
        let cancelledCaller = Task { await callerClipboard.write(urls: [first], to: fixture.board) }
        await callerBarrier.waitForEntry()
        cancelledCaller.cancel()
        await callerBarrier.release()
        #expect(await cancelledCaller.value == false)
        #expect(callerClipboard.lastWriteChangeCount == nil)
        #expect(FileClipboard.readURLs(from: fixture.board) == [second])
    }

    @Test func privateRecoveryDataCannotBePublishedOrDragged() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let ordinary = try fixture.file("ordinary.txt", data: Data("ordinary".utf8))
        let protected = fixture.root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try LocalTransferRecovery.mark(protected)
        let saved = protected.appendingPathComponent("previous-user-file.txt")
        try Data("private overwritten original".utf8).write(to: saved)
        let clipboard = FileClipboard()
        #expect(await clipboard.write(urls: [ordinary], to: fixture.board))
        let previousCount = fixture.board.changeCount
        for url in [protected, saved, fixture.root] {
            #expect(await clipboard.write(urls: [ordinary, url], to: fixture.board) == false)
            #expect(fixture.board.changeCount == previousCount)
            #expect(FileClipboard.readURLs(from: fixture.board) == [ordinary])
            #expect(clipboard.lastFailure == .rejectedFiles)
        }
        #expect(FileClipboard.pasteboardWriter(for: protected) == nil)
        #expect(FileClipboard.pasteboardWriter(for: saved) == nil)
        // An ancestor may be dragged only as a private local reference; the transfer engine
        // performs the full asynchronous recursive export check before copying it.
        let privateAncestor = try #require(FileClipboard.pasteboardWriter(for: fixture.root) as? NSPasteboardItem)
        #expect(privateAncestor.string(forType: .fileURL) == nil)
        let lookalike = fixture.root.appendingPathComponent(".my-explorer-copy-ordinary")
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: false)
        #expect(await clipboard.write(urls: [lookalike], to: fixture.board))
        #expect(FileClipboard.pasteboardWriter(for: lookalike) != nil)
    }

    @Test func mixedInternalDragKeepsPublicFileAndPrivateFolderWithoutEnablingExternalFolderExport() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let file = try fixture.file("file.txt", data: Data("file".utf8))
        let folder = fixture.root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fileWriter = try #require(FileClipboard.pasteboardWriter(for: file))
        let folderWriter = try #require(FileClipboard.pasteboardWriter(for: folder))
        #expect(fixture.board.writeObjects([fileWriter, folderWriter]))
        #expect(FileClipboard.readURLs(from: fixture.board, allowPrivateLocalReferences: true) == [file, folder])
        #expect(FileClipboard.readURLs(from: fixture.board).isEmpty)
        let items = try #require(fixture.board.pasteboardItems)
        #expect(items[0].string(forType: .fileURL) == file.absoluteString)
        #expect(items[1].string(forType: .fileURL) == nil)
        fixture.board.clearContents()
        #expect(fixture.board.writeObjects([try #require(FileClipboard.pasteboardWriter(for: folder))]))
        #expect(FileClipboard.readURLs(from: fixture.board, allowPrivateLocalReferences: true) == [folder])
        #expect(FileClipboard.readURLs(from: fixture.board).isEmpty)
    }

    private func imageData(_ type: UTType) throws -> Data {
        let pixels = Data([255, 0, 0, 255, 0, 0, 255, 255])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class BlockingClipboardPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }
    func block() { lock.withLock { didEnter = true }; semaphore.wait() }
    func release() { semaphore.signal() }
    func waitForEntry() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.fileReadUnknown)
    }
}

private actor PreparationBarrier {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func enterOnce() async {
        guard !entered else { return }
        entered = true
        for observer in observers { observer.resume() }
        observers = []
        await withCheckedContinuation { waiting = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { waiting?.resume(); waiting = nil }
}
