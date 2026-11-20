// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

internal struct PDFDestination: Sendable {
    let original: URL
    let resolved: URL
    let device: Int32
    let inode: UInt64
    static func inspect(_ url: URL, control: OCRCancellation) throws -> Self {
        try control.check()
        do { try DirectoryReader.validateLocalURL(url) } catch { throw SearchablePDFFailure(.invalidRequest) }
        guard url.pathExtension.lowercased() == "pdf", !url.lastPathComponent.isEmpty else { throw SearchablePDFFailure(.invalidRequest) }
        let parent = url.deletingLastPathComponent(), resolvedParent = parent.resolvingSymlinksInPath()
        let resolved = resolvedParent.appendingPathComponent(url.lastPathComponent)
        var original = stat(), target = stat()
        guard stat(parent.path, &original) == 0, lstat(resolvedParent.path, &target) == 0,
              target.st_mode & S_IFMT == S_IFDIR, original.st_dev == target.st_dev, original.st_ino == target.st_ino else { throw SearchablePDFFailure(.unavailable) }
        guard target.st_flags & UInt32(SF_DATALESS) == 0 else { throw SearchablePDFFailure(.needsDownload) }
        guard !LocalTransferRecovery.isProtected(url), !LocalTransferRecovery.isProtected(resolved) else { throw SearchablePDFFailure(.permissionDenied) }
        try absent(resolved)
        try control.check()
        return Self(original: url, resolved: resolved, device: target.st_dev, inode: target.st_ino)
    }
    func validate(_ control: OCRCancellation) throws {
        try control.check()
        let current = try Self.inspect(original, control: control)
        guard current.resolved == resolved, current.device == device, current.inode == inode else { throw SearchablePDFFailure(.sourceChanged) }
    }
    static func absent(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) != 0 else { throw SearchablePDFFailure(.destinationExists) }
        guard errno == ENOENT else { throw SearchablePDFFailure(.unavailable) }
    }
}

/// Eight admitted exports bound both staging storage and deferred filesystem cleanup.
/// Worker closures retain the lease while blocked; cleanup never runs on a cooperative/Main thread.
internal final class PDFExportLease: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var admitted = 0
    private static let cleanup = DispatchQueue(label: "MyExplorer.PDFCleanup", qos: .utility)
    private var parentFD: Int32 = -1
    private var stageFD: Int32 = -1
    private var stageName = ""
    private var stageDevice: Int32 = 0
    private var stageInode: UInt64 = 0
    private(set) var payloadURL: URL?
    private var outputIdentity: OCRFileIdentity?
    static func acquire() throws -> PDFExportLease {
        guard lock.withLock({ if admitted >= 8 { return false }; admitted += 1; return true }) else { throw SearchablePDFFailure(.busy) }
        return PDFExportLease()
    }
    func prepare(_ destination: PDFDestination, control: OCRCancellation) throws -> Int32 {
        try destination.validate(control)
        parentFD = open(destination.resolved.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var parent = stat()
        guard parentFD >= 0, fstat(parentFD, &parent) == 0, parent.st_dev == destination.device, parent.st_ino == destination.inode else { throw SearchablePDFFailure(.sourceChanged) }
        stageName = ".my-explorer-pdf-\(UUID())"
        payloadURL = destination.resolved.deletingLastPathComponent().appendingPathComponent(stageName).appendingPathComponent("output.pdf")
        guard mkdirat(parentFD, stageName, 0o700) == 0 else { throw SearchablePDFFailure(.unavailable) }
        stageFD = openat(parentFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var stage = stat()
        guard stageFD >= 0, fstat(stageFD, &stage) == 0 else { throw SearchablePDFFailure(.unavailable) }
        stageDevice = stage.st_dev; stageInode = stage.st_ino
        let output = openat(stageFD, "output.pdf", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw SearchablePDFFailure(.unavailable) }
        return output
    }
    func seal(_ fd: Int32) throws {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw SearchablePDFFailure(.sourceChanged) }
        outputIdentity = OCRFileIdentity(value)
    }
    func publish(to destination: PDFDestination, control: OCRCancellation, claim: @Sendable () throws -> Void) throws {
        try destination.validate(control)
        var parent = stat(), stage = stat(), output = stat()
        guard fstat(parentFD, &parent) == 0, parent.st_dev == destination.device, parent.st_ino == destination.inode,
              fstatat(parentFD, stageName, &stage, AT_SYMLINK_NOFOLLOW) == 0,
              stage.st_dev == stageDevice, stage.st_ino == stageInode,
              fstatat(stageFD, "output.pdf", &output, AT_SYMLINK_NOFOLLOW) == 0,
              output.st_mode & S_IFMT == S_IFREG, output.st_nlink == 1, OCRFileIdentity(output) == outputIdentity else { throw SearchablePDFFailure(.sourceChanged) }
        try claim() // Atomic cancellation/commit boundary; do not check cancellation after this point.
        guard renameatx_np(stageFD, "output.pdf", parentFD, destination.resolved.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw SearchablePDFFailure(errno == EEXIST ? .destinationExists : .unavailable)
        }
        // Descriptor-relative rename remains exclusive even if an ancestor is moved. Verify that
        // the promised URL still addresses this publication; never report false success or delete
        // an already-published file when the namespace changed during the commit syscall.
        var visibleParent = stat(), visibleOutput = stat(), requestedOutput = stat()
        guard lstat(destination.resolved.deletingLastPathComponent().path, &visibleParent) == 0,
              visibleParent.st_dev == destination.device, visibleParent.st_ino == destination.inode,
              lstat(destination.resolved.path, &visibleOutput) == 0,
              lstat(destination.original.path, &requestedOutput) == 0,
              visibleOutput.st_dev == output.st_dev, visibleOutput.st_ino == output.st_ino,
              requestedOutput.st_dev == output.st_dev, requestedOutput.st_ino == output.st_ino,
              visibleOutput.st_size == output.st_size, visibleOutput.st_mode == output.st_mode,
              visibleOutput.st_mtimespec.tv_sec == output.st_mtimespec.tv_sec,
              visibleOutput.st_mtimespec.tv_nsec == output.st_mtimespec.tv_nsec else {
            throw SearchablePDFFailure(.publicationIndeterminate)
        }
    }
    deinit {
        let parent = parentFD, stage = stageFD, name = stageName, device = stageDevice, inode = stageInode
        Self.cleanup.async {
            if stage >= 0 { _ = unlinkat(stage, "output.pdf", 0); close(stage) }
            if parent >= 0 {
                var current = stat()
                if !name.isEmpty, fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == device, current.st_ino == inode { _ = unlinkat(parent, name, AT_REMOVEDIR) }
                close(parent)
            }
            Self.lock.withLock { Self.admitted -= 1 }
        }
    }
}
