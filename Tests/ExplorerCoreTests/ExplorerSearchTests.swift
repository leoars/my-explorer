// SPDX-License-Identifier: Apache-2.0
import AppKit
import Foundation
import Testing
@testable import ExplorerCore

struct ExplorerSearchTests {
    @Test func walkUsesFullOriginsAndRespectsBoundaries() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        for directory in ["A/B", "C/B", "Private.myexplorervault", "Scratch"] {
            try manager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(directory + "/Relatório.PDF"))
        }
        let journal = root.appendingPathComponent("Scratch")
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journal.path)
        try LocalTransferRecovery.mark(journal)
        try manager.createSymbolicLink(at: root.appendingPathComponent("Cycle"), withDestinationURL: root)
        var spec = ExplorerSearchSpec(folder: root)
        spec.scope = .walkFolder
        spec.name = "relatorio"
        spec.fileExtension = "pdf"
        spec.modified = .lastWeek
        let results = try await spec.walk()
        #expect(Set(results.urls.map(\.path)) == Set(["A/B", "C/B"].map { root.appendingPathComponent($0 + "/Relatório.PDF").path }))
        #expect(!results.truncated)
        #expect(try await spec.walk(limit: 1).truncated)
        #expect(!ExplorerSearchSpec.mayShow(root.appendingPathComponent("Private.myexplorervault/Relatório.PDF")))
        #expect(!ExplorerSearchSpec.mayShow(root.appendingPathComponent("Scratch/Relatório.PDF")))
        spec.content = "private"
        await #expect(throws: (any Error).self) { try await spec.walk() }
    }

    @Test func tagsSurviveSeparateReadsAndRemovalPreservesOtherTags() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FinderTags.change("Trabalho", add: true, at: file)
        try FinderTags.change("Pessoal", add: true, at: file)
        try FinderTags.change("trabalho", add: true, at: file)
        #expect(Set(try FinderTags.read(file)) == ["Trabalho", "Pessoal"])
        try FinderTags.change("Trabalho", add: false, at: file)
        #expect(try FinderTags.read(file) == ["Pessoal"])
        #expect(throws: (any Error).self) { try FinderTags.change(" ", add: true, at: file) }
    }

    @Test @MainActor func savesCriteriaAndScopesWithoutCachingResults() throws {
        let suite = "MyExplorer.SearchTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var criteria = ExplorerSearchSpec(folder: URL(fileURLWithPath: "/"))
        criteria.scope = .computer
        criteria.tag = "Work"
        criteria.fileExtension = "pdf"
        criteria.modified = .lastMonth
        let saved = ExplorerSavedSearch(title: "Contracts", spec: criteria)
        try ExplorerSearchLibrary(defaults: defaults).add(saved)
        let restored = ExplorerSearchLibrary(defaults: defaults)
        #expect(restored.searches == [saved])
        try restored.remove(saved.id)
        #expect(restored.searches.isEmpty)
    }

    @Test @MainActor func finderSavedSearchUsesTheNativeOpenPath() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Documents.savedSearch")
        let query: [String: Any] = ["RawQuery": "kMDItemFSName == '*.pdf'cd",
                                    "SearchCriteria": ["FXScopeArrayOfPaths": [folder.path]]]
        try PropertyListSerialization.data(fromPropertyList: query, format: .xml, options: 0).write(to: file)
        let entry = FileEntry(url: file, name: file.lastPathComponent, isDirectory: false)
        #expect(!entry.canNavigate)
        #expect(MediaKind.detect(entry) == nil)
        let handler = try #require(NSWorkspace.shared.urlForApplication(toOpen: file))
        #expect(Bundle(url: handler)?.bundleIdentifier == "com.apple.finder")
    }

    @Test func spotlightCriteriaCombineWithoutParsingUserInputAsSyntax() {
        var spec = ExplorerSearchSpec(folder: URL(fileURLWithPath: "/"))
        spec.name = "a'b"
        spec.fileExtension = "pdf"
        spec.content = "resume"
        spec.tag = "Work"
        let document: [String: Any] = ["kMDItemFSName": "A'B.PDF", "kMDItemTextContent": "Résumé", "kMDItemUserTags": ["Work"]]
        #expect(spec.predicate().evaluate(with: document))
        spec.tag = "Personal"
        #expect(!spec.predicate().evaluate(with: document))
    }
}
