// SPDX-License-Identifier: Apache-2.0
import Foundation

public enum S3UploadCancellationRemoteOutcome: String, Codable, Sendable {
    case notAttempted, rejected, confirmed, indeterminate
}
/// A locally cancelled request does not establish whether S3 committed the object.
/// Without the original PUT receipt, the exact key remains residual for explicit reconciliation.
public struct S3UploadCancellationReport: Codable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let prefix: String
    public let key: String
    public let expectedByteCount: Int64
    public let expectedSHA256: String
    public let progressBytesSent: Int64
    public let cancellationRequestedAtBytes: Int64
    public let cancellationRequested: Bool
    public let cancellationObserved: Bool
    public let remoteOutcome: S3UploadCancellationRemoteOutcome
    public let reason: S3ValidationReason?
    public let cleanup: [S3ValidationCleanup]
    public let residualKeys: [String]
    public var failed: Bool { reason != nil || !cancellationRequested || !residualKeys.isEmpty }
}
