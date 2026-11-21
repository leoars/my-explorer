// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import ExplorerCore

struct SMBAddressTests {
    @Test func recentAddressesContainOnlyServerAndShare() {
        #expect(SMBAddress.parse("SMB://SERVER/Team%20Files/")?.absoluteString == "smb://server/Team%20Files")
        #expect(SMBAddress.parse("smb://example.net:445")?.host == "example.net")
        for input in ["smb://me:password@host/share", "smb://me@host", "smb://host/share?token=abc",
                      "smb://host/share#token", "smb://host/../", "smb://host/sh%2Fare",
                      "file:///Volumes/test", "smb:///nohost", "smb://host/share/subdirectory"] {
            #expect(SMBAddress.parse(input) == nil)
        }
    }
    @Test func systemVolumeIsNotEjectable() throws {
        #expect(try VolumeMount.identify(at: URL(fileURLWithPath: "/")).removal == nil)
    }
}
