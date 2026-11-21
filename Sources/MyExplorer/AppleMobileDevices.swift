// SPDX-License-Identifier: Apache-2.0
import AppKit
import IOKit

/// Only product names are read. Pairing, trust, sync and backups stay with the system apps.
private enum USBMobileDevices {
    static func names() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            func property(_ name: String) -> AnyObject? {
                IORegistryEntryCreateCFProperty(device, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("idVendor") as? NSNumber)?.intValue == 0x05AC,
                  let product = property("USB Product Name") as? String,
                  product.hasPrefix("iPhone") || product.hasPrefix("iPad") else { continue }
            names.append(product)
        }
        return names.sorted()
    }
}

@MainActor
final class AppleMobileDevices: DialogWindowController {
    private let devices = NSTextField(wrappingLabelWithString: "")
    private let guide = NSTextField(wrappingLabelWithString: "")
    private let finder = NSButton()
    private let photos = NSButton()
    private var importer: DevicePhotoImporter?
    private var observation: Task<Void, Never>?

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("devices.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        devices.setAccessibilityIdentifier("explorer.devices.connected")
        devices.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        guide.stringValue = L10n.text("devices.guide")
        finder.title = L10n.text("devices.finder")
        photos.title = L10n.text("devices.import")
        photos.isEnabled = false
        for button in [finder, photos] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = #selector(openSystemApp(_:))
        }
        let buttons = NSStackView(views: [finder, photos])
        let stack = NSStackView(views: [devices, guide, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            guide.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func relocalize() {
        window?.title = L10n.text("devices.title")
        guide.stringValue = L10n.text("devices.guide")
        finder.title = L10n.text("devices.finder")
        photos.title = L10n.text("devices.import")
        importer?.window?.title = photos.title
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        observation?.cancel()
        observation = Task { [weak self] in
            while !Task.isCancelled {
                let names = await Task.detached(priority: .utility) { USBMobileDevices.names() }.value
                guard !Task.isCancelled, let self, self.window?.isVisible == true else { return }
                self.devices.stringValue = names.isEmpty ? L10n.text("devices.empty") : names.joined(separator: ", ")
                self.photos.isEnabled = !names.isEmpty
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func windowWillClose(_ notification: Notification) { observation?.cancel(); observation = nil }

    @objc private func openSystemApp(_ sender: NSButton) {
        if sender === photos {
            if importer == nil {
                importer = DevicePhotoImporter()
                importer?.onClose = { [weak self] in self?.importer = nil }
            }
            importer?.showWindow(self)
            return
        }
        let identifier = "com.apple.finder"
        guard let target = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            if let window { window.presentError(CocoaError(.fileNoSuchFile)) }
            return
        }
        NSWorkspace.shared.openApplication(at: target, configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.window?.presentError(error) } }
        }
    }
}
