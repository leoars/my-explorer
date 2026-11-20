// SPDX-License-Identifier: Apache-2.0
import Foundation
import Vision
import PDFKit
import ImageIO
import UniformTypeIdentifiers

public struct OCRService: OCRReading {
    private let limits: OCRLimits
    private let executor: OCRExecutor
    public init(limits: OCRLimits = .init()) { self.limits = limits; executor = .shared }
    internal init(limits: OCRLimits = .init(), executor: OCRExecutor) { self.limits = limits; self.executor = executor }

    /// Lexical eligibility only; actual file availability/content is checked on workers.
    public static func canRecognize(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }
    /// Bounded metadata-only preflight for adapters; never hydrates placeholders or reads document content.
    public static func materializedURL(_ url: URL) async throws -> URL {
        try await OCRExecutor.shared.run(timeout: 15) { control in
            try OCRSource.inspect(url, limits: OCRLimits(), control: control).resolved
        }
    }
    public func supportedLanguages() async throws -> [String] {
        try await executor.run(timeout: 15) { control in
            try control.check()
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            do { return try request.supportedRecognitionLanguages() }
            catch { throw OCRFailure(.recognitionFailed) }
        }
    }
    public func recognize(_ request: OCRRequest, progress: (@Sendable (OCRProgress) -> Void)? = nil,
                          authorizeURL: (@Sendable (URL) async throws -> Void)? = nil) async throws -> OCRResult {
        guard limits.valid, request.languages.count <= 16,
              request.languages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }),
              request.pages.map({ $0.lowerBound >= 1 && $0.upperBound - $0.lowerBound < limits.maximumPages }) ?? true else { throw OCRFailure(.invalidRequest) }
        guard Self.canRecognize(request.url) else { throw OCRFailure(.unsupportedType) }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.timeoutSeconds
        func remaining() -> TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }
        func authorize(_ url: URL) async throws {
            if Task.isCancelled { throw OCRFailure(.cancelled) }
            do { try await authorizeURL?(url) }
            catch is CancellationError { throw OCRFailure(.cancelled) }
            catch { throw OCRFailure(.authorizationDenied) }
            if Task.isCancelled { throw OCRFailure(.cancelled) }
        }
        progress?(.init(stage: .preparing, completedPages: 0, totalPages: 0))
        try await authorize(request.url)
        let source = try await executor.run(timeout: remaining()) { try OCRSource.inspect(request.url, limits: limits, control: $0) }
        try await authorize(source.resolved)
        let result = try await executor.run(timeout: remaining()) { control in
            let snapshot = try source.snapshot(control)
            defer { snapshot.remove() }
            let result = try Self.read(snapshot.payload, original: request, limits: limits, control: control, progress: progress)
            try source.validate(control)
            return result
        }
        // Re-authorize after suspension, then verify any mutation caused by that callback.
        try await authorize(source.original)
        try await authorize(source.resolved)
        _ = try await executor.run(timeout: remaining()) { control in try source.validate(control); return true }
        // Authorization is checked after the last worker suspension as well.
        try await authorize(source.original)
        try await authorize(source.resolved)
        guard remaining() > 0 else { throw OCRFailure(.timedOut) }
        progress?(.init(stage: .completed, completedPages: result.pages.count, totalPages: result.pages.count))
        return result
    }

    private static func read(_ payload: URL, original: OCRRequest, limits: OCRLimits, control: OCRCancellation,
                             progress: (@Sendable (OCRProgress) -> Void)?) throws -> OCRResult {
        let languageRequest = VNRecognizeTextRequest(); languageRequest.recognitionLevel = .accurate
        let available: [String]
        do { available = try languageRequest.supportedRecognitionLanguages() }
        catch { throw OCRFailure(.recognitionFailed) }
        let languages = try recognitionLanguages(original.languages, supported: available)
        var pages: [OCRPage] = [], outputBytes = 0
        func append(_ text: String, number: Int, source: OCRPage.Source) throws {
            try control.check()
            let separator = pages.isEmpty ? 0 : 2
            guard text.utf8.count <= limits.maximumOutputBytes - outputBytes - separator else { throw OCRFailure(.limitExceeded) }
            outputBytes += text.utf8.count + separator
            pages.append(OCRPage(pageNumber: number, text: text, source: source))
        }
        if UTType(filenameExtension: original.url.pathExtension)?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: payload) else { throw OCRFailure(.recognitionFailed) }
            guard !document.isLocked, document.allowsCopying else { throw OCRFailure(.permissionDenied) }
            guard document.pageCount > 0 else { throw OCRFailure(.recognitionFailed) }
            let range = original.pages ?? 1...document.pageCount
            guard range.upperBound <= document.pageCount else { throw OCRFailure(.invalidRequest) }
            guard range.upperBound - range.lowerBound < limits.maximumPages else { throw OCRFailure(.limitExceeded) }
            for number in range {
                try control.check()
                try autoreleasepool {
                    guard let page = document.page(at: number - 1) else { throw OCRFailure(.recognitionFailed) }
                    progress?(.init(stage: .reading, completedPages: pages.count, totalPages: range.count))
                    try control.check()
                    if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try append(text, number: number, source: .embeddedText)
                    } else {
                        progress?(.init(stage: .recognizing, completedPages: pages.count, totalPages: range.count))
                        let image = try render(page, maximumPixels: limits.maximumPDFPagePixels, control: control)
                        let text = try recognizeImage(image, orientation: .up, languages: languages, automatic: original.languages.isEmpty, control: control)
                        try append(text, number: number, source: .recognized)
                    }
                }
            }
        } else {
            guard original.pages == nil || original.pages == 1...1 else { throw OCRFailure(.invalidRequest) }
            progress?(.init(stage: .reading, completedPages: 0, totalPages: 1))
            guard let source = CGImageSourceCreateWithURL(payload as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw OCRFailure(.recognitionFailed) }
            let imageCount = CGImageSourceGetCount(source)
            guard imageCount > 0 else { throw OCRFailure(.recognitionFailed) }
            guard imageCount == 1 else { throw OCRFailure(.unsupportedType) }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw OCRFailure(.recognitionFailed) }
            let w = width.doubleValue, h = height.doubleValue
            guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 32768, h <= 32768,
                  w * h <= Double(limits.maximumImagePixels) else { throw OCRFailure(.limitExceeded) }
            try control.check()
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw OCRFailure(.recognitionFailed) }
            guard Double(image.width) * Double(image.height) <= Double(limits.maximumImagePixels) else { throw OCRFailure(.limitExceeded) }
            let orientationValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
            progress?(.init(stage: .recognizing, completedPages: 0, totalPages: 1))
            let text = try recognizeImage(image, orientation: orientation, languages: languages, automatic: original.languages.isEmpty, control: control)
            try append(text, number: 1, source: .recognized)
        }
        return OCRResult(pages: pages)
    }

    internal static func recognitionLanguages(_ requested: [String], supported: [String]) throws -> [String] {
        if requested.isEmpty { return supported.filter { ["pt", "en", "es", "fr", "de", "ja", "ko", "it"].contains(String($0.prefix(2))) } }
        var result: [String] = []
        for language in requested {
            let canonical = language.replacingOccurrences(of: "_", with: "-").lowercased()
            guard let match = supported.first(where: { $0.lowercased() == canonical }) ?? supported.first(where: { $0.lowercased().hasPrefix(canonical + "-") }) else {
                throw OCRFailure(.invalidRequest)
            }
            if !result.contains(match) { result.append(match) }
        }
        return result
    }
    private static func recognizeImage(_ image: CGImage, orientation: CGImagePropertyOrientation, languages: [String],
                                       automatic: Bool, control: OCRCancellation) throws -> String {
        try control.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = automatic
        if !languages.isEmpty { request.recognitionLanguages = languages }
        control.setRequest(request); defer { control.setRequest(nil) }
        do { try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request]) }
        catch { try control.check(); throw OCRFailure(.recognitionFailed) }
        try control.check()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    internal static func render(_ page: PDFPage, maximumPixels: Int, control: OCRCancellation) throws -> CGImage {
        try control.check()
        guard let reference = page.pageRef else { throw OCRFailure(.recognitionFailed) }
        let bounds = reference.getBoxRect(.cropBox)
        var width = bounds.width, height = bounds.height
        if abs(reference.rotationAngle) % 180 == 90 { swap(&width, &height) }
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 10_000_000, height <= 10_000_000 else { throw OCRFailure(.limitExceeded) }
        let scale = min(200.0 / 72, sqrt(Double(maximumPixels) / (width * height)), 8192 / max(width, height))
        let w = max(1, Int(floor(width * scale))), h = max(1, Int(floor(height * scale)))
        guard w <= maximumPixels / h,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OCRFailure(.limitExceeded) }
        let target = CGRect(x: 0, y: 0, width: w, height: h)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        try control.check()
        guard let image = context.makeImage() else { throw OCRFailure(.recognitionFailed) }
        return image
    }
}
