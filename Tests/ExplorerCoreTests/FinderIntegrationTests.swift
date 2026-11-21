// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import ExplorerCore

struct FinderIntegrationTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func permissionsRespectIdentityAndAccessRules() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Report")
        try Data().write(to: file)
        #expect(chmod(file.path, 0o640) == 0)
        let acl = Process()
        acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
        acl.arguments = ["+a", "everyone allow readattr", file.path]
        try acl.run(); acl.waitUntilExit()
        #expect(acl.terminationStatus == 0)
        let initial = try ItemPermissions.inspect(file)
        #expect(initial.mode == 0o640)
        #expect(initial.canEdit)
        #expect(initial.acl != nil)
        try initial.apply(accessBits: 0o600, to: file)
        let changed = try ItemPermissions.inspect(file)
        #expect(changed.mode == 0o600)
        #expect(changed.acl == initial.acl)
        let replacement = root.appendingPathComponent("Other")
        try Data("other".utf8).write(to: replacement)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("Moved"))
        try FileManager.default.moveItem(at: replacement, to: file)
        #expect(throws: (any Error).self) { try changed.apply(accessBits: 0o644, to: file) }
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try ItemPermissions.inspect(link) }
    }

    @Test func plainLocalFileCannotBeEvictedUsingICloudAction() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Original")
        let original = Data("original".utf8)
        try original.write(to: file)
        #expect(throws: (any Error).self) { try ICloudAvailability.request(.removeDownload, at: file) }
        #expect(try Data(contentsOf: file) == original)
    }

    private func image(at url: URL, width: Int, height: Int) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
    }

    @Test func convertsRotatesAndOrdersPagesWithoutOverwriting() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("First.png"), b = root.appendingPathComponent("Second.png")
        try image(at: a, width: 12, height: 30)
        try image(at: b, width: 55, height: 18)
        let original = try Data(contentsOf: a)
        let rotated = root.appendingPathComponent("Rotated.png")
        try await ImageQuickAction.rotate.export([a], to: rotated)
        let src = try #require(CGImageSourceCreateWithURL(rotated as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(image.width == 30 && image.height == 12)
        let jpeg = root.appendingPathComponent("Result.jpg")
        try await ImageQuickAction.jpeg.export([a], to: jpeg)
        let jpegSource = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        #expect(CGImageSourceGetType(jpegSource) as String? == UTType.jpeg.identifier)
        await #expect(throws: (any Error).self) { try await ImageQuickAction.png.export([b], to: a) }
        #expect(try Data(contentsOf: a) == original)

        let pdf = root.appendingPathComponent("ordered.pdf")
        try await ImageQuickAction.pdf.export([b, a], to: pdf)
        let doc = try #require(PDFDocument(url: pdf))
        #expect(doc.pageCount == 2)
        #expect(doc.page(at: 0)?.bounds(for: .mediaBox).width == 55)
        #expect(doc.page(at: 1)?.bounds(for: .mediaBox).width == 12)
        let incomplete = root.appendingPathComponent("partial.pdf")
        await #expect(throws: (any Error).self) {
            try await ImageQuickAction.pdf.export([a, root.appendingPathComponent("gone.png")], to: incomplete)
        }
        #expect(!FileManager.default.fileExists(atPath: incomplete.path))
    }
}
