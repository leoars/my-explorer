// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct AddressCompletionTests {
    @Test func completesNavigableLocalFolders() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        for name in ["Café da manhã/東京", "Fake.app", ".private"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("catalog.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("Café da manhã"))
        func matches(_ draft: String) async throws -> [String] {
            try await AddressCompletion.suggestions(for: draft, relativeTo: root, showHidden: false)
        }
        #expect(try await matches("ca") == ["Café da manhã/"])
        #expect(try await matches("./") == ["./Café da manhã/", "./link/"])
        #expect(try await matches(root.path + "/Ca") == [root.path + "/Café da manhã/"])
        #expect(try await matches("link/東") == ["link/東京/"])
        #expect(try await matches("link/東京/").isEmpty)
        #expect(try await matches(".p") == [".private/"])
        #expect(try await matches("~") == ["~/"])
        #expect(try await matches("s3://bucket/").isEmpty)
        for index in 1...10 {
            try fm.createDirectory(at: root.appendingPathComponent("Item " + String(index)), withIntermediateDirectories: true)
        }
        #expect(try await matches("Item ") == (1...8).map { "Item " + String($0) + "/" })
        await #expect(throws: (any Error).self) { try await matches("missing/") }
    }
}
