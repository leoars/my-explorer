// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// The person's own home folder (/Users/name). In the App Store build the sandbox makes
/// `homeDirectoryForCurrentUser`, `NSHomeDirectory()` and `~` point at the app's container; the
/// folders a file manager shows (Desktop, Documents, the address `~/…`) are the real ones. Outside
/// the sandbox this is exactly `homeDirectoryForCurrentUser`, so the direct build does not change.
/// The app's own data (Application Support, receipts) keeps using the container on purpose.
public enum RealHome {
    /// Whether this process runs in the App Sandbox (the App Store build).
    public static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    public static let url: URL = {
        if isSandboxed, let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let path = String(cString: directory)
            if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    public static var path: String { url.path }

    /// The Pictures folder of the real home. In the sandbox, `urls(for: .picturesDirectory)` names
    /// the container's own Pictures folder; photos imported from a camera or phone belong in the
    /// person's (the `assets.pictures.read-write` entitlement opens it).
    public static var pictures: URL { pictures(in: url) }

    static func pictures(in home: URL) -> URL { home.appendingPathComponent("Pictures", isDirectory: true) }

    /// `expandingTildeInPath`, with `~` and `~/…` meaning the real home folder in the sandbox.
    public static func expandingTilde(_ text: String) -> String {
        let expanded = (text as NSString).expandingTildeInPath
        guard isSandboxed, text == "~" || text.hasPrefix("~/") else { return expanded }
        let container = NSHomeDirectory()
        guard expanded == container || expanded.hasPrefix(container + "/") else { return expanded }
        return path + expanded.dropFirst(container.count)
    }
}
