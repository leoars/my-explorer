// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The size of a folder as the Properties window shows it: the bytes of every file inside it, at
/// any depth, hidden files and package contents included. A package (an application, say) counts as one
/// file, as in the Finder. Links are counted as links, never followed, so a link to a large folder
/// (or to the folder itself) adds nothing.
public enum DirectorySize {
    public struct Total: Equatable, Sendable {
        public var bytes: Int64
        public var files: Int
        public var folders: Int
        public init(bytes: Int64, files: Int, folders: Int) { self.bytes = bytes; self.files = files; self.folders = folders }
    }

    /// Walks the folder; returns nil if `isCancelled` says the answer is no longer wanted.
    /// Items that cannot be read are skipped, as the Finder does.
    public static func total(of url: URL, isCancelled: () -> Bool = { false }) -> Total? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return Total(bytes: 0, files: 0, folders: 0) }
        var total = Total(bytes: 0, files: 0, folders: 0)
        var count = 0
        for case let item as URL in walker {
            count += 1
            if count % 256 == 0, isCancelled() { return nil }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                total.files += 1
            } else if values.isDirectory == true, values.isPackage == true {
                walker.skipDescendants()
                guard let inside = Self.total(of: item, isCancelled: isCancelled) else { return nil }
                total.files += 1
                total.bytes += inside.bytes
            } else if values.isDirectory == true {
                total.folders += 1
            } else {
                total.files += 1
                total.bytes += Int64(values.fileSize ?? 0)
            }
        }
        return isCancelled() ? nil : total
    }
}
