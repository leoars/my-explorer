// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import ExplorerCore

struct OperationInterruptionStoreTests {
    @Test @MainActor func persistsCodesAndRecoveryPathsUntilAcknowledged() throws {
        let suite = "MyExplorer.InterruptionTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OperationInterruptionStore(defaults: defaults)
        store.append(code: .partialOperation)
        store.append(code: .recoveryRequired, recoveryLocations: [URL(fileURLWithPath: "/fixture/recuperação 日本語")])
        let restored = OperationInterruptionStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(restored.pendingNotices.map(\.code) == [.partialOperation, .recoveryRequired])
        #expect(restored.pendingNotices.last?.recoveryPaths == ["/fixture/recuperação 日本語"])
        let shown = restored.pendingNotices
        #expect(restored.pendingNotices.count == 2)
        restored.acknowledge(ids: Set(shown.map(\.id)))
        #expect(restored.pendingNotices.isEmpty)
        #expect(store.pendingNotices.isEmpty)
    }

    @Test @MainActor func omitsRemoteCredentialsAndNonRecoveryLocations() throws {
        let suite = "MyExplorer.InterruptionTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OperationInterruptionStore(defaults: defaults)
        let remote = try #require(URL(string: "https://username:password@example.com/private?token=secret"))
        let local = URL(fileURLWithPath: "/fixture/recovery")
        let otherHost = try #require(URL(string: "file://remote/fixture/recovery"))
        let nulPath = try #require(URL(string: "file:///fixture/secret%00hidden"))
        store.append(code: .cloudCancellationUncertain, recoveryLocations: [local, remote])
        store.append(code: .recoveryRequired, recoveryLocations: [remote, otherHost, nulPath, local, local, URL(fileURLWithPath: "/")])
        #expect(store.pendingNotices.first?.recoveryPaths == [])
        #expect(store.pendingNotices.last?.recoveryPaths == [local.path])
        let data = try #require(defaults.data(forKey: OperationInterruptionStore.storageKey))
        let serialized = String(decoding: data, as: UTF8.self)
        #expect(!serialized.contains("username") && !serialized.contains("password") && !serialized.contains("secret"))
    }

    @Test @MainActor func boundsRetentionRecordsPathsAndCoalescesRepeatedNotices() throws {
        let suite = "MyExplorer.InterruptionTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OperationInterruptionStore(defaults: defaults, now: { date })
        store.append(code: .partialOperation); store.append(code: .partialOperation)
        #expect(store.pendingNotices.count == 1)
        for index in 0..<12 {
            store.append(code: .recoveryRequired, recoveryLocations: [URL(fileURLWithPath: "/fixture/\(index)")])
        }
        #expect(store.pendingNotices.count == 2)
        #expect(store.pendingNotices.last?.recoveryPaths.count == 12)
        store.append(code: .recoveryRequired, recoveryLocations: (0..<200).map { URL(fileURLWithPath: "/fixture/many/\($0)") })
        #expect(store.pendingNotices.last?.recoveryPaths.count == 128)
        #expect(store.pendingNotices.last?.additionalRecoveryLocations == true)
        date = date.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(store.pendingNotices.map(\.code) == [.recoveryRequired])
        #expect(store.pendingNotices.last?.recoveryPaths.count == 128)
    }

    @Test @MainActor func acknowledgementOfOlderNoticeCannotDiscardNewRecoveryLocations() throws {
        let suite = "MyExplorer.InterruptionTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OperationInterruptionStore(defaults: defaults)
        store.append(code: .recoveryRequired, recoveryLocations: [URL(fileURLWithPath: "/fixture/first")])
        let displayed = try #require(store.pendingNotices.first)
        store.append(code: .recoveryRequired, recoveryLocations: [URL(fileURLWithPath: "/fixture/second")])
        store.acknowledge(ids: [displayed.id])
        #expect(store.pendingNotices.first?.recoveryPaths == ["/fixture/first", "/fixture/second"])
        let updated = try #require(store.pendingNotices.first)
        store.acknowledge(ids: [updated.id])
        #expect(store.pendingNotices.isEmpty)
    }

    @Test @MainActor func malformedOversizedAndFuturePayloadsDoNotBreakStartup() throws {
        let suite = "MyExplorer.InterruptionTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OperationInterruptionStore(defaults: defaults, now: { date })
        defaults.set(Data("invalid json".utf8), forKey: OperationInterruptionStore.storageKey)
        #expect(store.pendingNotices.isEmpty)
        defaults.set(Data(repeating: 32, count: 1024 * 1024 + 1), forKey: OperationInterruptionStore.storageKey)
        #expect(store.pendingNotices.isEmpty)
        let future = OperationInterruptionStore(defaults: defaults, now: { date.addingTimeInterval(3600) })
        future.append(code: .deletionPartial)
        #expect(store.pendingNotices.isEmpty)
    }
}
