// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The list filter. Plain text matches any name that contains it; with a wildcard, as in Windows,
/// the pattern must match the whole name: `*` stands for any run of characters and `?` for one
/// (`*.pdf`, `IMG_????.*`). Case and accents are ignored either way.
public struct NameFilter: Sendable {
    private let query: String
    private let pattern: [Character]?

    public init(_ query: String) {
        // Plain text is used as typed (a leading space can be meant); a pattern ignores the spaces
        // around it, which are easy to type by accident.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        self.query = query
        pattern = trimmed.contains(where: { $0 == "*" || $0 == "?" }) ? Array(Self.fold(trimmed)) : nil
    }

    public var isEmpty: Bool { query.isEmpty }

    public func matches(_ name: String) -> Bool {
        guard !query.isEmpty else { return true }
        guard let pattern else { return name.localizedStandardContains(query) }
        return Self.glob(pattern, Array(Self.fold(name)))
    }

    private static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Iterative wildcard match with backtracking to the last `*`.
    private static func glob(_ pattern: [Character], _ name: [Character]) -> Bool {
        var p = 0, n = 0, star = -1, resume = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == name[n] {
                p += 1; n += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; resume = n; p += 1
            } else if star >= 0 {
                p = star + 1; resume += 1; n = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
