// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import ExplorerCore

/// Explicit developer entry point. Credentials stay in Keychain and are never accepted as arguments.
@MainActor
enum S3ValidationCommand {
    static func run(arguments: [String]) async -> Int32 {
        if arguments.first == "--import-s3-validation-credentials" { return await importCredentials(arguments) }
        let connections = CloudAccounts.shared.connections.filter { $0.provider == .s3 }
        if arguments.first == "--validate-s3-auth" { return await validateAuthentication(arguments, connections: connections) }
        if arguments.count == 3, arguments[0] == "--remove-s3-validation-connection",
           arguments[2] == "--confirm-test-connection", let id = UUID(uuidString: arguments[1]),
           let connection = connections.first(where: { $0.id == id }),
           connection.name == "My Explorer S3 validation", connection.bucket.hasPrefix("my-explorer-validation-") {
            do { try CloudAccounts.shared.remove(id); print("Removed local S3 validation connection and Keychain entry."); return 0 }
            catch { fputs("Could not remove the local test connection.\n", stderr); return 1 }
        }
        if arguments == ["--list-s3-validation-connections"] {
            struct ConnectionSummary: Encodable {
                let id: UUID
                let name: String
                let bucket: String
                let region: String
            }
            let summaries = connections.map {
                ConnectionSummary(id: $0.id, name: $0.name, bucket: $0.bucket, region: $0.region ?? "us-east-1")
            }
            if let data = try? JSONEncoder().encode(summaries) { print(String(decoding: data, as: UTF8.self)) }
            return 0
        }
        guard arguments.count == 6, ["--validate-s3", "--validate-s3-upload-cancellation"].contains(arguments[0]),
              let connectionID = UUID(uuidString: arguments[1]), arguments[2] == "--allow-test-writes",
              arguments[3] == "--report", arguments[4].hasPrefix("/"), arguments[5] == "--confirm-disposable-bucket",
              connections.contains(where: { $0.id == connectionID }) else {
            fputs("Usage: MyExplorer --list-s3-validation-connections\nMyExplorer --validate-s3 CONNECTION_UUID --allow-test-writes --report /absolute/new-report.json --confirm-disposable-bucket\nUse an existing S3 test connection saved in the app. Credentials are read from Keychain.\n", stderr)
            return 2
        }
        // Reserve a new report before contacting AWS; never overwrite an existing report or follow a symlink.
        let descriptor = open(arguments[4], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            fputs("Could not create the report. Use a new file in an existing local directory.\n", stderr)
            return 2
        }
        defer { close(descriptor) }
        let runID = UUID()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct StartedReport: Encodable {
            let schemaVersion = 1
            let status = "running"
            let runID: UUID
            let prefix: String
            let connectionID: UUID
            let note = "An unfinished report is not evidence of success or cleanup. Inspect the run prefix before removing anything."
        }
        do {
            let started = StartedReport(runID: runID, prefix: "my-explorer-validation/\(runID.uuidString.lowercased())/", connectionID: connectionID)
            try write(encoder.encode(started), to: descriptor)
            let client = try await CloudAccounts.shared.client(id: connectionID)
            let runner = S3ValidationRunner(client: client, runID: runID)
            if arguments[0] == "--validate-s3-upload-cancellation" {
                let report = await runner.runUploadCancellation()
                try write(encoder.encode(report), to: descriptor)
                print(report.failed ? "S3 UPLOAD CANCELLATION: inspect report and reconcile residual fixture keys." : "S3 UPLOAD CANCELLATION PASSED.")
                return report.failed ? 1 : 0
            }
            let report = await runner.run()
            try write(encoder.encode(report), to: descriptor)
            print(report.failed ? "S3 VALIDATION FAILED: inspect the report and any residual fixture keys." : "S3 VALIDATION PASSED: inspect the report for covered and deferred checks.")
            return report.failed ? 1 : 0
        } catch {
            // No raw NSError, request, signed URL or provider response is allowed into logs.
            let reason = (error as? CloudFailure)?.reason.rawValue ?? "localReportOrCredentialError"
            fputs("S3 VALIDATION FAILED: \(reason). No success claim; inspect the report before cleanup.\n", stderr)
            return 1
        }
    }

    private static func validateAuthentication(_ arguments: [String], connections: [CloudConnection]) async -> Int32 {
        guard arguments.count == 4, let id = UUID(uuidString: arguments[1]),
              connections.contains(where: { $0.id == id }), arguments[2] == "--report", arguments[3].hasPrefix("/") else {
            fputs("Usage: --validate-s3-auth CONNECTION_UUID --report /absolute/new-report.json\n", stderr); return 2
        }
        let fd = open(arguments[3], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { fputs("Use a new report file in an existing directory.\n", stderr); return 2 }
        defer { close(fd) }
        struct AuthReport: Encodable {
            let schemaVersion = 1
            var status = "running"
            var positiveRead = false
            var invalidSignatureRejected = false
            var deniedPrefixRejected = false
            let expiry = "not_tested_live"
        }
        var report = AuthReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var credentials: CloudCredentials?
        defer { credentials = nil; CloudAccounts.shared.clientFactory = nil }
        CloudAccounts.shared.clientFactory = { connection, value in
            credentials = value
            return try CloudStorageClient(connection: connection, credentials: value)
        }
        do {
            try write(encoder.encode(report), to: fd)
            let client = try await CloudAccounts.shared.client(id: id)
            _ = try await client.list(prefix: "my-explorer-validation/", pageSize: 1)
            report.positiveRead = true
            guard let original = credentials, let secret = original.secretAccessKey else { throw CloudFailure(.invalidConfiguration) }
            let invalid = try CloudStorageClient(connection: client.connection,
                credentials: CloudCredentials(accessKeyID: original.accessKeyID, secretAccessKey: secret + "INVALID", sessionToken: original.sessionToken))
            do { _ = try await invalid.list(prefix: "my-explorer-validation/", pageSize: 1) }
            catch let failure as CloudFailure where failure.reason == .authenticationRequired { report.invalidSignatureRejected = true }
            do { _ = try await client.list(prefix: "my-explorer-validation-denied/\(UUID().uuidString)/", pageSize: 1) }
            catch let failure as CloudFailure where failure.reason == .permissionDenied { report.deniedPrefixRejected = true }
            report.status = report.positiveRead && report.invalidSignatureRejected && report.deniedPrefixRejected ? "passed" : "failed"
            try write(encoder.encode(report), to: fd)
            print("S3 AUTH VALIDATION: \(report.status)")
            return report.status == "passed" ? 0 : 1
        } catch {
            report.status = "failed"
            try? write(encoder.encode(report), to: fd)
            fputs("S3 AUTH VALIDATION FAILED. No raw authentication diagnostics are logged.\n", stderr)
            return 1
        }
    }

    private static func importCredentials(_ arguments: [String]) async -> Int32 {
        guard arguments.count == 6, arguments[1].hasPrefix("/"), arguments[2] == "--bucket",
              arguments[3].hasPrefix("my-explorer-validation-"), arguments[4] == "--region" else {
            fputs("Usage: --import-s3-validation-credentials /absolute/private.json --bucket my-explorer-validation-NAME --region REGION\n", stderr)
            return 2
        }
        let fd = open(arguments[1], O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { fputs("Could not open the private credential file.\n", stderr); return 2 }
        defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16_384 else {
            fputs("Credential input must be an owned private regular file, mode 600, at most 16 KiB.\n", stderr)
            return 2
        }
        do {
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            guard data.count <= 16_384,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = json["AccessKey"] as? [String: Any],
                  let user = key["UserName"] as? String, user.hasPrefix("my-explorer-s3-validation-"),
                  let access = key["AccessKeyId"] as? String,
                  let secret = key["SecretAccessKey"] as? String else { throw CloudFailure(.invalidConfiguration) }
            let connection = CloudConnection(name: "My Explorer S3 validation", provider: .s3,
                                             bucket: arguments[3], region: arguments[5])
            let credentials = CloudCredentials(accessKeyID: access, secretAccessKey: secret)
            let client = try CloudStorageClient(connection: connection, credentials: credentials)
            _ = try await client.list(prefix: "my-explorer-validation/", pageSize: 1)
            try await CloudAccounts.shared.save(connection, credentials: credentials)
            print(connection.id.uuidString)
            return 0
        } catch {
            fputs("Could not import the test credentials. Check private file format, permissions and S3 access.\n", stderr)
            return 1
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw CloudFailure(.io) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CloudFailure(.io) }
                written += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else { throw CloudFailure(.io) }
    }
}
