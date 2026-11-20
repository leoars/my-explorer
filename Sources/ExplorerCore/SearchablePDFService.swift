// SPDX-License-Identifier: Apache-2.0
import Foundation
import PDFKit
import Vision
import ImageIO
import CPDFio
import CoreText
import UniformTypeIdentifiers
import Darwin

public struct SearchablePDFService: SearchablePDFWriting {
    private let limits: OCRLimits
    private let maximumOutputBytes: Int64
    private let executor: OCRExecutor
    public init(limits: OCRLimits = .init(), maximumOutputBytes: Int64 = 200 * 1024 * 1024) {
        self.limits = limits; self.maximumOutputBytes = min(maximumOutputBytes, 200 * 1024 * 1024); executor = .shared
    }
    public static func validatedDestinationURL(_ url: URL) async throws -> URL {
        do { return try await OCRExecutor.shared.run(timeout: 15) { try PDFDestination.inspect(url, control: $0).resolved } }
        catch { throw SearchablePDFFailure(error) }
    }
    public func export(_ request: SearchablePDFRequest, progress: (@Sendable (OCRProgress) -> Void)? = nil,
                       authorize: (@Sendable (URL, SearchablePDFLocationRole) async throws -> Void)? = nil) async throws -> SearchablePDFResult {
        do {
            guard limits.valid, maximumOutputBytes > 0, request.languages.count <= 16,
                  request.languages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }) else { throw SearchablePDFFailure(.invalidRequest) }
            guard OCRService.canRecognize(request.sourceURL) else { throw SearchablePDFFailure(.unsupportedType) }
            let lease = try PDFExportLease.acquire()
            let deadline = ProcessInfo.processInfo.systemUptime + limits.timeoutSeconds
            func remaining() -> TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }
            func authorizeLocation(_ url: URL, _ role: SearchablePDFLocationRole) async throws {
                if Task.isCancelled { throw SearchablePDFFailure(.cancelled) }
                do { try await authorize?(url, role) }
                catch is CancellationError { throw SearchablePDFFailure(.cancelled) }
                catch { throw SearchablePDFFailure(.authorizationDenied) }
                if Task.isCancelled { throw SearchablePDFFailure(.cancelled) }
                guard remaining() > 0 else { throw SearchablePDFFailure(.timedOut) }
            }
            progress?(.init(stage: .preparing, completedPages: 0, totalPages: 0))
            try await authorizeLocation(request.sourceURL, .source)
            try await authorizeLocation(request.destinationURL, .destination)
            let source = try await executor.run(timeout: remaining()) { try OCRSource.inspect(request.sourceURL, limits: limits, control: $0) }
            let destination = try await executor.run(timeout: remaining()) { try PDFDestination.inspect(request.destinationURL, control: $0) }
            try await authorizeLocation(source.resolved, .source)
            try await authorizeLocation(destination.resolved, .destination)
            let result = try await executor.run(timeout: remaining()) { control in
                let snapshot = try source.snapshot(control); defer { snapshot.remove() }
                let fd = try lease.prepare(destination, control: control); defer { close(fd) }
                let counts = try PDFSearchableRenderer.render(snapshot.payload, sourceURL: request.sourceURL, outputURL: lease.payloadURL!, fd: fd,
                    languages: request.languages, limits: limits, outputLimit: maximumOutputBytes, control: control, progress: progress)
                guard fsync(fd) == 0 else { throw SearchablePDFFailure(.unavailable) }
                try source.validate(control)
                try lease.seal(fd)
                return SearchablePDFResult(destinationURL: destination.resolved, pageCount: counts.total,
                                           recognizedPages: counts.recognized, textLayerPages: counts.existing)
            }
            try await authorizeLocation(source.original, .source)
            try await authorizeLocation(source.resolved, .source)
            try await authorizeLocation(destination.original, .destination)
            try await authorizeLocation(destination.resolved, .destination)
            let receipt = try await executor.publish(timeout: remaining()) { control, claim in
                try source.validate(control)
                try lease.publish(to: destination, control: control, claim: claim)
                return result
            }
            // No throwing suspension/check after publication: the receipt describes a real created file.
            progress?(.init(stage: .completed, completedPages: receipt.pageCount, totalPages: receipt.pageCount))
            return receipt
        } catch { throw SearchablePDFFailure(error) }
    }
}

internal struct PDFTextRegion: Sendable {
    let text: String
    let box: CGRect
    // Bottom-left, bottom-right and top-left retain the recognized baseline orientation.
    let corners: [CGPoint]?
    init(text: String, box: CGRect, corners: [CGPoint]? = nil) { self.text = text; self.box = box; self.corners = corners }
}
internal enum PDFSearchableRenderer {
    struct Counts: Sendable { var total = 0; var recognized = 0; var existing = 0 }
    static func render(_ payload: URL, sourceURL: URL, outputURL: URL, fd: Int32, languages requested: [String], limits: OCRLimits,
                       outputLimit: Int64, control: OCRCancellation, progress: (@Sendable (OCRProgress) -> Void)?) throws -> Counts {
        let probe = VNRecognizeTextRequest(); probe.recognitionLevel = .accurate
        let languages = try OCRService.recognitionLanguages(requested, supported: probe.supportedRecognitionLanguages())
        let isPDF = UTType(filenameExtension: sourceURL.pathExtension)?.conforms(to: .pdf) == true
        // Quartz writes only the pages that need OCR. Keep its temporary output inside
        // the private source snapshot so the final file can mix original and new pages.
        let renderedURL = payload.deletingLastPathComponent().appendingPathComponent("recognized.pdf")
        let renderFD = isPDF ? open(renderedURL.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600) : fd
        guard renderFD >= 0 else { throw SearchablePDFFailure(.unavailable) }
        defer { if isPDF { close(renderFD) } }
        var originalPages = IndexSet()
        let sink = PDFBoundedSink(fd: renderFD, maximumBytes: outputLimit, control: control)
        guard let consumer = sink.consumer(), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw SearchablePDFFailure(.unavailable) }
        var closed = false
        defer { if !closed { context.closePDF() } }
        var counts = Counts(), textBytes = 0
        var expected: [[String]] = [], pageBounds: [CGRect] = []
        func overlay(_ regions: [PDFTextRegion], in bounds: CGRect) throws {
            expected.append(regions.map(\.text))
            for region in regions {
                try control.check()
                guard region.text.utf8.count <= limits.maximumOutputBytes - textBytes else { throw SearchablePDFFailure(.limitExceeded) }
                textBytes += region.text.utf8.count
                try drawText(region, in: bounds, context: context)
            }
        }
        if isPDF {
            guard let document = PDFDocument(url: payload), let reference = document.documentRef else { throw SearchablePDFFailure(.recognitionFailed) }
            guard document.pageCount > 0, document.pageCount <= limits.maximumPages else { throw SearchablePDFFailure(.limitExceeded) }
            try validate(document, reference: reference, control: control)
            counts.total = document.pageCount
            for index in 0..<document.pageCount {
                try control.check()
                try autoreleasepool {
                    guard let page = document.page(at: index), let original = page.pageRef else { throw SearchablePDFFailure(.recognitionFailed) }
                    var bounds = original.getBoxRect(.cropBox)
                    guard bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                          bounds.width > 0, bounds.height > 0, bounds.width <= 100_000, bounds.height <= 100_000,
                          abs(original.rotationAngle) % 90 == 0 else { throw SearchablePDFFailure(.unsupportedDocument) }
                    if abs(original.rotationAngle) % 180 == 90 { bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width) }
                    else { bounds.origin = .zero }
                    progress?(.init(stage: .reading, completedPages: index, totalPages: counts.total))
                    if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        guard text.utf8.count <= limits.maximumOutputBytes - textBytes else { throw SearchablePDFFailure(.limitExceeded) }
                        textBytes += text.utf8.count
                        counts.existing += 1
                        originalPages.insert(index)
                        pageBounds.append(page.bounds(for: .mediaBox))
                        expected.append([text])
                        return
                    }
                    pageBounds.append(bounds)
                    begin(context, bounds: bounds)
                    context.saveGState()
                    context.concatenate(original.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(original); context.restoreGState()
                    progress?(.init(stage: .recognizing, completedPages: index, totalPages: counts.total))
                    let image = try OCRService.render(page, maximumPixels: limits.maximumPDFPagePixels, control: control)
                    try overlay(recognize(image, languages: languages, automatic: requested.isEmpty, control: control), in: bounds)
                    counts.recognized += 1
                    context.endPDFPage(); try sink.check()
                }
            }
        } else {
            let image = try orientedImage(payload, limits: limits, control: control)
            counts.total = 1
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            pageBounds.append(bounds)
            begin(context, bounds: bounds); context.draw(image, in: bounds)
            progress?(.init(stage: .recognizing, completedPages: 0, totalPages: 1))
            try overlay(recognize(image, languages: languages, automatic: requested.isEmpty, control: control), in: bounds)
            counts.recognized = 1; context.endPDFPage(); try sink.check()
        }
        context.closePDF(); closed = true; try sink.check(); try control.check()
        if isPDF {
            try assemble(original: payload, recognized: renderedURL, originalPages: originalPages,
                         count: counts.total, fd: fd, limit: outputLimit, control: control)
        }
        guard let generated = PDFDocument(url: outputURL), generated.pageCount == counts.total else { throw SearchablePDFFailure(.recognitionFailed) }
        for index in 0..<counts.total {
            try control.check()
            guard let page = generated.page(at: index), page.bounds(for: .mediaBox) == pageBounds[index] else { throw SearchablePDFFailure(.recognitionFailed) }
            if originalPages.contains(index) {
                guard let text = page.string, text.utf8.elementsEqual(expected[index][0].utf8) else {
                    throw SearchablePDFFailure(.recognitionFailed)
                }
                continue
            }
            let extracted = canonicalText(page.string ?? "")
            for text in expected[index] {
                guard extracted.contains(canonicalText(text)) else { throw SearchablePDFFailure(.recognitionFailed) }
            }
        }
        return counts
    }
    private static func assemble(original: URL, recognized: URL, originalPages: IndexSet, count: Int,
                                 fd: Int32, limit: Int64, control: OCRCancellation) throws {
        let onError: pdfio_error_cb_t = { _, _, _ in false }
        guard let source = pdfioFileOpen(original.path, nil, nil, onError, nil) else { throw SearchablePDFFailure(.unsupportedDocument) }
        defer { pdfioFileClose(source) }
        guard pdfioFileGetNumPages(source) == count else { throw SearchablePDFFailure(.recognitionFailed) }
        let recognizedCount = count - originalPages.count
        let scans = recognizedCount == 0 ? nil : pdfioFileOpen(recognized.path, nil, nil, onError, nil)
        defer { if let scans { pdfioFileClose(scans) } }
        guard recognizedCount == 0 || (scans != nil && pdfioFileGetNumPages(scans) == recognizedCount) else {
            throw SearchablePDFFailure(.recognitionFailed)
        }
        let sink = PDFBoundedSink(fd: fd, maximumBytes: limit, control: control)
        try withExtendedLifetime(sink) {
            let write: pdfio_output_cb_t = { pointer, buffer, length in
                guard let pointer, let buffer else { return -1 }
                let sink = Unmanaged<PDFBoundedSink>.fromOpaque(pointer).takeUnretainedValue()
                return sink.put(buffer, count: length) == length ? length : -1
            }
            let version = String(cString: pdfioFileGetVersion(source)).hasPrefix("2.") ? "2.0" : "1.7"
            guard let output = pdfioFileCreateOutput(write, Unmanaged.passUnretained(sink).toOpaque(), version, nil, nil, onError, nil) else {
                try sink.check()
                throw SearchablePDFFailure(.unavailable)
            }
            var closed = false
            defer { if !closed { pdfioFileClose(output) } }
            var scan = 0
            for index in 0..<count {
                try control.check()
                let existing = originalPages.contains(index)
                guard let page = pdfioFileGetPage(existing ? source : scans, existing ? index : scan),
                      pdfioPageCopy(output, page) else {
                    try sink.check()
                    throw SearchablePDFFailure(.recognitionFailed)
                }
                if !existing { scan += 1 }
            }
            let success = pdfioFileClose(output)
            closed = true
            try sink.check()
            guard success else { throw SearchablePDFFailure(.recognitionFailed) }
        }
    }

    private static func canonicalText(_ value: String) -> String {
        String(value.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    private static func validate(_ document: PDFDocument, reference: CGPDFDocument, control: OCRCancellation) throws {
        guard !document.isEncrypted, !document.isLocked, document.allowsCopying else { throw SearchablePDFFailure(.unsupportedDocument) }
        guard let catalog = reference.catalog else { throw SearchablePDFFailure(.unsupportedDocument) }
        for key in ["AcroForm", "Perms", "OpenAction", "AA", "OCProperties", "Names", "Outlines", "StructTreeRoot", "Threads", "Collection"] {
            var value: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog, key, &value) { throw SearchablePDFFailure(.unsupportedDocument) }
        }
        for index in 0..<document.pageCount {
            try control.check()
            guard let page = document.page(at: index), page.annotations.isEmpty else { throw SearchablePDFFailure(.unsupportedDocument) }
            if let dictionary = page.pageRef?.dictionary {
                for key in ["AA", "PresSteps", "VP", "Trans", "Dur"] {
                    var value: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(dictionary, key, &value) { throw SearchablePDFFailure(.unsupportedDocument) }
                }
            }
        }
    }
    private static func begin(_ context: CGContext, bounds: CGRect) {
        var rectangle = bounds
        let data = Data(bytes: &rectangle, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
    }
    static func drawText(_ region: PDFTextRegion, in bounds: CGRect, context: CGContext) throws {
        let box = region.box
        guard box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0, box.minX >= 0, box.minY >= 0, box.maxX <= 1.001, box.maxY <= 1.001 else { throw SearchablePDFFailure(.recognitionFailed) }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let string = NSAttributedString(string: region.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        guard width > 0, ascent + descent > 0 else { throw SearchablePDFFailure(.recognitionFailed) }
        let target = CGRect(x: bounds.minX + box.minX * bounds.width, y: bounds.minY + box.minY * bounds.height,
                            width: box.width * bounds.width, height: box.height * bounds.height)
        context.saveGState()
        if let corners = region.corners {
            guard corners.count == 3, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x <= 1.001 && $0.y <= 1.001 }) else {
                context.restoreGState(); throw SearchablePDFFailure(.recognitionFailed)
            }
            let points = corners.map { CGPoint(x: bounds.minX + $0.x * bounds.width, y: bounds.minY + $0.y * bounds.height) }
            let x = CGVector(dx: points[1].x - points[0].x, dy: points[1].y - points[0].y)
            let y = CGVector(dx: points[2].x - points[0].x, dy: points[2].y - points[0].y)
            guard abs(x.dx * y.dy - x.dy * y.dx) > 0.0001 else { context.restoreGState(); throw SearchablePDFFailure(.recognitionFailed) }
            context.concatenate(CGAffineTransform(a: x.dx / width, b: x.dy / width,
                c: y.dx / (ascent + descent), d: y.dy / (ascent + descent), tx: points[0].x, ty: points[0].y))
        } else {
            context.translateBy(x: target.minX, y: target.minY)
            context.scaleBy(x: target.width / width, y: target.height / (ascent + descent))
        }
        context.textMatrix = .identity; context.textPosition = CGPoint(x: 0, y: descent)
        context.setTextDrawingMode(.invisible); CTLineDraw(line, context); context.restoreGState()
    }
    private static func recognize(_ image: CGImage, languages: [String], automatic: Bool, control: OCRCancellation) throws -> [PDFTextRegion] {
        try control.check()
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = automatic
        if !languages.isEmpty { request.recognitionLanguages = languages }
        control.setRequest(request); defer { control.setRequest(nil) }
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { try control.check(); throw SearchablePDFFailure(.recognitionFailed) }
        try control.check()
        return (request.results ?? []).compactMap { item in
            guard let candidate = item.topCandidates(1).first else { return nil }
            let range = candidate.string.startIndex..<candidate.string.endIndex
            let bounds = (try? candidate.boundingBox(for: range)) ?? item
            return PDFTextRegion(text: candidate.string, box: bounds.boundingBox, corners: [bounds.bottomLeft, bounds.bottomRight, bounds.topLeft])
        }
    }
    private static func orientedImage(_ payload: URL, limits: OCRLimits, control: OCRCancellation) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(payload as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else { throw SearchablePDFFailure(.unsupportedType) }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw SearchablePDFFailure(.recognitionFailed) }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 32768, h <= 32768, w * h <= Double(limits.maximumImagePixels) else { throw SearchablePDFFailure(.limitExceeded) }
        try control.check()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h), kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              Double(image.width) * Double(image.height) <= Double(limits.maximumImagePixels) else { throw SearchablePDFFailure(.recognitionFailed) }
        try control.check(); return image
    }
}

private final class PDFBoundedSink {
    let fd: Int32
    let maximumBytes: Int64
    let control: OCRCancellation
    var written: Int64 = 0
    var failure: (any Error)?
    init(fd: Int32, maximumBytes: Int64, control: OCRCancellation) { self.fd = fd; self.maximumBytes = maximumBytes; self.control = control }
    func consumer() -> CGDataConsumer? {
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
            guard let info else { return 0 }
            return Unmanaged<PDFBoundedSink>.fromOpaque(info).takeUnretainedValue().put(buffer, count: count)
        }, releaseConsumer: { info in if let info { Unmanaged<PDFBoundedSink>.fromOpaque(info).release() } })
        let retained = Unmanaged.passRetained(self)
        guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else { retained.release(); return nil }
        return consumer
    }
    func put(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        guard failure == nil else { return 0 }
        do {
            try control.check()
            guard Int64(count) <= maximumBytes - written else { throw SearchablePDFFailure(.limitExceeded) }
            var offset = 0
            while offset < count {
                try control.check()
                let amount = write(fd, buffer.advanced(by: offset), count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw SearchablePDFFailure(.unavailable) }
                offset += amount; written += Int64(amount)
            }
            return count
        } catch { failure = error; return 0 }
    }
    func check() throws { if let failure { throw failure } }
}
