// SPDX-License-Identifier: Apache-2.0
import AppKit
import ImageCaptureCore
import Quartz
import ExplorerCore

/// Image Capture owns camera sessions, thumbnail loading, selection and downloads.
@MainActor
final class DevicePhotoImporter: DialogWindowController, @preconcurrency IKDeviceBrowserViewDelegate, @preconcurrency IKCameraDeviceViewDelegate {
    var onClose: (() -> Void)?
    private let browser = IKDeviceBrowserView()
    private let camera = IKCameraDeviceView()

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 470),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("devices.import")
        window.minSize = NSSize(width: 680, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        browser.displaysLocalCameras = true
        browser.displaysLocalScanners = false
        browser.displaysNetworkCameras = false
        browser.displaysNetworkScanners = false
        browser.delegate = self
        camera.delegate = self
        camera.displaysDownloadsDirectoryControl = true
        camera.displaysPostProcessApplicationControl = false
        // The real Pictures folder: in the App Store build, `.picturesDirectory` is the container's.
        camera.downloadsDirectory = RealHome.pictures
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(browser)
        split.addArrangedSubview(camera)
        window.contentView = split
        split.setPosition(200, ofDividerAt: 0)
        camera.cameraDevice = browser.selectedDevice as? ICCameraDevice
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        browser.delegate = nil
        camera.delegate = nil
        camera.cameraDevice = nil
        onClose?()
    }

    func cameraDeviceView(_ cameraDeviceView: IKCameraDeviceView!, didDownloadFile file: ICCameraFile!,
                          location url: URL!, fileData data: Data!, error: Error!) {
        if let error { window?.presentError(error) }
    }

    func cameraDeviceView(_ cameraDeviceView: IKCameraDeviceView!, didEncounterError error: Error!) {
        if let error { window?.presentError(error) }
    }

    func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView!, selectionDidChange device: ICDevice!) {
        camera.cameraDevice = device as? ICCameraDevice
    }

    func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView!, didEncounterError error: Error!) {
        if let error { window?.presentError(error) }
    }
}
