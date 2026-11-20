// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

/// Shares original local file URLs. Service and recipient selection belong to macOS and the user.
@MainActor
final class FileSharingController: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    typealias Presenter = ([URL], NSRect, NSView) -> Void
    private let presenter: Presenter?
    private var picker: NSSharingServicePicker?
    private var generation = 0

    init(presenter: Presenter? = nil) { self.presenter = presenter }

    static func supports(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy(\.isFileURL)
    }

    func share(_ urls: [URL], relativeTo rect: NSRect, of view: NSView) async throws {
        guard Self.supports(urls) else { throw CocoaError(.fileReadUnsupportedScheme) }
        generation += 1
        let request = generation
        let preflight = Task.detached {
            for url in urls {
                try LocalTransferRecovery.assertExportable(url)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                guard values.isRegularFile == true || values.isDirectory == true,
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    throw CocoaError(.fileReadNoPermission)
                }
            }
        }
        try await withTaskCancellationHandler { try await preflight.value } onCancel: { preflight.cancel() }
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        if let presenter { presenter(urls, rect, view); return }
        picker?.close()
        let next = NSSharingServicePicker(items: urls.map { $0 as NSURL })
        next.delegate = self
        picker = next
        next.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Retain a chosen picker while the system owns the sharing UI; a later share may replace it.
        if service == nil, picker === sharingServicePicker { picker = nil }
    }

    func closePicker() { generation += 1; picker?.close(); picker = nil }
}
