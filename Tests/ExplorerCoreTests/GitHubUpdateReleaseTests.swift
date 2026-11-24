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

    @Test func readsTheVersionFromTheTag() throws {
        func release(_ tag: Any, _ build: Int) -> [String: Any] {
            ["draft": false, "tag_name": tag,
             "assets": [["id": build, "size": 72, "state": "uploaded", "name": "MyExplorer-macOS-universal-\(build).dmg"]]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            release("v1.0.1", 65), release("v1.0.2", 66), release("beta-x", 67), release("v1.0.2.1.5", 68)
        ])
        let releases = try JSONDecoder().decode([GitHubUpdateRelease].self, from: data)
        #expect(releases.map(\.version) == ["1.0.1", "1.0.2", nil, nil])
        let newest = GitHubUpdateRelease.newest(in: releases, after: 65)
        #expect(newest?.build == 68 && newest?.version == nil)
        #expect(GitHubUpdateRelease.newest(in: Array(releases.prefix(2)), after: 65)?.version == "1.0.2")
        let untagged = try JSONDecoder().decode([GitHubUpdateRelease].self,
            from: JSONSerialization.data(withJSONObject: [["draft": false, "assets": []]]))
        #expect(untagged.first?.version == nil)
    }
}
