// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

/// Outside the App Sandbox (the direct build, and these tests) the real home folder is the one
/// Foundation reports, so nothing changes; the sandboxed case is checked by launching the
/// App Store build (docs/APP-STORE.md).
struct RealHomeTests {
    @Test func outsideTheSandboxMatchesFoundation() {
        #expect(!RealHome.isSandboxed)
        #expect(RealHome.url == FileManager.default.homeDirectoryForCurrentUser)
        for text in ["~", "~/", "~/Documents", "~/Documents/", "/tmp/a", "relative/b", "~root"] {
            #expect(RealHome.expandingTilde(text) == (text as NSString).expandingTildeInPath)
        }
    }

    @Test func addressesWithTildeResolveInTheHomeFolder() {
        let current = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #expect(AddressParser.resolve("~/Desktop", relativeTo: current)?.path == RealHome.url.appendingPathComponent("Desktop").path)
    }
}

/// Photos imported from a device go to the real Pictures folder, never the container's.
struct RealHomePicturesTests {
    @Test func picturesIsInTheRealHome() {
        #expect(RealHome.pictures(in: URL(fileURLWithPath: "/Users/ana", isDirectory: true)).path == "/Users/ana/Pictures")
        #expect(RealHome.pictures.path == FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.path)
    }
}
