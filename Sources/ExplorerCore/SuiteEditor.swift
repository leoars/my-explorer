// SPDX-License-Identifier: Apache-2.0
import Foundation
import UniformTypeIdentifiers

/// The other My Suite applications My Explorer can hand a file to for editing.
public enum SuiteEditor: String, CaseIterable, Sendable {
    case notepad, paint

    public var bundleIdentifier: String {
        switch self {
        case .notepad: return "local.mynotepad.editor"
        case .paint: return "local.mypaint.editor"
        }
    }

    /// Content types an application declares it can open, read from its Info.plist dictionary.
    public static func documentTypes(inInfoDictionary info: [String: Any]) -> [String] {
        let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
    }

    /// The same list for an application bundle on disk; empty when the bundle cannot be read.
    public static func documentTypes(ofApplicationAt application: URL) -> [String] {
        let url = application.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return documentTypes(inInfoDictionary: info)
    }

    /// Whether a file, judged by its extension, is of a type the declared content types cover.
    public static func supports(_ file: URL, documentTypes: [String]) -> Bool {
        let fileExtension = file.pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return documentTypes.contains { identifier in
            guard let declared = UTType(identifier) else { return false }
            if type.conforms(to: declared) { return true }
            // An editor of plain text also opens the other text formats (JSON, XML, HTML, YAML…),
            // which the system files under public.text. Rich text is left to its own editors.
            return declared == .plainText && type.conforms(to: .text) && !type.conforms(to: .rtf)
        }
    }

    /// Whether opening the file (a double click) should go to this editor instead of the usual
    /// way. Narrower than `supports`: only My Notepad takes a double click, and only on plain text
    /// files (.txt, .text, .log), so HTML, CSV, source code and the like keep their applications.
    /// Images stay with My Explorer's own viewer; My Paint is offered in the context menu.
    public func opensByDefault(_ file: URL, documentTypes: [String]) -> Bool {
        guard self == .notepad, SuiteEditor.supports(file, documentTypes: documentTypes) else { return false }
        let fileExtension = file.pathExtension.lowercased()
        return ["txt", "text", "log"].contains(fileExtension) || UTType(filenameExtension: fileExtension) == .plainText
    }
}
