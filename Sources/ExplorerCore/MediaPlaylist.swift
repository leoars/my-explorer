// SPDX-License-Identifier: Apache-2.0
import Foundation
import UniformTypeIdentifiers

/// Classification by filename, without opening files or scanning the filesystem.
/// The viewer still checks readability and whether its decoder supports the actual contents.
public enum MediaKind: String, Sendable {
    case image, video, audio

    public static func detect(_ entry: FileEntry) -> MediaKind? {
        guard isLocalMediaURL(entry.url), !entry.canNavigate, !entry.isDirectory, !entry.isPackage, !entry.isAlias,
              let type = UTType(filenameExtension: entry.url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }
}

/// A snapshot of the displayed list, retaining its ordering and original file URLs.
public struct MediaPlaylist: Sendable {
    public let entries: [FileEntry]
    public private(set) var index: Int
    public var current: FileEntry { entries[index] }
    public var count: Int { entries.count }
    public var canPrevious: Bool { index > 0 }
    public var canNext: Bool { index + 1 < entries.count }

    /// Fails when the requested selection is absent or is not a supported local media entry.
    public init?(entries: [FileEntry], selectedURL: URL) {
        guard isLocalMediaURL(selectedURL) else { return nil }
        var identities: Set<String> = []
        let media = entries.filter { entry in
            MediaKind.detect(entry) != nil && identities.insert(entry.id).inserted
        }
        guard let index = media.firstIndex(where: { $0.id == selectedURL.explorerIdentity }) else { return nil }
        self.entries = media
        self.index = index
    }

    /// Returns nil at either boundary, leaving the current item selected; navigation never wraps.
    @discardableResult public mutating func previous() -> FileEntry? {
        guard canPrevious else { return nil }
        index -= 1
        return current
    }

    @discardableResult public mutating func next() -> FileEntry? {
        guard canNext else { return nil }
        index += 1
        return current
    }
}

/// macOS hardware key codes; kept independent of AppKit for navigation tests.
public enum MediaNavigationDirection: Equatable, Sendable {
    case previous, next

    public static func direction(keyCode: UInt16) -> MediaNavigationDirection? {
        switch keyCode {
        case 123, 116: .previous // Left arrow, Page Up
        case 124, 121: .next     // Right arrow, Page Down
        default: nil
        }
    }
}

private func isLocalMediaURL(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
        && url.query == nil && url.fragment == nil && url.path.hasPrefix("/")
}
