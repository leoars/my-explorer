// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerCore

struct GitHubUpdateReleaseTests {
    @Test func selectsNewerUniversalAssetIncludingPrereleases() throws {
        func release(_ name: String, draft: Bool = false) -> [String: Any] {
            ["draft": draft, "prerelease": true, "assets": [["id": 1, "size": 72, "state": "uploaded", "name": name]]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            release("MyExplorer-macOS-universal-100.dmg", draft: true),
            release("MyExplorer-macOS-universal-0101.dmg"), release("kit.zip"),
            release("MyExplorer-macOS-universal-25.dmg"), release("MyExplorer-macOS-universal-9.dmg")
        ])
        let releases = try JSONDecoder().decode([GitHubUpdateRelease].self, from: data)
        #expect(GitHubUpdateRelease.newest(in: releases, after: 10)?.build == 25)
        #expect(GitHubUpdateRelease.newest(in: releases, after: 25) == nil)
    }
}
