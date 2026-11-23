// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerCore
import ExplorerLocalization

@MainActor
enum L10n {
    static var preferences = LanguagePreferences()
    static var current: Localization { Localization(language: preferences.selection) }
    static func text(_ key: String) -> String { current.text(key) }
    static func format(_ key: String, _ value: String) -> String { current.text(key, value) }
    static func format(_ key: String, _ first: String, _ second: String) -> String { current.text(key, first, second) }
    /// For texts with three or more values, written with numbered placeholders (%1$@, %2$@…).
    static func format(_ key: String, _ first: String, _ second: String, _ third: String, _ rest: String...) -> String {
        String(format: text(key), arguments: [first, second, third] + rest)
    }
    static func directoryError(_ failure: DirectoryFailure?) -> String? {
        guard let failure else { return nil }
        let path = URL(string: failure.path).flatMap { RemoteLocation.parse($0) == nil ? nil : CloudAccounts.shared.address(for: $0) } ?? failure.path
        return current.directoryError(failure, displayPath: path)
    }
}

extension Localization {
    func fileKind(_ entry: FileEntry) -> String {
        let kind = baseKind(entry)
        guard let state = entry.iCloudAvailability else { return kind }
        return kind + " · iCloud · " + text("icloud." + state.rawValue)
    }

    private func baseKind(_ entry: FileEntry) -> String {
        if entry.isSymbolicLink { return text("kind.symbolic_link") }
        if entry.canNavigate { return text("kind.folder") }
        if entry.isPackage { return text(entry.url.pathExtension.lowercased() == "app" ? "kind.application" : "kind.package") }
        if entry.url.pathExtension.isEmpty { return text("kind.file") }
        return text("kind.extension", entry.url.pathExtension.uppercased(with: locale))
    }

    func directoryError(_ failure: DirectoryFailure?, displayPath: String? = nil) -> String? {
        guard let failure else { return nil }
        if let reason = failure.cloudReason {
            return text("error.open_directory", displayPath ?? failure.path, text("cloud.error.\(reason.rawValue)"))
        }
        let key: String
        switch failure.reason {
        case .permission: key = "error.permission"
        case .notFound: key = "error.not_found"
        case .notDirectory: key = "error.not_directory"
        case .other: key = "error.generic"
        }
        return text("error.open_directory", displayPath ?? failure.path, text(key))
    }
}
