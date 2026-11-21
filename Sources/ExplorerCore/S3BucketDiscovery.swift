// SPDX-License-Identifier: Apache-2.0
import Foundation

/// ListBuckets enumerates owned general-purpose buckets. Only a successful root listing qualifies
/// a bucket for the Explorer picker. Cross-account buckets may still be entered manually.
public struct S3BucketDiscovery: Sendable {
    public struct Bucket: Equatable, Sendable {
        public let name: String
        public let region: String
        public init(name: String, region: String) { self.name = name; self.region = region }
    }
    public struct Result: Sendable {
        public let buckets: [Bucket]
        public let isPartial: Bool
        public init(buckets: [Bucket], isPartial: Bool) { self.buckets = buckets; self.isPartial = isPartial }
    }

    private let transport: any CloudTransport
    public init() {
        // Never forward a signed request. A region hint can cause a newly signed request to AWS.
        transport = URLSessionCloudTransport(configuration: .ephemeral, returnRedirects: true)
    }
    init(transport: any CloudTransport) { self.transport = transport }

    public func discover(credentials: CloudCredentials, region: String) async throws -> Result {
        try S3CloudBackend.validate(credentials, region: region)
        var token: String?
        var tokens = Set<String>(), names = Set<String>()
        var verified: [Bucket] = []
        var partial = false
        repeat {
            try Task.checkCancellation()
            let page: DiscoveryPage
            do {
                let request = try listRequest(region: region, credentials: credentials, token: token)
                let response = try await transport.send(request)
                try CloudStorageClient.checkStatus(response, provider: .s3)
                page = try DiscoveryPage(response.body, defaultRegion: region)
            } catch {
                try Task.checkCancellation()
                if let failure = error as? CloudFailure, [.authenticationRequired, .cancelled].contains(failure.reason) { throw error }
                guard token != nil else { throw error }
                partial = true
                break
            }
            var candidates = page.buckets.filter { names.insert($0.name).inserted }.makeIterator()
            try await withThrowingTaskGroup(of: Probe.self) { group in
                func enqueue() {
                    if let bucket = candidates.next() {
                        group.addTask { try await probe(bucket, credentials: credentials, initialRegion: region) }
                    }
                }
                for _ in 0..<4 { enqueue() }
                while let outcome = try await group.next() {
                    try Task.checkCancellation()
                    switch outcome {
                    case .available(let bucket): verified.append(bucket)
                    case .unknown: partial = true
                    case .unavailable: break
                    }
                    enqueue()
                }
            }
            token = page.token
            if let token, !tokens.insert(token).inserted { partial = true; break }
        } while token != nil
        try Task.checkCancellation()
        return Result(buckets: verified.sorted { $0.name < $1.name }, isPartial: partial)
    }

    private func listRequest(region: String, credentials: CloudCredentials, token: String?) throws -> URLRequest {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "s3." + region + (region.hasPrefix("cn-") ? ".amazonaws.com.cn" : ".amazonaws.com")
        url.path = "/"
        var query = [("max-buckets", "100")]
        if let token { query.append(("continuation-token", token)) }
        url.percentEncodedQuery = S3SignatureV4.canonicalQuery(query)
        guard let endpoint = url.url, let id = credentials.accessKeyID, let secret = credentials.secretAccessKey else {
            throw CloudFailure(.invalidConfiguration)
        }
        return try S3SignatureV4.sign(URLRequest(url: endpoint), accessKeyID: id, secretAccessKey: secret,
                                      sessionToken: credentials.sessionToken, region: region, date: Date())
    }

    private enum Probe: Sendable { case available(Bucket), unavailable, unknown }

    private func probe(_ bucket: Bucket, credentials: CloudCredentials, initialRegion: String) async throws -> Probe {
        var region = bucket.region
        do {
            for attempt in 0...1 {
                try Task.checkCancellation()
                guard Self.partition(region) == Self.partition(initialRegion) else { return .unknown }
                let connection = CloudConnection(name: bucket.name, provider: .s3, bucket: bucket.name, region: region)
                let backend = try S3CloudBackend(connection: connection, credentials: credentials)
                let request = try backend.listRequest(prefix: "", continuationToken: nil, pageSize: 1)
                let response = try await transport.send(request)
                try Task.checkCancellation()
                if attempt == 0, [301, 307, 400].contains(response.statusCode),
                   let hint = response.header("x-amz-bucket-region"), hint != region,
                   S3ErrorResponse.reason(for: response) == nil {
                    region = hint
                    continue
                }
                try CloudStorageClient.checkStatus(response, provider: .s3)
                _ = try backend.parseList(response)
                return .available(Bucket(name: bucket.name, region: region))
            }
        } catch {
            try Task.checkCancellation()
            if let failure = error as? CloudFailure {
                switch failure.reason {
                case .authenticationRequired, .cancelled: throw failure
                case .notFound, .permissionDenied: return .unavailable
                default: break
                }
            }
        }
        return .unknown
    }

    private static func partition(_ region: String) -> String {
        if region.hasPrefix("cn-") { return "aws-cn" }
        if region.hasPrefix("us-gov-") { return "aws-us-gov" }
        return "aws"
    }

    private struct DiscoveryPage {
        let buckets: [Bucket]
        let token: String?

        init(_ data: Data, defaultRegion: String) throws {
            guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
                  !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY"), !data.contains(0),
                  let root = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]).rootElement(),
                  root.name == "ListAllMyBucketsResult",
                  root.elements(forName: "Buckets").count == 1,
                  let list = root.elements(forName: "Buckets").first else { throw CloudFailure(.malformedResponse) }
            let entries = list.elements(forName: "Bucket")
            guard entries.count <= 100 else { throw CloudFailure(.malformedResponse) }
            func field(_ name: String, in element: XMLElement) throws -> String? {
                let fields = element.elements(forName: name)
                guard fields.count <= 1, !(fields.first?.children ?? []).contains(where: { $0.kind == .element }) else {
                    throw CloudFailure(.malformedResponse)
                }
                return fields.first?.stringValue
            }
            buckets = try entries.map { entry in
                guard let name = try field("Name", in: entry), !name.isEmpty else { throw CloudFailure(.malformedResponse) }
                return try Bucket(name: name, region: field("BucketRegion", in: entry) ?? defaultRegion)
            }
            let next = try field("ContinuationToken", in: root)
            guard (next?.utf8.count ?? 0) <= 1024 else { throw CloudFailure(.malformedResponse) }
            token = next.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
