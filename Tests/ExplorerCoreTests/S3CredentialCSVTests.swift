// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct S3CredentialCSVTests {
    @Test func recognizesAWSExport() throws {
        let keys = try S3CredentialCSV.parse(Data("Access key ID,Secret access key\r\nid,fake/secret+=\r\n".utf8))
        #expect(keys.accessKeyID == "id")
        #expect(keys.secretAccessKey == "fake/secret+=")
        #expect(keys.sessionToken == nil)
    }

    @Test func acceptsQuotedFieldsBOMAndTemporaryCredentials() throws {
        let csv = "\u{FEFF}User name,aws_secret_access_key,AWS_SESSION_TOKEN,aws_access_key_id\r\n\"user, one\",\"fake\"\"secret\",session,id\r\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        try Data(csv.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = try S3CredentialCSV.read(from: url)
        #expect(keys.accessKeyID == "id")
        #expect(keys.secretAccessKey == "fake\"secret")
        #expect(keys.sessionToken == "session")
    }

    @Test func rejectsMalformedAmbiguousOrIncompleteExports() {
        let header = "Access key ID,Secret access key\n"
        for csv in [header, header + "id,", header + "id,s\nsecond,t", header + "id,\"unclosed",
                    header + "id,s,extra", "Access key ID,aws_access_key_id,Secret access key\na,b,c",
                    "User name,Password\na,b", header + "id," + String(repeating: "x", count: 270_000)] {
            #expect(throws: S3CredentialCSV.Failure.self) { try S3CredentialCSV.parse(Data(csv.utf8)) }
        }
    }
}
