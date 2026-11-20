// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Syntax-only normalization. Filesystem resolution belongs to the bounded OCR executor.
enum AutomationOCRLocation {
    static func parse(_ value: String) throws -> URL {
        let url = value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: false) : URL(string: value)
        guard let url else { throw AutomationError.invalidArguments }
        guard url.isFileURL else { throw AutomationError.unsupported }
        return try normalized(url)
    }
    /// Foundation may abbreviate these fixed macOS system aliases while realpath expands them.
    /// This is a string equivalence only; the resolved target is still independently authorized.
    static func scopePath(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }
    static func normalized(_ url: URL) throws -> URL {
        guard url.isFileURL, url.user == nil, url.password == nil, url.port == nil,
              url.host == nil || url.host == "" || url.host == "localhost", url.query == nil, url.fragment == nil,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.utf8.contains(0) else { throw AutomationError.invalidArguments }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: false)
    }
}
