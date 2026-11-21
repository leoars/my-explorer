// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreServices
import Darwin

@MainActor
public protocol DirectoryChangeObserving: AnyObject {
    func watch(_ url: URL, onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Cancellation never waits for filesystem I/O or stream teardown.
private final class WatchPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activated = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    var acceptsEvents: Bool { lock.withLock { activated && !cancelled } }
    func activate() { lock.withLock { activated = true } }
    func cancel() { lock.withLock { cancelled = true } }
}

private final class WatchCallback: @unchecked Sendable {
    let path: String
    let includeDescendants: Bool
    let notify: @Sendable (Bool) -> Void
    private let lifecycle: (@Sendable (Bool) -> Void)?
    init(path: String, includeDescendants: Bool, notify: @escaping @Sendable (Bool) -> Void, lifecycle: (@Sendable (Bool) -> Void)?) {
        self.path = path; self.includeDescendants = includeDescendants; self.notify = notify; self.lifecycle = lifecycle; lifecycle?(true)
    }
    deinit { lifecycle?(false) }
}

/// Owns the descriptor through its dispatch source. FSEvents may wait during teardown;
/// neither explicit cancellation nor the last release performs that work on MainActor.
private final class WatchResources: @unchecked Sendable {
    private let lock = NSLock()
    private var retired = false
    private let stream: FSEventStreamRef?
    private let source: (any DispatchSourceFileSystemObject)?
    init(stream: FSEventStreamRef?, source: (any DispatchSourceFileSystemObject)?) {
        self.stream = stream; self.source = source
    }
    func cancel() {
        guard lock.withLock({ if retired { return false }; retired = true; return true }) else { return }
        source?.cancel()
        if let stream {
            let cleanup = StreamCleanup(stream)
            DispatchQueue.global(qos: .utility).async { cleanup.run() }
        }
    }
    deinit { cancel() }
}

private final class StreamCleanup: @unchecked Sendable {
    let stream: FSEventStreamRef
    init(_ stream: FSEventStreamRef) { self.stream = stream }
    func run() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// A blocked mount cannot consume an unbounded number of threads or pending requests.
private enum WatchPreparationPool {
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    static let admission = WatchAdmission()
    static func submit(_ operation: @escaping @Sendable () -> Void) -> Bool {
        guard admission.enter() else { return false }
        queue.addOperation { defer { admission.leave() }; operation() }
        return true
    }
}
private final class WatchAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func enter() -> Bool { lock.withLock { guard count < 64 else { return false }; count += 1; return true } }
    func leave() { lock.withLock { count -= 1 } }
}

/// FSEvents covers child metadata; vnode events cover rapid membership changes.
/// All path resolution, ancestor probing and stream setup happen on a bounded worker pool.
@MainActor
public final class DirectoryWatcher: DirectoryChangeObserving {
    nonisolated(unsafe) private var resources: WatchResources?
    nonisolated(unsafe) private var preparation: WatchPreparation?
    private var generation = 0
    private var retry: Task<Void, Never>?
    private var observedURL: URL?
    private var notify: (@MainActor () -> Void)?
    private let beforePreparation: (@Sendable (URL) -> Void)?
    private let openedDescriptor: (@Sendable (Int32) -> Void)?
    private let forceStreamCreationFailure: Bool
    private let contextLifecycle: (@Sendable (Bool) -> Void)?
    private let includeDescendants: Bool
    public init(includeDescendants: Bool = false) {
        self.includeDescendants = includeDescendants
        beforePreparation = nil; openedDescriptor = nil; forceStreamCreationFailure = false; contextLifecycle = nil
    }
    internal init(beforePreparation: (@Sendable (URL) -> Void)? = nil,
                  openedDescriptor: (@Sendable (Int32) -> Void)? = nil,
                  forceStreamCreationFailure: Bool = false,
                  contextLifecycle: (@Sendable (Bool) -> Void)? = nil) {
        self.includeDescendants = false
        self.beforePreparation = beforePreparation; self.openedDescriptor = openedDescriptor
        self.forceStreamCreationFailure = forceStreamCreationFailure; self.contextLifecycle = contextLifecycle
    }

    public func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        guard (try? DirectoryReader.validateLocalURL(url)) != nil else { return }
        observedURL = url; notify = onChange
        schedulePreparation()
    }

    public func stop() {
        generation &+= 1
        retry?.cancel(); retry = nil
        preparation?.cancel(); preparation = nil
        resources?.cancel(); resources = nil
        observedURL = nil; notify = nil
    }

    private func schedulePreparation() {
        guard let url = observedURL else { return }
        generation &+= 1
        let expected = generation
        preparation?.cancel(); resources?.cancel(); resources = nil
        let token = WatchPreparation()
        preparation = token
        let before = beforePreparation, opened = openedDescriptor, recursive = includeDescendants
        let failCreation = forceStreamCreationFailure, lifecycle = contextLifecycle
        let callback: @Sendable (Bool) -> Void = { [weak self] rearm in
            guard token.acceptsEvents else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, !token.isCancelled else { return }
                self.notify?()
                if rearm { self.schedulePreparation() }
            }
        }
        let accepted = WatchPreparationPool.submit { [weak self] in
            guard !token.isCancelled else { return }
            before?(url)
            let prepared = Self.prepare(url, token: token, callback: callback, opened: opened,
                                        forceStreamCreationFailure: failCreation, contextLifecycle: lifecycle, includeDescendants: recursive)
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, !token.isCancelled else { prepared?.cancel(); return }
                self.resources = prepared
                token.activate()
                // A first directory read may finish before asynchronous observation starts.
                // Reconcile once after installation, covering changes in that interval.
                if prepared != nil { self.notify?() }
            }
        }
        if !accepted {
            retry?.cancel()
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.generation == expected else { return }
                self.schedulePreparation()
            }
        }
    }

    nonisolated private static func prepare(_ url: URL, token: WatchPreparation,
        callback: @escaping @Sendable (Bool) -> Void, opened: (@Sendable (Int32) -> Void)?,
        forceStreamCreationFailure: Bool, contextLifecycle: (@Sendable (Bool) -> Void)?, includeDescendants: Bool) -> WatchResources? {
        guard !token.isCancelled else { return nil }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !token.isCancelled else { return nil }
        var ancestor = URL(fileURLWithPath: path)
        var descriptor: Int32 = -1
        var waitingForRecreation = false
        for _ in 0..<128 {
            guard !token.isCancelled else { if descriptor >= 0 { close(descriptor) }; return nil }
            descriptor = open(ancestor.path, O_EVTONLY | O_CLOEXEC)
            if descriptor >= 0 || ancestor.path == "/" { break }
            waitingForRecreation = true
            ancestor.deleteLastPathComponent()
        }
        if descriptor >= 0 { opened?(descriptor) }
        guard !token.isCancelled else { if descriptor >= 0 { close(descriptor) }; return nil }
        var source: (any DispatchSourceFileSystemObject)?
        if descriptor >= 0 {
            let next = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .revoke], queue: .global(qos: .utility))
            let ownedDescriptor = descriptor, waiting = waitingForRecreation
            next.setCancelHandler { close(ownedDescriptor) }
            next.setEventHandler { [weak next] in
                guard let next else { return }
                callback(waiting || !next.data.intersection([.delete, .rename, .revoke]).isEmpty)
            }
            next.resume()
            source = next
        }
        let box = WatchCallback(path: path, includeDescendants: includeDescendants, notify: callback, lifecycle: contextLifecycle)
        // FSEventStreamCreate can retain then release the context while failing and returning nil.
        // Give each framework retain its matching release; ownership never transfers implicitly.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<WatchCallback>.fromOpaque(pointer).retain().toOpaque())
            }, release: { pointer in
                if let pointer { Unmanaged<WatchCallback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        // Empty paths force a real Create failure for the lifecycle regression fixture.
        let pathsToWatch = forceStreamCreationFailure ? [] : [URL(fileURLWithPath: path).deletingLastPathComponent().path]
        let stream = withExtendedLifetime(box) { FSEventStreamCreate(nil, { _, info, count, rawPaths, eventFlags, _ in
            guard let info else { return }
            let callback = Unmanaged<WatchCallback>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes gives a borrowed CFArray (Get rule).
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let relevant = (0..<min(count, paths.count)).contains { index in
                let path = URL(fileURLWithPath: paths[index]).standardizedFileURL.path
                return eventFlags[index] & rescan != 0 || path == callback.path ||
                    (callback.includeDescendants && path.hasPrefix(callback.path == "/" ? "/" : callback.path + "/")) ||
                    URL(fileURLWithPath: path).deletingLastPathComponent().path == callback.path
            }
            if relevant { callback.notify(false) }
        }, &context, pathsToWatch as CFArray,
           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) }
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
                return source.map { WatchResources(stream: nil, source: $0) }
            }
        }
        if stream == nil && source == nil { return nil }
        return WatchResources(stream: stream, source: source)
    }

    deinit {
        preparation?.cancel()
        resources?.cancel()
    }
}
