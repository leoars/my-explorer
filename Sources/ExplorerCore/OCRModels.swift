// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct OCRRequest: Codable, Equatable, Sendable {
    public let url: URL
    public let languages: [String]
    /// Inclusive, one-based pages. Nil processes all pages (images have page 1).
    public let pages: ClosedRange<Int>?
    public init(url: URL, languages: [String] = [], pages: ClosedRange<Int>? = nil) {
        self.url = url; self.languages = languages; self.pages = pages
    }
}
public struct OCRPage: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case embeddedText, recognized }
    public let pageNumber: Int
    public let text: String
    public let source: Source
    public init(pageNumber: Int, text: String, source: Source) { self.pageNumber = pageNumber; self.text = text; self.source = source }
}
public struct OCRResult: Codable, Equatable, Sendable {
    public let pages: [OCRPage]
    public let engine: String
    /// Computed, not duplicated in Codable output; page text is the canonical wire representation.
    public var fullText: String { pages.map(\.text).joined(separator: "\n\n") }
    public init(pages: [OCRPage], engine: String = "apple-vision") { self.pages = pages; self.engine = engine }
}
public struct OCRProgress: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case preparing, reading, recognizing, completed }
    public let stage: Stage
    public let completedPages: Int
    public let totalPages: Int
    public init(stage: Stage, completedPages: Int, totalPages: Int) {
        self.stage = stage; self.completedPages = completedPages; self.totalPages = totalPages
    }
}
public struct OCRFailure: Error, Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case invalidRequest, unsupportedType, unavailable, needsDownload, permissionDenied, limitExceeded
        case cancelled, timedOut, recognitionFailed, sourceChanged, authorizationDenied, busy
    }
    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
}
public struct OCRLimits: Sendable {
    public let maximumFileBytes: Int64
    public let maximumPages: Int
    public let maximumImagePixels: Int
    public let maximumPDFPagePixels: Int
    public let maximumOutputBytes: Int
    public let timeoutSeconds: TimeInterval
    public init(maximumFileBytes: Int64 = 100 * 1024 * 1024, maximumPages: Int = 100,
                maximumImagePixels: Int = 40_000_000, maximumPDFPagePixels: Int = 12_000_000,
                maximumOutputBytes: Int = 128 * 1024, timeoutSeconds: TimeInterval = 120) {
        self.maximumFileBytes = min(maximumFileBytes, 100 * 1024 * 1024)
        self.maximumPages = min(maximumPages, 100)
        self.maximumImagePixels = min(maximumImagePixels, 40_000_000)
        self.maximumPDFPagePixels = min(maximumPDFPagePixels, 12_000_000)
        self.maximumOutputBytes = min(maximumOutputBytes, 128 * 1024)
        self.timeoutSeconds = timeoutSeconds.isFinite ? min(timeoutSeconds, 120) : 0
    }
    var valid: Bool { maximumFileBytes > 0 && maximumPages > 0 && maximumImagePixels > 0 && maximumPDFPagePixels > 0 && maximumOutputBytes > 0 && timeoutSeconds > 0 }
}
public protocol OCRReading: Sendable {
    func supportedLanguages() async throws -> [String]
    func recognize(_ request: OCRRequest, progress: (@Sendable (OCRProgress) -> Void)?,
                   authorizeURL: (@Sendable (URL) async throws -> Void)?) async throws -> OCRResult
}
