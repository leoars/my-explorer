// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct SearchablePDFBatchRequest: Codable, Equatable, Sendable {
    public let sourceURLs: [URL]
    public let destinationDirectoryURL: URL
    public let languages: [String]
    public init(sourceURLs: [URL], destinationDirectoryURL: URL, languages: [String] = []) {
        self.sourceURLs = sourceURLs; self.destinationDirectoryURL = destinationDirectoryURL; self.languages = languages
    }
}
public struct SearchablePDFBatchItem: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case succeeded, failed, cancelled, notStarted, needsInput }
    public let sourceURL: URL
    public let destinationURL: URL?
    public let state: State
    public let reason: SearchablePDFFailure.Reason?
    public let receipt: SearchablePDFResult?
    public init(sourceURL: URL, destinationURL: URL? = nil, state: State,
                reason: SearchablePDFFailure.Reason? = nil, receipt: SearchablePDFResult? = nil) {
        self.sourceURL = sourceURL; self.destinationURL = destinationURL; self.state = state; self.reason = reason; self.receipt = receipt
    }
}
public struct SearchablePDFBatchResult: Codable, Equatable, Sendable {
    public let items: [SearchablePDFBatchItem]
    public init(items: [SearchablePDFBatchItem]) { self.items = items }
}
public struct SearchablePDFBatchProgress: Sendable {
    /// One-based current source index; completedResults contains only finalized entries.
    public let index: Int
    public let total: Int
    public let page: OCRProgress?
    public let completedResults: [SearchablePDFBatchItem]
    public init(index: Int, total: Int, page: OCRProgress? = nil, completedResults: [SearchablePDFBatchItem] = []) {
        self.index = index; self.total = total; self.page = page; self.completedResults = completedResults
    }
}
public protocol SearchablePDFBatchWriting: Sendable {
    func exportBatch(_ request: SearchablePDFBatchRequest, progress: (@Sendable (SearchablePDFBatchProgress) -> Void)?,
                     authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)?) async throws -> SearchablePDFBatchResult
}

/// A sequential coordinator. Individual exports retain their existing bounded workers and exclusive commit.
public struct SearchablePDFBatchService: SearchablePDFBatchWriting {
    private let writer: any SearchablePDFWriting
    public init(writer: any SearchablePDFWriting = SearchablePDFService()) { self.writer = writer }

    public func exportBatch(_ request: SearchablePDFBatchRequest,
                            progress: (@Sendable (SearchablePDFBatchProgress) -> Void)? = nil,
                            authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)? = nil) async throws -> SearchablePDFBatchResult {
        try Self.validate(request)
        let total = request.sourceURLs.count
        var items: [SearchablePDFBatchItem] = []
        var stopReason: SearchablePDFFailure.Reason?
        func report(_ index: Int) { progress?(.init(index: index, total: total, completedResults: items)) }
        func authorizeDirectory(_ url: URL) async throws {
            if Task.isCancelled { throw SearchablePDFFailure(.cancelled) }
            do { try await authorize?(url, .destination) }
            catch is CancellationError { throw SearchablePDFFailure(.cancelled) }
            catch { throw SearchablePDFFailure(.authorizationDenied) }
            if Task.isCancelled { throw SearchablePDFFailure(.cancelled) }
        }
        let directory: PDFDestination
        do {
            // Authorize before resolving/inspecting the destination directory. The random sentinel
            // is never created; it lets us reuse descriptor-safe destination metadata validation.
            try await authorizeDirectory(request.destinationDirectoryURL)
            let probe = request.destinationDirectoryURL.appendingPathComponent(".my-explorer-batch-probe-\(UUID()).pdf")
            directory = try await OCRExecutor.shared.run(timeout: 15) { try PDFDestination.inspect(probe, control: $0) }
            try await authorizeDirectory(directory.resolved.deletingLastPathComponent())
        } catch {
            let reason = SearchablePDFFailure(error).reason
            let result = SearchablePDFBatchResult(items: request.sourceURLs.map { .init(sourceURL: $0, state: .notStarted, reason: reason) })
            progress?(.init(index: 1, total: total, completedResults: result.items))
            return result
        }
        for (index, source) in request.sourceURLs.enumerated() {
            if stopReason == nil, Task.isCancelled { stopReason = .cancelled }
            if let stopReason {
                items.append(.init(sourceURL: source, state: .notStarted, reason: stopReason)); continue
            }
            report(index + 1)
            var destination: URL?
            do {
                let priorResults = items
                var receipt: SearchablePDFResult?
                for attempt in 1...100 {
                    if Task.isCancelled { throw SearchablePDFFailure(.cancelled) }
                    // Every retry is a new write attempt. A collision must not let the selected
                    // output directory silently change before the next generated filename.
                    destination = nil
                    _ = try await OCRExecutor.shared.run(timeout: 15) { control in try directory.validate(control); return true }
                    let name = Self.destinationName(for: source, attempt: attempt)
                    let target = try Self.appendingName(name, to: request.destinationDirectoryURL)
                    destination = target
                    do {
                        receipt = try await writer.export(.init(sourceURL: source, destinationURL: target, languages: request.languages),
                            progress: { page in progress?(.init(index: index + 1, total: total, page: page, completedResults: priorResults)) },
                            authorize: authorize)
                        break
                    } catch {
                        let failure = SearchablePDFFailure(error)
                        guard failure.reason == .destinationExists, attempt < 100 else { throw failure }
                    }
                }
                guard let receipt else { throw SearchablePDFFailure(.destinationExists) }
                // Publication may have won a cancellation race. Record it before considering cancellation.
                items.append(.init(sourceURL: source, destinationURL: receipt.destinationURL, state: .succeeded, receipt: receipt))
            } catch {
                let failure = SearchablePDFFailure(error)
                let state: SearchablePDFBatchItem.State = failure.reason == .publicationIndeterminate ? .needsInput : (failure.reason == .cancelled ? .cancelled : .failed)
                items.append(.init(sourceURL: source, destinationURL: destination, state: state, reason: failure.reason))
                if [.cancelled, .authorizationDenied, .publicationIndeterminate, .busy, .timedOut].contains(failure.reason) { stopReason = failure.reason }
                // A replaced destination directory invalidates the whole chosen output location.
                if destination == nil { stopReason = failure.reason }
            }
            report(index + 1)
        }
        // Include untouched entries and preserve receipts even if cancellation is now set.
        report(total)
        return .init(items: items)
    }

    private static func validate(_ request: SearchablePDFBatchRequest) throws {
        guard !request.sourceURLs.isEmpty, request.sourceURLs.count <= 50, request.languages.count <= 16,
              request.languages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }) else { throw SearchablePDFFailure(.invalidRequest) }
        do { try DirectoryReader.validateLocalURL(request.destinationDirectoryURL) }
        catch { throw SearchablePDFFailure(.invalidRequest) }
        var identities = Set<Data>()
        for source in request.sourceURLs {
            do { try DirectoryReader.validateLocalURL(source) }
            catch { throw SearchablePDFFailure(.invalidRequest) }
            // Match the path handed to open/lstat. Foundation preserves encoded separators in
            // file URL.path; manually percent-decoding would conflate them with actual directories.
            // The syntactic URL guard above already rejects encoded NUL before this conversion.
            let path = source.path
            guard path.hasPrefix("/") else { throw SearchablePDFFailure(.invalidRequest) }
            var parts: [Substring] = []
            for part in path.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { if !parts.isEmpty { parts.removeLast() } }
                else { parts.append(part) }
            }
            guard identities.insert(Data(("/" + parts.joined(separator: "/")).utf8)).inserted else { throw SearchablePDFFailure(.invalidRequest) }
        }
    }
    /// URL.appendingPathComponent normalizes file URL names to NFD on macOS. Preserve the
    /// requested UTF-8 spelling here; the exclusive filesystem operation decides collisions.
    private static func appendingName(_ name: String, to directory: URL) throws -> URL {
        var components = URLComponents(url: directory, resolvingAgainstBaseURL: false)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed), components != nil else { throw SearchablePDFFailure(.invalidRequest) }
        let prefix = components!.percentEncodedPath
        components!.percentEncodedPath = prefix + (prefix.hasSuffix("/") ? "" : "/") + encoded
        guard let target = components?.url else { throw SearchablePDFFailure(.invalidRequest) }
        return target
    }
    internal static func destinationName(for source: URL, attempt: Int) -> String {
        let suffix = attempt == 1 ? "-OCR.pdf" : "-OCR (\(attempt)).pdf"
        let maximum = 255 - suffix.utf8.count
        let original = source.deletingPathExtension().lastPathComponent
        var prefix = "", bytes = 0
        for scalar in original.unicodeScalars {
            let length = scalar.utf8.count
            if bytes + length > maximum { break }
            prefix.unicodeScalars.append(scalar); bytes += length
        }
        if prefix.isEmpty || prefix == "." || prefix == ".." { prefix = "Document" }
        return prefix + suffix
    }
}
