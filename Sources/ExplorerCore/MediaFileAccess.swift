// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

public enum MediaFileAvailability: Equatable, Sendable {
    /// A materialized regular file. Decoding and content readability still belong to the caller.
    case available(URL)
    /// A File Provider/iCloud placeholder; opening its contents could initiate a download.
    case needsDownload
    case unavailable
}

/// Metadata-only preflight for image, audio, video and preview readers.
/// Run outside MainActor: filesystem metadata itself can be slow on external/network volumes.
public enum MediaFileAccess {
    public static func availability(of url: URL, isAlias: Bool = false) -> MediaFileAvailability {
        guard !isAlias, url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.query == nil, url.fragment == nil, !Task.isCancelled else { return .unavailable }
        var original = stat()
        guard lstat(url.path, &original) == 0,
              original.st_mode & S_IFMT == S_IFREG || original.st_mode & S_IFMT == S_IFLNK else { return .unavailable }
        guard let path = realpath(url.path, nil) else { return .unavailable }
        let resolved = URL(fileURLWithPath: String(cString: path)); free(path)
        var target = stat()
        guard lstat(resolved.path, &target) == 0, target.st_mode & S_IFMT == S_IFREG else { return .unavailable }
        do {
            try LocalTransferRecovery.assertExportable(url)
            try LocalTransferRecovery.assertExportable(resolved)
        } catch { return .unavailable }

        let availability = classify(mode: target.st_mode, originalFlags: original.st_flags,
                                    resolvedFlags: target.st_flags, resolvedURL: resolved)
        guard case .available = availability else { return availability }
        // Finder aliases are bookmark files, not media, even when their names end in .jpg/.mp4.
        guard !hasFinderAliasFlag(resolved) else { return .unavailable }
        var latest = stat()
        guard lstat(resolved.path, &latest) == 0, latest.st_dev == target.st_dev, latest.st_ino == target.st_ino,
              latest.st_mode == target.st_mode, !Task.isCancelled else { return .unavailable }
        return classify(mode: latest.st_mode, originalFlags: original.st_flags,
                        resolvedFlags: latest.st_flags, resolvedURL: resolved)
    }

    /// Kept separate because creating SF_DATALESS fixtures requires a File Provider, not chflags.
    static func classify(mode: mode_t, originalFlags: UInt32, resolvedFlags: UInt32,
                         resolvedURL: URL) -> MediaFileAvailability {
        guard mode & S_IFMT == S_IFREG else { return .unavailable }
        if (originalFlags | resolvedFlags) & UInt32(SF_DATALESS) != 0 { return .needsDownload }
        return .available(resolvedURL)
    }

    private static func hasFinderAliasFlag(_ url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW)
        if count < 0 { return errno != ENOATTR && errno != ENOTSUP }
        // FinderInfo stores the big-endian Finder flags at offset 8; kIsAlias is bit 15.
        return count >= 10 && info[8] & 0x80 != 0
    }
}
