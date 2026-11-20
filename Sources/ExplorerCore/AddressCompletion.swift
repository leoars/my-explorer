// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum AddressCompletion {
    public static func suggestions(for draft: String, relativeTo base: URL, showHidden: Bool,
                                   reader: any DirectoryReading = DirectoryReader(purpose: .background)) async throws -> [String] {
        guard !draft.isEmpty, !draft.contains("://"), !draft.hasPrefix("file:") else { return [] }
        if draft == "~" { return ["~/"] }
        let split = draft.lastIndex(of: "/").map { draft.index(after: $0) } ?? draft.startIndex
        let parent = String(draft[..<split])
        let prefix = String(draft[split...])
        guard let directory = AddressParser.resolve(parent.isEmpty ? "." : parent, relativeTo: base),
              directory.isFileURL else { return [] }
        let entries = try await reader.entries(at: directory, showHidden: showHidden || prefix.hasPrefix("."))
        try Task.checkCancellation()
        return entries.lazy.filter {
            $0.canNavigate && (prefix.isEmpty || $0.name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil)
        }.prefix(8).map { parent + $0.name + "/" }
    }
}
