// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Publishes interoperable file references and bounded, genuine image/PDF content.
/// The caller owns cut/move intent; it must associate that intent with the returned change count.
@MainActor
public final class FileClipboard {
    public enum Failure: Sendable, Equatable { case rejectedFiles }
    public static let locationsType = NSPasteboard.PasteboardType("io.github.leoars.myexplorer.locations")
    public static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static var filenamesUTI: NSPasteboard.PasteboardType {
        let type = UTType(tag: filenamesType.rawValue, tagClass: UTTagClass(rawValue: "com.apple.nspboard-type"), conformingTo: nil)
        return NSPasteboard.PasteboardType(type?.identifier ?? filenamesType.rawValue)
    }
    public static var dragTypes: [NSPasteboard.PasteboardType] { [.fileURL, filenamesType, filenamesUTI, locationsType] }
    private let contentLimitBytes: Int
    private let prepareContent: @Sendable ([URL], Int) async -> [PreparedItem]
    private var generation: UInt64 = 0
    private var worker: Task<[PreparedItem], Never>?
    public private(set) var lastWriteChangeCount: Int?
    public private(set) var lastFailure: Failure?

    public init(contentLimitBytes: Int = 128 * 1024 * 1024) {
        self.contentLimitBytes = max(0, min(contentLimitBytes, 128 * 1024 * 1024))
        self.prepareContent = { urls, limit in
            await prepareClipboard(urls, contentLimit: limit)
        }
    }

    // Deterministic worker injection for concurrency tests; publishing still uses the actual pasteboard.
    init(contentLimitBytes: Int = 128 * 1024 * 1024,
         prepareContent: @escaping @Sendable ([URL], Int) async -> [PreparedItem]) {
        self.contentLimitBytes = max(0, min(contentLimitBytes, 128 * 1024 * 1024))
        self.prepareContent = prepareContent
    }

    init(contentLimitBytes: Int = 128 * 1024 * 1024,
         inspectPayload: @escaping @Sendable (URL) -> ClipboardPayloadMetadata?) {
        self.contentLimitBytes = max(0, min(contentLimitBytes, 128 * 1024 * 1024))
        self.prepareContent = { urls, limit in
            await prepareClipboard(urls, contentLimit: limit, inspectPayload: inspectPayload)
        }
    }

    public func cancelPendingWrite() {
        generation &+= 1
        worker?.cancel()
        worker = nil
    }

    /// A lightweight drag reference. Regular local files are interoperable with other apps.
    /// Directories and symlinks use a private reference, avoiding a recursive export scan on the UI thread.
    /// Their actual transfer is validated asynchronously by My Explorer's transfer engine.
    public static func pasteboardWriter(for url: URL) -> (any NSPasteboardWriting)? {
        guard validLocation(url) else { return nil }
        if url.isFileURL {
            guard !LocalTransferRecovery.isProtected(url) else { return nil }
            var metadata = Darwin.stat()
            guard lstat(url.path, &metadata) == 0 else { return nil }
            switch metadata.st_mode & S_IFMT {
            case S_IFREG: return url as NSURL
            case S_IFDIR, S_IFLNK: break
            default: return nil
            }
        }
        guard let data = try? JSONEncoder().encode([url.absoluteString]) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: locationsType)
        return item
    }

    /// Prepares representations off the main thread and publishes all items once.
    /// Returns false without replacing the clipboard if cancelled, superseded, invalid,
    /// or another app changed the pasteboard while content was being prepared.
    /// A failure of the final AppKit write after clearContents may leave it empty;
    /// arbitrary previous clipboard contents are not eagerly materialized for rollback.
    @discardableResult
    public func write(urls: [URL], to pasteboard: NSPasteboard = .general) async -> Bool {
        cancelPendingWrite()
        lastWriteChangeCount = nil
        lastFailure = nil
        let request = generation
        guard !urls.isEmpty, urls.count <= 10_000, urls.allSatisfy(Self.validLocation),
              urls.allSatisfy(\.isFileURL) || urls.allSatisfy({ !$0.isFileURL }),
              urls.reduce(0, { $0 + $1.absoluteString.utf8.count + 4 }) <= 1024 * 1024,
              let metadata = try? JSONEncoder().encode(urls.map(\.absoluteString)),
              metadata.count + (urls[0].isFileURL ? 0 : urls.count - 1) <= 1024 * 1024 else {
            lastFailure = .rejectedFiles
            return false
        }
        let changeCount = pasteboard.changeCount
        let limit = contentLimitBytes
        let prepareContent = self.prepareContent
        let preparation = Task { await prepareContent(urls, limit) }
        worker = preparation
        defer { if request == generation { worker = nil } }
        let prepared = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        guard request == generation, !Task.isCancelled, !preparation.isCancelled,
              pasteboard.changeCount == changeCount else { return false }
        guard prepared.count == urls.count else { lastFailure = .rejectedFiles; return false }
        let items = prepared.map { item in
            let result = NSPasteboardItem()
            // Rich representations precede text for destinations that honor pasteboard type order.
            for representation in item.representations {
                result.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            if item.url.isFileURL {
                result.setString(item.url.absoluteString, forType: .fileURL)
                // Text-only destinations receive the filename, never an icon masquerading as a file.
                result.setString(item.url.lastPathComponent, forType: .string)
            } else if let reference = try? JSONEncoder().encode([item.url.absoluteString]) {
                result.setData(reference, forType: Self.locationsType)
            }
            return result
        }
        if urls.allSatisfy(\.isFileURL) {
            items[0].setData(metadata, forType: Self.locationsType)
            items[0].setPropertyList(urls.map(\.path), forType: Self.filenamesUTI)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return false }
        lastWriteChangeCount = pasteboard.changeCount
        return true
    }

    /// Reads modern file URLs, Finder's legacy filename list, or My Explorer cloud locations.
    /// Custom metadata never overrides a different set of public local file URLs.
    public static func readURLs(from pasteboard: NSPasteboard = .general, allowPrivateLocalReferences: Bool = false) -> [URL] {
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= 10_000 else { return [] }
        let modern = items.compactMap { item -> URL? in
            guard let text = item.string(forType: .fileURL), text.utf8.count <= 16_384,
                  let url = URL(string: text), url.isFileURL, validLocation(url) else { return nil }
            return url
        }
        if !modern.isEmpty {
            if modern.count == items.count { return modern }
            guard allowPrivateLocalReferences else { return [] }
            var combined: [URL] = []
            for item in items {
                if let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL, validLocation(url) {
                    combined.append(url)
                } else {
                    guard !item.types.contains(.fileURL),
                          let data = item.data(forType: locationsType), data.count <= 16_400,
                          let strings = try? JSONDecoder().decode([String].self, from: data), strings.count == 1,
                          let url = URL(string: strings[0]), url.isFileURL, validLocation(url) else { return [] }
                    combined.append(url)
                }
            }
            return combined
        }
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String],
           !paths.isEmpty, paths.count <= 10_000,
           paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) && $0.utf8.count <= 16_384 }) {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        var locations: [URL] = []
        var metadataBytes = 0
        for item in items {
            guard let data = item.data(forType: locationsType) else { return [] }
            metadataBytes += data.count
            guard metadataBytes <= 1024 * 1024,
                  let strings = try? JSONDecoder().decode([String].self, from: data), !strings.isEmpty,
                  strings.count <= 10_000 - locations.count else { return [] }
            let urls = strings.compactMap(URL.init(string:))
            guard urls.count == strings.count, urls.allSatisfy(validLocation) else { return [] }
            locations += urls
        }
        if locations.allSatisfy({ !$0.isFileURL }) { return locations }
        return allowPrivateLocalReferences && locations.allSatisfy(\.isFileURL) ? locations : []
    }

    private static func validLocation(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 16_384, url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil, !url.path.utf8.contains(0) else { return false }
        if url.isFileURL {
            return (url.host == nil || url.host == "" || url.host == "localhost") && url.path.hasPrefix("/")
        }
        guard let remote = RemoteLocation.parse(url), !remote.key.contains("\\") else { return false }
        return remote.key.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }
}

struct PreparedItem: Sendable {
    let url: URL
    let representations: [Representation]
}
struct Representation: Sendable {
    let type: String
    let data: Data
}

private func prepareClipboard(_ urls: [URL], contentLimit: Int,
                              inspectPayload: @escaping @Sendable (URL) -> ClipboardPayloadMetadata? = ClipboardPayloadMetadata.inspect) async -> [PreparedItem] {
    await ClipboardPreparationExecutor.shared.run { control in
        for url in urls where url.isFileURL {
            guard !control.isCancelled else { return [] }
            do { try LocalTransferRecovery.assertExportable(url) } catch { return [] }
        }
        return prepare(urls, contentLimit: contentLimit, control: control, inspectPayload: inspectPayload)
    }
}

private func prepare(_ urls: [URL], contentLimit: Int, control: ClipboardCancellation,
                     inspectPayload: @Sendable (URL) -> ClipboardPayloadMetadata?) -> [PreparedItem] {
    var remaining = contentLimit
    return urls.map { url in
        guard !control.isCancelled, url.isFileURL, remaining > 0,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type == .pdf,
              let data = readBoundedRegularFile(url, limit: remaining, control: control, inspectPayload: inspectPayload) else {
            return PreparedItem(url: url, representations: [])
        }
        let representationType: String
        if type == .pdf {
            guard data.starts(with: Data("%PDF-".utf8)) else { return PreparedItem(url: url, representations: []) }
            representationType = UTType.pdf.identifier
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let actual = CGImageSourceGetType(source), let actualType = UTType(actual as String), actualType.conforms(to: .image),
                  CGImageSourceGetCount(source) > 0 else { return PreparedItem(url: url, representations: []) }
            representationType = actualType.identifier
        }
        remaining -= data.count
        return PreparedItem(url: url, representations: [Representation(type: representationType, data: data)])
    }
}

/// Does not read symlink entries or special files; reads are bounded and off the main thread.
/// Rejects content when the opened file changes during the read.
private func readBoundedRegularFile(_ url: URL, limit: Int, control: ClipboardCancellation,
                                    inspectPayload: @Sendable (URL) -> ClipboardPayloadMetadata?) -> Data? {
    // Never open File Provider/iCloud placeholders just to enrich clipboard representations.
    // Their public file URL remains usable; choosing to paste elsewhere is a separate operation.
    guard !control.isCancelled, let metadata = inspectPayload(url), metadata.permitsContentRead(limit: limit) else { return nil }
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var before = Darwin.stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
          before.st_size > 0, before.st_size <= limit, before.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
    var result = Data()
    result.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: min(Int(before.st_size), 256 * 1024))
    while result.count < before.st_size {
        guard !control.isCancelled else { return nil }
        let capacity = min(buffer.count, Int(before.st_size) - result.count)
        let amount = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, capacity) }
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { return nil }
        result.append(buffer, count: amount)
    }
    var after = Darwin.stat()
    var currentPath = Darwin.stat()
    guard fstat(descriptor, &after) == 0, lstat(url.path, &currentPath) == 0,
          sameFile(before, after), sameFile(before, currentPath),
          (after.st_flags | currentPath.st_flags) & UInt32(SF_DATALESS) == 0, !control.isCancelled else { return nil }
    return result
}

private func sameFile(_ before: Darwin.stat, _ after: Darwin.stat) -> Bool {
    before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size &&
    before.st_mode == after.st_mode && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
    before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
    before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
}

/// Metadata-only preflight, injectable without creating real File Provider placeholders.
struct ClipboardPayloadMetadata: Sendable {
    let mode: mode_t
    let flags: UInt32
    let size: Int64
    func permitsContentRead(limit: Int) -> Bool {
        mode & S_IFMT == S_IFREG && flags & UInt32(SF_DATALESS) == 0 && size > 0 && size <= limit
    }
    static func inspect(_ url: URL) -> ClipboardPayloadMetadata? {
        var value = Darwin.stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return .init(mode: value.st_mode, flags: value.st_flags, size: value.st_size)
    }
}
