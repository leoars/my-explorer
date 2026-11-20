// SPDX-License-Identifier: Apache-2.0
// Disposable, silent PNG/WAV/MOV fixtures for the native graphical smoke test.
import AppKit
import AVFoundation
import CoreVideo
import ImageIO

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let width = 640, height = 360
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(NSColor.systemBlue.cgColor)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.setFillColor(NSColor.systemYellow.cgColor)
context.fill(CGRect(x: 160, y: 80, width: 320, height: 200))
let picture = NSBitmapImageRep(cgImage: context.makeImage()!)
try picture.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("01-Imagem 日本語.png"))

// Three seconds of silent 16-bit mono PCM, no microphones or personal recordings.
let sampleRate = 44_100, sampleCount = sampleRate * 3, byteCount = sampleCount * 2
var wave = Data()
func ascii(_ string: String) { wave.append(contentsOf: string.utf8) }
func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
func dword(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
ascii("RIFF"); dword(UInt32(36 + byteCount)); ascii("WAVEfmt "); dword(16)
word(1); word(1); dword(UInt32(sampleRate)); dword(UInt32(sampleRate * 2)); word(2); word(16)
ascii("data"); dword(UInt32(byteCount)); wave.append(Data(repeating: 0, count: byteCount))
try wave.write(to: folder.appendingPathComponent("02-Áudio.wav"))

let movie = folder.appendingPathComponent("03-Vídeo.mov")
let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
])
guard writer.canAdd(input) else { fatalError("Cannot create video fixture") }
writer.add(input)
guard writer.startWriting() else { throw writer.error! }
writer.startSession(atSourceTime: .zero)
for frame in 0..<30 {
    let deadline = Date().addingTimeInterval(10)
    while !input.isReadyForMoreMediaData && Date() < deadline && writer.status == .writing {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { fatalError("Fixture encoder unavailable") }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { fatalError("No fixture pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let drawing = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    drawing.setFillColor(NSColor.systemBlue.cgColor)
    drawing.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawing.setFillColor(NSColor.systemYellow.cgColor)
    drawing.fill(CGRect(x: 10 + frame * 10, y: 100, width: 100, height: 100))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw writer.error! }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
guard done.wait(timeout: .now() + 20) == .success, writer.status == .completed else { fatalError("Video fixture failed") }
print("Generated silent media fixtures")

// Small-memory fixtures exercise full resolution beyond 4096px, the decode limit, and EXIF rotation.
let zoomFolder = folder.appendingPathComponent("Zoom", isDirectory: true)
try FileManager.default.createDirectory(at: zoomFolder, withIntermediateDirectories: false)
for (name, pixelsWide) in [("full-resolution.png", 4101), ("limited-preview.png", 17000)] {
    let strip = CGContext(data: nil, width: pixelsWide, height: 2, bitsPerComponent: 8,
        bytesPerRow: pixelsWide * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    strip.setFillColor(NSColor.systemGreen.cgColor)
    strip.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: 2))
    let bitmap = NSBitmapImageRep(cgImage: strip.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: zoomFolder.appendingPathComponent(name))
}
let rotated = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8,
    bytesPerRow: 120, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rotated.setFillColor(NSColor.systemOrange.cgColor)
rotated.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
let rotatedDestination = CGImageDestinationCreateWithURL(zoomFolder.appendingPathComponent("oriented.jpg") as CFURL,
    "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(rotatedDestination, rotated.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
guard CGImageDestinationFinalize(rotatedDestination) else { fatalError("Cannot write oriented fixture") }
