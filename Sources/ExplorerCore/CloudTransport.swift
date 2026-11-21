// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

/// Uses foreground ephemeral sessions: redirects remain under our control and no credentials are cached.
public struct URLSessionCloudTransport: CloudTransport, Sendable {
    private let configuration: URLSessionConfiguration
    private let returnRedirects: Bool
    public init() { configuration = .ephemeral; returnRedirects = false }
    /// Tests can supply a URLProtocol without opening sockets or using real accounts.
    init(configuration: URLSessionConfiguration, returnRedirects: Bool = false) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.returnRedirects = returnRedirects
    }
    public func send(_ request: URLRequest) async throws -> CloudResponse {
        try await CloudHTTPTransaction(request: request, operation: .metadata, progress: nil, configuration: configuration, returnRedirects: returnRedirects).run()
    }
    public func upload(_ request: URLRequest, fileURL: URL, progress: CloudProgressHandler? = nil) async throws -> CloudResponse {
        try await CloudHTTPTransaction(request: request, operation: .upload(fileURL), progress: progress, configuration: configuration).run()
    }
    public func download(_ request: URLRequest, to fileURL: URL, progress: CloudProgressHandler? = nil) async throws -> CloudResponse {
        try await CloudHTTPTransaction(request: request, operation: .download(fileURL), progress: progress, configuration: configuration).run()
    }
}

/// Same origin includes the port; a downgrade or a credential-bearing URL is never accepted.
enum CloudRedirectPolicy {
    static func secure(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
    static func allows(from original: URL?, to proposed: URL?) -> Bool {
        guard secure(original), secure(proposed), let original, let proposed else { return false }
        return original.host?.lowercased() == proposed.host?.lowercased() && (original.port ?? 443) == (proposed.port ?? 443)
    }
}

private final class CloudHTTPTransaction: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Operation { case metadata, upload(URL), download(URL) }
    private let request: URLRequest
    private let operation: Operation
    private let progress: CloudProgressHandler?
    private let configuration: URLSessionConfiguration
    private let returnRedirects: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CloudResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionTask?
    private var cancelled = false
    private var finished = false
    private var received = Data()
    private var downloaded = false
    private var downloadFailure: CloudFailure?
    private let maximumMetadataBytes = 16 * 1024 * 1024

    init(request: URLRequest, operation: Operation, progress: CloudProgressHandler?, configuration: URLSessionConfiguration, returnRedirects: Bool = false) {
        self.request = request; self.operation = operation; self.progress = progress
        self.configuration = configuration; self.returnRedirects = returnRedirects
    }

    func run() async throws -> CloudResponse {
        guard CloudRedirectPolicy.secure(request.url) else { throw CloudFailure(.insecureTransport) }
        if Task.isCancelled { throw CloudFailure(.cancelled) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { start($0) }
        } onCancel: { self.cancel() }
    }

    private func start(_ continuation: CheckedContinuation<CloudResponse, any Error>) {
        let shouldCancel = lock.withLock {
            self.continuation = continuation
            return cancelled
        }
        if shouldCancel { finish(.failure(CloudFailure(.cancelled))); return }
        let configuration = self.configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task: URLSessionTask
        switch operation {
        case .metadata: task = session.dataTask(with: request)
        case .upload(let source): task = session.uploadTask(with: request, fromFile: source)
        case .download: task = session.downloadTask(with: request)
        }
        let stopped = lock.withLock {
            guard !finished, !cancelled else { return true }
            self.session = session; self.task = task
            return false
        }
        if stopped {
            task.cancel(); session.invalidateAndCancel()
            finish(.failure(CloudFailure(.cancelled)))
        } else { task.resume() }
    }

    private func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
        finish(.failure(CloudFailure(.cancelled)))
    }

    private func finish(_ result: Result<CloudResponse, any Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<CloudResponse, any Error>, URLSession?, Bool)? in
            guard !finished, let continuation else { return nil }
            finished = true
            self.continuation = nil
            let session = self.session
            self.session = nil; task = nil
            return (continuation, session, cancelled)
        }
        guard let (continuation, session, cancelled) = completion else { return }
        session?.invalidateAndCancel()
        if cancelled { continuation.resume(throwing: CloudFailure(.cancelled)) }
        else { continuation.resume(with: result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if returnRedirects { completionHandler(nil); return }
        guard CloudRedirectPolicy.allows(from: self.request.url, to: request.url) else {
            completionHandler(nil)
            finish(.failure(CloudFailure(.insecureTransport)))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock {
            guard !finished else { return false }
            guard data.count <= maximumMetadataBytes - received.count else { return true }
            received.append(data)
            return false
        }
        if tooLarge { finish(.failure(CloudFailure(.malformedResponse, detail: "Metadata response exceeds 16 MiB"))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard !lock.withLock({ finished || cancelled }) else { return }
        progress?(CloudTransferProgress(completedBytes: totalBytesSent,
                                        totalBytes: totalBytesExpectedToSend >= 0 ? totalBytesExpectedToSend : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard !lock.withLock({ finished || cancelled }) else { return }
        progress?(CloudTransferProgress(completedBytes: totalBytesWritten,
                                        totalBytes: totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard case .download(let destination) = operation,
              let response = downloadTask.response as? HTTPURLResponse,
              !lock.withLock({ finished || cancelled }) else { return }
        if (400..<500).contains(response.statusCode) {
            let body = CloudDownloadErrorBody.read(location)
            lock.withLock { if !finished && !cancelled { received = body } }
            return
        }
        guard (200..<300).contains(response.statusCode) else { return }
        do {
            // The caller supplies a fresh path inside a private staging directory.
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { downloaded = true }
        } catch { lock.withLock { downloadFailure = CloudFailure(.io, detail: "Could not stage downloaded file") } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let code = (error as NSError).code
            finish(.failure(CloudFailure(code == NSURLErrorCancelled ? .cancelled : .io, detail: "Network error \(code)")))
            return
        }
        guard let response = task.response as? HTTPURLResponse else { finish(.failure(CloudFailure(.malformedResponse))); return }
        let snapshot = lock.withLock { (received, downloaded, downloadFailure) }
        if let failure = snapshot.2 { finish(.failure(failure)); return }
        if case .download = operation, (200..<300).contains(response.statusCode), !snapshot.1 {
            finish(.failure(CloudFailure(.io, detail: "Download did not produce a file"))); return
        }
        let headers = Dictionary(response.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }; return (key, String(describing: value))
        }, uniquingKeysWith: { first, _ in first })
        finish(.success(CloudResponse(statusCode: response.statusCode, headers: headers, body: snapshot.0)))
    }
}

/// URLSession owns this temporary file. Error documents are never moved to a destination.
internal enum CloudDownloadErrorBody {
    static func read(_ url: URL) -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return Data() }
        defer { close(descriptor) }
        var metadata = Darwin.stat()
        let limit = 65_536
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= limit else { return Data() }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var total = 0
        while total <= limit {
            let amount = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: total), limit + 1 - total)
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount >= 0 else { return Data() }
            if amount == 0 { return Data(bytes.prefix(total)) }
            total += amount
        }
        return Data()
    }
}
