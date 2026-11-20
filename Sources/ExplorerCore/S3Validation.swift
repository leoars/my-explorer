// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import Darwin

public enum S3ValidationStatus: String, Codable, Sendable { case passed, failed, cancelled }
public enum S3ValidationStepStatus: String, Codable, Sendable { case passed, failed, deferred }
public enum S3ValidationReason: String, Codable, Sendable {
    case unsupportedProvider, cancelled, timedOut, authentication, permission, conflict, transport
    case invalidResponse, contentMismatch, unexpectedOutcome, unknownOutcome, changedVersion, unavailableEvidence
    case listingMalformedResponse, listingTooManyObjects, listingOutOfScope, listingPageLimit
    case listingRepeatedToken, listingMissingFixture, listingInsufficientPages
}
public struct S3ValidationStep: Codable, Sendable {
    public let id: String
    public let status: S3ValidationStepStatus
    public let reason: S3ValidationReason?
}
public struct S3ValidationCleanup: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case acknowledged, alreadyAbsent, preserved, residualUnknown }
    public let key: String
    public let status: Status
    public let reason: S3ValidationReason?
}
/// Safe diagnostic identifiers are generated fixture names, never raw server-returned keys or tokens.
public enum S3ValidationListingVariant: String, Codable, Sendable {
    case spacesAsPlus, plusAsSpace, spacesAsPercent20, percentEscapesRemaining, ampersandEscaped
}
public struct S3ValidationListPage: Codable, Sendable {
    public let pageNumber: Int
    public let objectCount: Int
    public let hasNextToken: Bool
    public let knownFixtures: [String]
    public let unknownKeyCount: Int
    public let outOfScopeCount: Int
    public let fixtureSpellingDiagnostics: [S3ValidationListingVariant]
}
/// Contains only generated fixture keys and fixed diagnostic enums, never connection metadata or raw errors.
public struct S3ValidationReport: Codable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let prefix: String
    public let status: S3ValidationStatus
    public let steps: [S3ValidationStep]
    public let cleanup: [S3ValidationCleanup]
    public let residualKeys: [String]
    public let listPages: [S3ValidationListPage]
    public var failed: Bool { status != .passed || !residualKeys.isEmpty }
}

/// Explicit opt-in network validation. Creates at most eight objects in one random, fixed namespace.
/// No bucket inventory, prefix deletion, unconditional write or unconditional delete is performed.
public struct S3ValidationRunner: Sendable {
    private let client: CloudStorageClient
    private let operationTimeout: Duration
    public let runID: UUID
    public var prefix: String { "my-explorer-validation/\(runID.uuidString.lowercased())/" }
    public init(client: CloudStorageClient, runID: UUID = UUID()) {
        self.client = client; self.runID = runID; operationTimeout = .seconds(15)
    }
    init(client: CloudStorageClient, operationTimeout: Duration) {
        self.client = client; self.runID = UUID(); self.operationTimeout = operationTimeout
    }
    public func run() async -> S3ValidationReport {
        await S3ValidationExecution(client: client, timeout: operationTimeout, runID: runID).run()
    }
    /// Separate opt-in experiment: an unknown remote outcome deliberately leaves a residual key.
    public func runUploadCancellation() async -> S3UploadCancellationReport {
        await S3ValidationExecution(client: client, timeout: operationTimeout, runID: runID).runUploadCancellation()
    }
}

private struct S3ValidationError: Error { let reason: S3ValidationReason }
private struct S3OwnedObject: Sendable { let version: String? }
private actor S3ValidationExecution {
    let client: CloudStorageClient
    let timeout: Duration
    let runID: UUID
    var prefix: String { "my-explorer-validation/\(runID.uuidString.lowercased())/" }
    var owned: [String: S3OwnedObject] = [:]
    var steps: [S3ValidationStep] = []
    var listPages: [S3ValidationListPage] = []
    var currentStep = "prepare"
    init(client: CloudStorageClient, timeout: Duration, runID: UUID) {
        self.client = client; self.timeout = timeout; self.runID = runID
    }

    func runUploadCancellation() async -> S3UploadCancellationReport {
        let key = prefix + "upload-cancellation.bin"
        let byteCount = 16 * 1024 * 1024
        let bytes = Data(repeating: 0xA7, count: byteCount)
        let expectedSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let cancellation = S3ValidationUploadProgress(total: Int64(byteCount))
        var observedCancellation = false
        var remoteOutcome: S3UploadCancellationRemoteOutcome = .notAttempted
        var failureReason: S3ValidationReason?
        var ownedTemporary: URL?
        defer {
            cancellation.clear()
            if let ownedTemporary { try? FileManager.default.removeItem(at: ownedTemporary) }
        }
        do {
            guard client.connection.provider == .s3 else { throw S3ValidationError(reason: .unsupportedProvider) }
            try Task.checkCancellation()
            let temporary = try Self.makeTemporaryDirectory()
            ownedTemporary = temporary
            let source = temporary.appendingPathComponent("upload-cancellation.bin")
            try bytes.write(to: source)
            // Register before dispatch; no subsequent HEAD can convert this unknown into ownership.
            owned[key] = .init(version: nil)
            remoteOutcome = .indeterminate
            let upload = Task { [client] in
                try await client.upload(fileURL: source, key: key, condition: .absent, progress: { progress in
                    cancellation.record(progress.completedBytes)
                })
            }
            cancellation.install { upload.cancel() }
            let object = try await call {
                try await withTaskCancellationHandler { try await upload.value } onCancel: { upload.cancel() }
            }
            guard object.key == key, let version = object.version, !version.isEmpty else {
                throw S3ValidationError(reason: .invalidResponse)
            }
            owned[key] = .init(version: version)
            remoteOutcome = .confirmed
            if !cancellation.requested { failureReason = .unexpectedOutcome }
        } catch {
            if let error = error as? CloudFailure, [.preconditionFailed, .conflict].contains(error.reason) {
                owned.removeValue(forKey: key)
                remoteOutcome = .rejected
            }
            let mapped = Self.reason(error)
            observedCancellation = mapped == .cancelled
            failureReason = mapped
        }
        let ledger = owned, client = client, scope = prefix, timeout = timeout
        let cleanup = await Task.detached {
            await Self.cleanup(ledger: ledger, client: client, prefix: scope, timeout: min(timeout, .seconds(5)))
        }.value
        let residual = cleanup.filter { $0.status == .preserved || $0.status == .residualUnknown }.map(\.key)
        return S3UploadCancellationReport(schemaVersion: 1, runID: runID, prefix: prefix, key: key,
            expectedByteCount: Int64(byteCount), expectedSHA256: expectedSHA256,
            progressBytesSent: cancellation.bytesSent, cancellationRequestedAtBytes: cancellation.requestedAtBytes,
            cancellationRequested: cancellation.requested,
            cancellationObserved: observedCancellation, remoteOutcome: remoteOutcome, reason: failureReason,
            cleanup: cleanup, residualKeys: residual)
    }

    func run() async -> S3ValidationReport {
        var status: S3ValidationStatus = .passed
        var ownedTemporary: URL?
        defer { if let ownedTemporary { try? FileManager.default.removeItem(at: ownedTemporary) } }
        do {
            guard client.connection.provider == .s3 else { throw S3ValidationError(reason: .unsupportedProvider) }
            let temporary = try Self.makeTemporaryDirectory()
            ownedTemporary = temporary
            let binary = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let unicode = Data("Olá 日本語 한국어 — + % # & spaces\n".utf8)
            let fixtures: [(String, String, Data)] = [
                ("binaryRoundTrip", "binary.bin", binary),
                ("emptyRoundTrip", "empty.dat", Data()),
                ("unicodeRoundTrip", "Olá 日本語 + % # &.txt", unicode)
            ]
            for (step, name, bytes) in fixtures {
                currentStep = step
                let source = temporary.appendingPathComponent(name)
                try bytes.write(to: source, options: .atomic)
                _ = try await put(source, key: prefix + name)
                try await verifyDownload(key: prefix + name, bytes: bytes, directory: temporary)
                passed()
            }
            currentStep = "stat"
            let binaryKey = prefix + "binary.bin"
            let object = try await call { [client] in try await client.stat(key: binaryKey) }
            guard object?.size == Int64(binary.count), object?.version == owned[binaryKey]?.version else {
                throw S3ValidationError(reason: .invalidResponse)
            }
            passed()

            let empty = temporary.appendingPathComponent("empty.dat")
            let folder = prefix + "folder/"
            currentStep = "folderListing"
            _ = try await put(empty, key: folder)
            _ = try await put(temporary.appendingPathComponent(fixtures[2].1), key: folder + "child.txt")
            let listPrefix = prefix
            var objects: [CloudObject] = []
            var token: String?, tokens: Set<String> = [], pages = 0
            repeat {
                let continuation = token
                let page: CloudPage
                do {
                    page = try await call { [client] in
                        try await client.list(prefix: listPrefix, continuationToken: continuation, pageSize: 2)
                    }
                } catch let error as CloudFailure where error.reason == .malformedResponse {
                    throw S3ValidationError(reason: .listingMalformedResponse)
                }
                pages += 1
                let expectedNames = fixtures.map { $0.1 } + ["folder/", "folder/child.txt"]
                let expectedKeys = Set(expectedNames.map { listPrefix + $0 })
                let known = page.objects.compactMap { object -> String? in
                    guard expectedKeys.contains(object.key) else { return nil }
                    // Emit the locally defined fixture spelling, never arbitrary response text.
                    return expectedNames.first { listPrefix + $0 == object.key }
                }
                let outside = page.objects.filter { !$0.key.hasPrefix(listPrefix) }.count
                var variants: Set<S3ValidationListingVariant> = []
                for object in page.objects where !expectedKeys.contains(object.key) && object.key.hasPrefix(listPrefix) {
                    for name in expectedNames {
                        let candidates: [(S3ValidationListingVariant, String)] = [
                            (.spacesAsPlus, name.replacingOccurrences(of: " ", with: "+")),
                            (.plusAsSpace, name.replacingOccurrences(of: "+", with: " ")),
                            (.spacesAsPercent20, name.replacingOccurrences(of: " ", with: "%20")),
                            (.percentEscapesRemaining, S3SignatureV4.encode(name, preservingSlashes: true)),
                            (.ampersandEscaped, name.replacingOccurrences(of: "&", with: "&amp;"))
                        ]
                        for (variant, candidate) in candidates where candidate != name && listPrefix + candidate == object.key {
                            variants.insert(variant)
                        }
                    }
                }
                listPages.append(.init(pageNumber: pages, objectCount: page.objects.count,
                                       hasNextToken: page.nextToken != nil, knownFixtures: known,
                                       unknownKeyCount: page.objects.count - known.count, outOfScopeCount: outside,
                                       fixtureSpellingDiagnostics: variants.sorted { $0.rawValue < $1.rawValue }))
                guard pages <= 8 else { throw S3ValidationError(reason: .listingPageLimit) }
                guard page.objects.count <= 2 else { throw S3ValidationError(reason: .listingTooManyObjects) }
                guard outside == 0 else { throw S3ValidationError(reason: .listingOutOfScope) }
                objects.append(contentsOf: page.objects)
                token = page.nextToken
                if let token, !tokens.insert(token).inserted { throw S3ValidationError(reason: .listingRepeatedToken) }
            } while token != nil
            guard pages > 1 else { throw S3ValidationError(reason: .listingInsufficientPages) }
            guard objects.contains(where: { $0.key == folder && $0.isDirectory }),
                  Set(objects.map(\.key)).isSuperset(of: Set(fixtures.map { listPrefix + $0.1 })) else {
                throw S3ValidationError(reason: .listingMissingFixture)
            }
            passed()
            steps.append(.init(id: "pagination", status: .passed, reason: nil))

            currentStep = "absentConflict"
            try await expectConflict { [self] in _ = try await put(empty, key: binaryKey) }
            passed()
            currentStep = "conditionalReplace"
            guard let initialVersion = owned[binaryKey]?.version else { throw S3ValidationError(reason: .invalidResponse) }
            let replacement = Data("changed fixture content".utf8)
            let replacementFile = temporary.appendingPathComponent("replacement.bin")
            try replacement.write(to: replacementFile)
            let newVersion = try await put(replacementFile, key: binaryKey, condition: .matches(initialVersion))
            guard newVersion != initialVersion else { throw S3ValidationError(reason: .invalidResponse) }
            try await verifyDownload(key: binaryKey, bytes: replacement, directory: temporary)
            passed()
            currentStep = "staleReplace"
            try await expectConflict { [self] in _ = try await put(empty, key: binaryKey, condition: .matches(initialVersion)) }
            try await verifyDownload(key: binaryKey, bytes: replacement, directory: temporary)
            passed()
            currentStep = "staleDownload"
            let staleDestination = temporary.appendingPathComponent("stale-download.bin")
            try await expectConflict { [self, client] in
                _ = try await call {
                    try await client.download(key: binaryKey, to: staleDestination, matchingVersion: initialVersion)
                }
            }
            guard !FileManager.default.fileExists(atPath: staleDestination.path) else {
                throw S3ValidationError(reason: .unexpectedOutcome)
            }
            passed()
            currentStep = "staleDelete"
            let stale = try await call { [client] in try await client.delete(key: binaryKey, matchingVersion: initialVersion) }
            guard stale == .changed else { throw S3ValidationError(reason: .unexpectedOutcome) }
            passed()

            currentStep = "sharedFolderDownload"
            let output = temporary.appendingPathComponent("download", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let service = StorageTransferService(clientFactory: { [client] id in
                guard id == client.connection.id else { throw CloudFailure(.invalidConfiguration) }
                return client
            }, limits: .init(entries: 16, depth: 4))
            let remoteFolder = RemoteLocation.url(connectionID: client.connection.id, key: folder)
            let result = try await call {
                try await service.copy(sources: [remoteFolder], to: output, resolveConflict: { _ in .cancel })
            }
            guard result.count == 1,
                  Self.digest(try Data(contentsOf: output.appendingPathComponent("folder/child.txt"))) == Self.digest(unicode) else {
                throw S3ValidationError(reason: .contentMismatch)
            }
            passed()

            try await validateSharedTransfers(temporary: temporary, unicode: unicode, service: service)
            try await validateDownloadCancellation(temporary: temporary)

            currentStep = "conditionalDelete"
            owned[binaryKey] = .init(version: nil)
            let outcome = try await call { [client] in try await client.delete(key: binaryKey, matchingVersion: newVersion) }
            switch outcome {
            case .acknowledged, .absent: owned.removeValue(forKey: binaryKey)
            case .changed: owned[binaryKey] = .init(version: newVersion)
            case .indeterminate: break // Never retry a delete with an unknown response.
            }
            guard outcome == .acknowledged else { throw S3ValidationError(reason: .unexpectedOutcome) }
            let removed = try await call { [client] in try await client.stat(key: binaryKey) }
            guard removed == nil else { throw S3ValidationError(reason: .unexpectedOutcome) }
            passed()
        } catch {
            let reason = Self.reason(error)
            status = reason == .cancelled ? .cancelled : .failed
            steps.append(.init(id: currentStep, status: .failed, reason: reason))
        }
        let ledger = owned, client = client, scope = prefix, timeout = timeout
        // Cancellation of the validation must not cancel cleanup. Its finite ledger has no more than eight keys.
        let cleanup = await Task.detached {
            await Self.cleanup(ledger: ledger, client: client, prefix: scope, timeout: min(timeout, .seconds(5)))
        }.value
        let residual = cleanup.filter { $0.status == .preserved || $0.status == .residualUnknown }.map(\.key)
        if status == .passed && !residual.isEmpty { status = .failed }
        return .init(schemaVersion: 1, runID: runID, prefix: prefix, status: status, steps: steps,
                     cleanup: cleanup, residualKeys: residual, listPages: listPages)
    }

    private func validateSharedTransfers(temporary: URL, unicode: Data, service: StorageTransferService) async throws {
    currentStep = "sharedFolderUpload"
    let sharedName = "shared-folder"
    let sharedLocal = temporary.appendingPathComponent(sharedName, isDirectory: true)
    try FileManager.default.createDirectory(at: sharedLocal, withIntermediateDirectories: false)
    try unicode.write(to: sharedLocal.appendingPathComponent("child.txt"))
    let sharedPrefix = prefix + sharedName + "/"
    let sharedKeys: Set<String> = [sharedPrefix, sharedPrefix + "child.txt"]
    let remoteBase = RemoteLocation.url(connectionID: client.connection.id, key: prefix)
    // Register the complete, tiny possible write set before starting a cancellable service.
    // A timed-out authorizer must not introduce an unreported key after cleanup snapshots the ledger.
    guard owned.count + sharedKeys.count <= 8 else { throw S3ValidationError(reason: .unexpectedOutcome) }
    for key in sharedKeys { owned[key] = .init(version: nil) }
    let sharedResults = try await call { [self] in
        try await service.copy(sources: [sharedLocal], to: remoteBase, resolveConflict: { _ in .cancel },
            authorize: { _, destination, replacing in
                try await self.registerSharedWrite(destination, replacing: replacing, allowed: sharedKeys)
            }, onUploadConfirmed: { destination, object in
                await self.recordReceipt(destination, object: object, allowed: sharedKeys)
            })
    }
    guard sharedResults.count == 1, sharedKeys.allSatisfy({ owned[$0]?.version != nil }) else {
        throw S3ValidationError(reason: .unavailableEvidence)
    }
    try await verifyDownload(key: sharedPrefix + "child.txt", bytes: unicode, directory: temporary)
    passed()

    currentStep = "sharedDeletion"
    let sharedRoot = RemoteLocation.url(connectionID: client.connection.id, key: sharedPrefix)
    var expected: [URL: String] = [:]
    for key in sharedKeys {
        expected[RemoteLocation.url(connectionID: client.connection.id, key: key)] = owned[key]!.version!
    }
    let expectedVersions = expected
    let deletion = StorageDeletionService(clientFactory: { [client] id in
        guard id == client.connection.id else { throw CloudFailure(.invalidConfiguration) }
        return client
    }, limits: .init(entries: 8, depth: 3))
    let plan = try await call {
        try await deletion.plan(sources: [sharedRoot], recursive: true, expectedRemoteVersions: expectedVersions)
    }
    let prior: [String: S3OwnedObject] = owned.filter { sharedKeys.contains($0.key) }
    for key in sharedKeys { owned[key] = .init(version: nil) }
    do {
        let removed = try await call {
            try await deletion.execute(planID: plan.id, authorizationCheck: { expectedVersions[$0] != nil })
        }
        guard Set(removed.completed) == Set(expectedVersions.keys) else {
            throw S3ValidationError(reason: .unexpectedOutcome)
        }
        for key in sharedKeys { owned.removeValue(forKey: key) }
    } catch let error as StorageDeletionFailure {
        let uncertain = Set(error.indeterminate.compactMap { RemoteLocation.parse($0)?.key })
        let completed = Set(error.completed.compactMap { RemoteLocation.parse($0)?.key })
        for key in sharedKeys {
            if completed.contains(key) { owned.removeValue(forKey: key) }
            else if !uncertain.contains(key) { owned[key] = prior[key] }
        }
        throw error
    }
    passed()

    }
    private func validateDownloadCancellation(temporary: URL) async throws {
    currentStep = "downloadCancellation"
    let large = Data(repeating: 0x5A, count: 8 * 1024 * 1024)
    let largeFile = temporary.appendingPathComponent("cancellation.bin")
    try large.write(to: largeFile)
    let largeKey = prefix + "cancellation.bin"
    let largeVersion = try await put(largeFile, key: largeKey)
    let cancelledDestination = temporary.appendingPathComponent("cancelled-download.bin")
    try await call { [client] in
        try await Self.cancelDownloadAfterProgress(client: client, key: largeKey, version: largeVersion,
                                                 destination: cancelledDestination)
    }
    guard !FileManager.default.fileExists(atPath: cancelledDestination.path) else {
        throw S3ValidationError(reason: .unexpectedOutcome)
    }
    passed()

    }

    private func registerSharedWrite(_ url: URL, replacing: Bool, allowed: Set<String>) throws {
        guard !replacing, let remote = RemoteLocation.parse(url), remote.connectionID == client.connection.id,
              allowed.contains(remote.key), remote.key.hasPrefix(prefix), owned.count < 8 || owned[remote.key] != nil else {
            throw S3ValidationError(reason: .unexpectedOutcome)
        }
        // The service may authorize a marker twice before its PUT; do not discard a delivered receipt.
        if owned[remote.key] == nil { owned[remote.key] = .init(version: nil) }
    }
    private func recordReceipt(_ url: URL, object: CloudObject, allowed: Set<String>) {
        guard let remote = RemoteLocation.parse(url), remote.connectionID == client.connection.id,
              remote.key == object.key, allowed.contains(object.key), object.key.hasPrefix(prefix),
              owned[object.key] != nil, let version = object.version, !version.isEmpty else { return }
        owned[object.key] = .init(version: version)
    }
    private nonisolated static func cancelDownloadAfterProgress(client: CloudStorageClient, key: String,
                                                                version: String, destination: URL) async throws {
        let cancellation = S3ValidationProgressCancellation()
        let download = Task {
            try await client.download(key: key, to: destination, matchingVersion: version, progress: { progress in
                if progress.completedBytes > 0 { cancellation.request() }
            })
        }
        cancellation.install { download.cancel() }
        defer { cancellation.clear() }
        do {
            _ = try await withTaskCancellationHandler { try await download.value } onCancel: { download.cancel() }
        } catch let error as CloudFailure where error.reason == .cancelled && cancellation.requested {
            return
        }
        throw S3ValidationError(reason: .unexpectedOutcome)
    }
    private nonisolated static func makeTemporaryDirectory() throws -> URL {
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("MyExplorer.S3Validation.XXXXXXXX").path.utf8CString)
        let path = template.withUnsafeMutableBufferPointer { pointer -> String? in
            guard let address = pointer.baseAddress, mkdtemp(address) != nil else { return nil }
            return String(cString: address)
        }
        guard let path else { throw S3ValidationError(reason: .transport) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private func passed() { steps.append(.init(id: currentStep, status: .passed, reason: nil)) }
    private func call<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await S3ValidationDeadline.perform(timeout: timeout, body)
    }
    private func put(_ file: URL, key: String, condition: CloudWriteCondition = .absent) async throws -> String {
        guard key.hasPrefix(prefix), key.count > prefix.count, owned.count < 8 || owned[key] != nil else {
            throw S3ValidationError(reason: .unexpectedOutcome)
        }
        let previous = owned[key]
        // Dispatch may succeed even when the response is lost. Never infer ownership from a later HEAD.
        owned[key] = .init(version: nil)
        do {
            let object = try await call { [client] in try await client.upload(fileURL: file, key: key, condition: condition) }
            guard object.key == key, let version = object.version, !version.isEmpty else {
                throw S3ValidationError(reason: .invalidResponse)
            }
            owned[key] = .init(version: version)
            return version
        } catch {
            if let failure = error as? CloudFailure, [.preconditionFailed, .conflict].contains(failure.reason) {
                // These responses confirm that this attempt did not write. Preserve prior ownership, if any.
                owned[key] = previous
            }
            throw error
        }
    }
    private func expectConflict(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch let failure as CloudFailure where [.preconditionFailed, .conflict].contains(failure.reason) { return }
        throw S3ValidationError(reason: .unexpectedOutcome)
    }
    private func verifyDownload(key: String, bytes: Data, directory: URL) async throws {
        let destination = directory.appendingPathComponent(UUID().uuidString)
        guard let version = owned[key]?.version else { throw S3ValidationError(reason: .unavailableEvidence) }
        _ = try await call { [client] in
            try await client.download(key: key, to: destination, matchingVersion: version)
        }
        guard Self.digest(try Data(contentsOf: destination)) == Self.digest(bytes) else {
            throw S3ValidationError(reason: .contentMismatch)
        }
    }
    private nonisolated static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private nonisolated static func cleanup(ledger: [String: S3OwnedObject], client: CloudStorageClient,
                                           prefix: String, timeout: Duration) async -> [S3ValidationCleanup] {
        var results: [S3ValidationCleanup] = []
        for (key, object) in ledger.sorted(by: { $0.key < $1.key }).prefix(8) {
            guard key.hasPrefix(prefix), let version = object.version else {
                results.append(.init(key: key, status: .residualUnknown, reason: .unknownOutcome)); continue
            }
            do {
                let result = try await S3ValidationDeadline.perform(timeout: timeout) {
                    try await client.delete(key: key, matchingVersion: version)
                }
                switch result {
                case .acknowledged: results.append(.init(key: key, status: .acknowledged, reason: nil))
                case .absent: results.append(.init(key: key, status: .alreadyAbsent, reason: nil))
                case .changed: results.append(.init(key: key, status: .preserved, reason: .changedVersion))
                case .indeterminate: results.append(.init(key: key, status: .residualUnknown, reason: .unknownOutcome))
                }
            } catch { results.append(.init(key: key, status: .residualUnknown, reason: reason(error))) }
        }
        return results
    }
    private nonisolated static func reason(_ error: any Error) -> S3ValidationReason {
        if let error = error as? S3ValidationError { return error.reason }
        if error is CancellationError { return .cancelled }
        if let error = error as? CloudFailure {
            switch error.reason {
            case .cancelled: return .cancelled
            case .authenticationRequired: return .authentication
            case .permissionDenied: return .permission
            case .preconditionFailed, .conflict: return .conflict
            case .malformedResponse: return .invalidResponse
            default: return .transport
            }
        }
        if let error = error as? StorageTransferFailure, error.reason == .cancelled { return .cancelled }
        return .transport
    }
}

/// Unstructured worker ownership intentionally prevents an uncooperative transport from holding
/// the report open. Late results are discarded; any dispatched write with no response remains residual.
private final class S3ValidationDeadline<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    static func perform(timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let state = S3ValidationDeadline<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending = state.lock.withLock { () -> Result<T, any Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let pending { continuation.resume(with: pending); return }
                let worker = Task.detached {
                    do { state.finish(.success(try await body())) }
                    catch { state.finish(.failure(error)) }
                }
                let timer = Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    state.finish(.failure(S3ValidationError(reason: .timedOut)))
                }
                let finished = state.lock.withLock {
                    if state.result != nil { return true }
                    state.worker = worker; state.timer = timer
                    return false
                }
                if finished { worker.cancel(); timer.cancel() }
            }
        } onCancel: { state.finish(.failure(S3ValidationError(reason: .cancelled))) }
    }
    private func finish(_ value: Result<T, any Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<T, any Error>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard result == nil else { return nil }
            result = value
            let pending = (continuation, worker, timer)
            continuation = nil; worker = nil; timer = nil
            return pending
        }
        guard let pending else { return }
        pending.1?.cancel(); pending.2?.cancel()
        pending.0?.resume(with: value)
    }
}

private final class S3ValidationProgressCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var didRequest = false
    var requested: Bool { lock.withLock { didRequest } }
    func install(_ action: @escaping @Sendable () -> Void) {
        let pending = lock.withLock { self.action = action; return didRequest }
        if pending { action() }
    }
    func clear() { lock.withLock { action = nil } }
    func request() {
        let action = lock.withLock { didRequest = true; return self.action }
        action?()
    }
}

/// Upload progress starts at zero during preparation; cancel only after the transport reports bytes sent.
private final class S3ValidationUploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var sent: Int64 = 0
    private var trigger: Int64 = 0
    private var didRequest = false
    private let total: Int64
    init(total: Int64) { self.total = total }
    var requestedAtBytes: Int64 { lock.withLock { trigger } }
    var bytesSent: Int64 { lock.withLock { sent } }
    var requested: Bool { lock.withLock { didRequest } }
    func install(_ action: @escaping @Sendable () -> Void) {
        let pending = lock.withLock { self.action = action; return didRequest }
        if pending { action() }
    }
    func record(_ count: Int64) {
        guard count > 0 else { return }
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            sent = max(sent, count)
            guard !didRequest, count < total else { return nil }
            didRequest = true
            trigger = count
            return action
        }
        callback?()
    }
    func clear() { lock.withLock { action = nil } }
}
