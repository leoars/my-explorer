// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Server history never contains identities, passwords, queries or fragments.
public enum SMBAddress {
    public static func parse(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let pieces = parts.percentEncodedPath.split(separator: "/")
        guard pieces.count <= 1, pieces.allSatisfy({
            guard let name = String($0).removingPercentEncoding else { return false }
            return name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
        }) else { return nil }
        var normalized = parts
        normalized.scheme = "smb"
        normalized.host = host.lowercased()
        normalized.percentEncodedPath = pieces.first.map { "/" + $0 } ?? ""
        return normalized.url
    }
}
