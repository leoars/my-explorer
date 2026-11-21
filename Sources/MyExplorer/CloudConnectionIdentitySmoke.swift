// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerCore

@MainActor
enum CloudConnectionIdentitySmoke {
    static func run() async throws {
        let suite = "MyExplorer.CloudIdentitySmoke." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw SmokeFailure.failed("Missing isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudAccounts(defaults: defaults, useKeychain: false)
        func connection(_ name: String, region: String? = nil, bucket: String = "smoke-bucket") -> CloudConnection {
            CloudConnection(name: name, provider: .s3, bucket: bucket, region: region)
        }
        let original = connection("First")
        let duplicate = connection("Second", region: "us-east-1")
        let credentials = CloudCredentials(accessKeyID: "EXAMPLEKEY", secretAccessKey: "not-a-real-key")
        let newSecret = CloudCredentials(accessKeyID: "EXAMPLEKEY", secretAccessKey: "different-secret")
        let newID = CloudCredentials(accessKeyID: "DIFFERENTKEY", secretAccessKey: "not-a-real-key")
        let token = CloudCredentials(accessKeyID: "EXAMPLEKEY", secretAccessKey: "not-a-real-key", sessionToken: "temporary-token")
        try await store.save(original, credentials: credentials)
        let matched = try await store.save(duplicate, credentials: credentials, reuseExistingS3: true)
        guard matched == original.id, store.connections == [original] else { throw SmokeFailure.failed("New S3 connection was duplicated") }

        let variants = [(connection("Other key"), newID), (connection("Other secret"), newSecret),
                        (connection("Temporary"), token), (connection("Other region", region: "sa-east-1"), credentials),
                        (connection("Other bucket", bucket: "other-smoke-bucket"), credentials)]
        for (candidate, value) in variants {
            guard try await store.save(candidate, credentials: value, reuseExistingS3: true) == candidate.id else {
                throw SmokeFailure.failed("Distinct S3 identity was reused")
            }
        }
        try await store.save(duplicate, credentials: credentials)
        let aliases = store.consolidateDuplicateS3Connections()
        guard aliases == [duplicate.id: original.id],
              store.connections == [original] + variants.map({ $0.0 }),
              store.consolidateDuplicateS3Connections() == aliases,
              CloudAccounts(defaults: defaults, useKeychain: false).connectionAliases == aliases else {
            throw SmokeFailure.failed("Legacy duplicate migration did not preserve the correct accounts")
        }
        _ = try await store.client(id: original.id)
        var edited = original
        edited.name = "Renamed"
        try await store.save(edited, credentials: credentials, reuseExistingS3: true)
        guard store.connections.first == edited else { throw SmokeFailure.failed("Explicit connection edit was lost") }

        var changed = variants[3].0
        changed.region = "us-east-1"
        let reused = try await store.save(changed, credentials: credentials, reuseExistingS3: true)
        guard reused == original.id, store.connections == [edited] + variants.map({ $0.0 }) else {
            throw SmokeFailure.failed("Editing into an existing S3 identity changed the old profiles")
        }

        async let one = store.save(connection("Repeat one"), credentials: credentials, reuseExistingS3: true)
        async let two = store.save(connection("Repeat two"), credentials: credentials, reuseExistingS3: true)
        let pair = try await (one, two)
        guard pair == (original.id, original.id), store.connections.count == 1 + variants.count else {
            throw SmokeFailure.failed("Concurrent Connect duplicated an S3 connection")
        }
        try store.remove(original.id)
        guard store.connections == variants.map({ $0.0 }), store.connectionAliases.isEmpty else {
            throw SmokeFailure.failed("Disconnect did not clean aliases or removed another identity")
        }
    }
}
