// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct SearchablePDFRequest: Codable, Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let languages: [String]
    public init(sourceURL: URL, destinationURL: URL, languages: [String] = []) {
        self.sourceURL = sourceURL; self.destinationURL = destinationURL; self.languages = languages
    }
}
public enum SearchablePDFLocationRole: String, Codable, Sendable { case source, destination }
public struct SearchablePDFResult: Codable, Equatable, Sendable {
    public let destinationURL: URL
    public let pageCount: Int
    public let recognizedPages: Int
    public let textLayerPages: Int
    public let engine: String
    public init(destinationURL: URL, pageCount: Int, recognizedPages: Int, textLayerPages: Int, engine: String = "apple-vision") {
        self.destinationURL = destinationURL; self.pageCount = pageCount; self.recognizedPages = recognizedPages
        self.textLayerPages = textLayerPages; self.engine = engine
    }
}
public struct SearchablePDFFailure: Error, Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case invalidRequest, unsupportedType, unavailable, needsDownload, permissionDenied, limitExceeded
        case cancelled, timedOut, recognitionFailed, sourceChanged, authorizationDenied, busy
        case destinationExists, unsupportedDocument, publicationIndeterminate
    }
    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
    internal init(_ error: any Error) {
        if let failure = error as? Self { self = failure }
        else if let failure = error as? OCRFailure { self.init(Reason(rawValue: failure.reason.rawValue) ?? .unavailable) }
        else if error is CancellationError { self.init(.cancelled) }
        else { self.init(.unavailable) }
    }
}
public protocol SearchablePDFWriting: Sendable {
    func export(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)?,
                authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFResult
}
