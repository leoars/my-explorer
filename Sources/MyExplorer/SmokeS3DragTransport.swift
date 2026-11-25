// SPDX-License-Identifier: Apache-2.0
#if !APP_STORE
import Foundation
import ExplorerCore

/// Models the two listings and conditional S3 requests used by the AppKit drag smoke.
actor SmokeS3DragTransport: CloudTransport {
    private let source = "clip.mov"
    private let folder = "Sub Pasta/"
    private let etag = "\"fixture\""
    private var objects = ["clip.mov": Data("example".utf8)]

    var didMoveFile: Bool {
        objects == [folder + source: Data("example".utf8)]
    }

    func send(_ request: URLRequest) async throws -> CloudResponse {
        try Task.checkCancellation()
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == "smoke-bucket.s3.us-east-1.amazonaws.com" else { throw CloudFailure(.invalidConfiguration) }
        let key = String(parts.path.dropFirst())
        switch request.httpMethod {
        case "GET":
            let prefix = parts.queryItems?.first { $0.name == "prefix" }?.value ?? ""
            var xml = "<ListBucketResult><IsTruncated>false</IsTruncated>"
            if prefix.isEmpty { xml += "<CommonPrefixes><Prefix>Sub Pasta/</Prefix></CommonPrefixes>" }
            for (key, bytes) in objects where key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/") {
                xml += "<Contents><Key>\(key)</Key><Size>\(bytes.count)</Size><ETag>\(etag)</ETag></Contents>"
            }
            return CloudResponse(statusCode: 200, body: Data((xml + "</ListBucketResult>").utf8))
        case "HEAD":
            guard let data = objects[key] else { return CloudResponse(statusCode: 404) }
            return CloudResponse(statusCode: 200, headers: ["Content-Length": String(data.count), "ETag": etag])
        case "PUT":
            let originalKey = key == source ? folder + source : source
            guard (key == source || key == folder + source), let data = objects[originalKey], objects[key] == nil,
                  request.value(forHTTPHeaderField: "If-None-Match") == "*",
                  request.value(forHTTPHeaderField: "x-amz-copy-source-if-match") == etag,
                  request.value(forHTTPHeaderField: "x-amz-copy-source") == "/smoke-bucket/" + originalKey.replacingOccurrences(of: " ", with: "%20")
            else { return CloudResponse(statusCode: 412) }
            objects[key] = data
            let xml = "<CopyObjectResult><ETag>\(etag)</ETag></CopyObjectResult>"
            return CloudResponse(statusCode: 200, body: Data(xml.utf8))
        case "DELETE":
            guard (key == source || key == folder + source), objects[key] != nil,
                  request.value(forHTTPHeaderField: "If-Match") == etag else { return CloudResponse(statusCode: 412) }
            objects.removeValue(forKey: key)
            return CloudResponse(statusCode: 204)
        default:
            throw CloudFailure(.io)
        }
    }

    func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        guard let url = request.url, let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.dropFirst(),
              key == folder + source, request.value(forHTTPHeaderField: "If-None-Match") == "*",
              objects[String(key)] == nil else { return CloudResponse(statusCode: 412) }
        objects[String(key)] = try Data(contentsOf: fileURL)
        return CloudResponse(statusCode: 200, headers: ["ETag": etag])
    }

    func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler?) async throws -> CloudResponse {
        guard let url = request.url, let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.dropFirst(),
              let data = objects[String(key)], request.value(forHTTPHeaderField: "If-Match") == etag
        else { return CloudResponse(statusCode: 412) }
        try data.write(to: fileURL, options: .withoutOverwriting)
        return CloudResponse(statusCode: 200, headers: ["ETag": etag, "Content-Length": String(data.count)])
    }
}
#endif
