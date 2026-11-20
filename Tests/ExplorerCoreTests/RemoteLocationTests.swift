// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct RemoteLocationTests {
    @Test func keysRoundTripWithoutLosingEscapingOrTrailingSlash() {
        let id = UUID()
        for key in ["", "pasta/", "pasta/日本語 # %.txt", "a%2Fb.txt", "a?b.txt"] {
            let url = RemoteLocation.url(connectionID: id, key: key)
            #expect(RemoteLocation.parse(url)?.key == key)
            #expect(RemoteLocation.parse(url)?.connectionID == id)
        }
        #expect(RemoteLocation.parse(URL(string: "myexplorer-cloud://\(id)/a?secret=example")!) == nil)
        #expect(RemoteLocation.parse(URL(string: "https://example.com/a")!) == nil)
    }
    @Test func historyDistinguishesConnectionsAndStopsAtRemoteRoot() {
        let first = RemoteLocation.url(connectionID: UUID())
        let second = RemoteLocation.url(connectionID: UUID())
        var history = NavigationHistory(url: first)
        history.goUp()
        #expect(history.current.url == first)
        #expect(history.back.isEmpty)
        history.visit(second)
        #expect(history.back.count == 1)
        history.goBack()
        #expect(history.current.url == first)
        let folder = RemoteLocation.url(connectionID: RemoteLocation.parse(first)!.connectionID, key: "docs/資料/")
        history.visit(folder)
        history.goUp()
        #expect(RemoteLocation.parse(history.current.url)?.key == "docs/")
        #expect(history.current.selectedPaths == [folder.explorerIdentity])
        history.goUp()
        #expect(history.current.url == first)
        history.goUp()
        #expect(history.current.url == first)
    }
    @Test func navigableLocationsHaveCanonicalFolderSuffix() {
        let id = UUID()
        var history = NavigationHistory(url: RemoteLocation.url(connectionID: id, key: "docs"))
        #expect(RemoteLocation.parse(history.current.url)?.key == "docs/")
        history.visit(RemoteLocation.url(connectionID: id, key: "docs/"))
        #expect(history.back.isEmpty)
        let file = RemoteLocation.url(connectionID: id, key: "docs/report.txt")
        #expect(RemoteLocation.parse(file)?.key == "docs/report.txt")
        #expect(file.explorerParent == history.current.url)
        #expect(file.explorerIdentity != RemoteLocation.url(connectionID: UUID(), key: "docs/report.txt").explorerIdentity)
    }
}
