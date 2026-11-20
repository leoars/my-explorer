// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
final class CloudSettingsController: DialogWindowController {
    var onConnected: ((URL) -> Void)?
    var onAuthenticate: ((CloudConnection, CloudCredentials) -> Void)?
    private(set) var automationConnectionID: UUID?
    private let saved = NSPopUpButton()
    private let provider = NSPopUpButton()
    private let name = NSTextField(), bucket = NSTextField(), region = NSTextField(), account = NSTextField()
    private let accessKey = NSTextField(), secret = NSSecureTextField(), sessionToken = NSSecureTextField()
    private let sas = NSSecureTextField(), token = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private var rows: [String: NSView] = [:]
    private var pending: Task<Void, Never>?
    private var savedConnections: [CloudConnection] = []
    init(draft: CloudConnection? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("cloud.manage")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        saved.target = self; saved.action = #selector(selectSaved)
        saved.widthAnchor.constraint(equalToConstant: 390).isActive = true
        saved.setAccessibilityIdentifier("cloud.connections")
        let remove = NSButton(title: L10n.text("cloud.remove"), target: self, action: #selector(removeSaved))
        remove.bezelStyle = .rounded
        stack.addArrangedSubview(ExplorerStyle.stack([saved, remove]))
        provider.addItems(withTitles: ["AWS S3", "Azure Blob Storage", "Google Cloud Storage"])
        provider.target = self; provider.action = #selector(providerChanged)
        provider.widthAnchor.constraint(equalToConstant: 350).isActive = true
        provider.setAccessibilityIdentifier("cloud.provider")
        func row(_ key: String, _ field: NSView) {
            let label = NSTextField(labelWithString: L10n.text(key))
            label.widthAnchor.constraint(equalToConstant: 170).isActive = true
            field.widthAnchor.constraint(equalToConstant: 350).isActive = true
            field.setAccessibilityLabel(label.stringValue)
            field.setAccessibilityIdentifier(key)
            let row = ExplorerStyle.stack([label, field])
            rows[key] = row; stack.addArrangedSubview(row)
        }
        row("cloud.provider", provider)
        row("cloud.name", name); row("cloud.bucket", bucket)
        row("cloud.region", region); row("cloud.account", account)
        row("cloud.access_key", accessKey); row("cloud.secret", secret); row("cloud.session_token", sessionToken)
        row("cloud.sas", sas); row("cloud.access_token", token)
        let note = NSTextField(wrappingLabelWithString: L10n.text("cloud.credentials_note"))
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 530).isActive = true
        stack.addArrangedSubview(note)
        status.textColor = .systemRed
        status.widthAnchor.constraint(equalToConstant: 530).isActive = true
        stack.addArrangedSubview(status)
        saveButton.title = L10n.text("cloud.connect")
        saveButton.bezelStyle = .rounded
        saveButton.target = self; saveButton.action = #selector(connect)
        saveButton.setAccessibilityIdentifier("cloud.connect")
        stack.addArrangedSubview(saveButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        reloadSaved()
        region.stringValue = "us-east-1"
        providerChanged(nil)
        if let draft {
            automationConnectionID = draft.id
            name.stringValue = draft.name; bucket.stringValue = draft.bucket
            region.stringValue = draft.region ?? ""; account.stringValue = draft.account ?? ""
            provider.selectItem(at: CloudProvider.allCases.firstIndex(of: draft.provider) ?? 0)
            providerChanged(nil)
            for control in [saved, provider] { control.isEnabled = false }
            for field in [name, bucket, region, account] { field.isEditable = false }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func reloadSaved() {
        savedConnections = CloudAccounts.shared.connections
        saved.removeAllItems()
        saved.addItems(withTitles: [L10n.text("cloud.new")] + savedConnections.map(\.name))
    }
    @objc private func selectSaved(_ sender: Any?) {
        let index = saved.indexOfSelectedItem - 1
        secret.stringValue = ""; sas.stringValue = ""; token.stringValue = ""; sessionToken.stringValue = ""
        guard savedConnections.indices.contains(index) else {
            name.stringValue = ""; bucket.stringValue = ""; account.stringValue = ""; accessKey.stringValue = ""
            return
        }
        let connection = savedConnections[index]
        provider.selectItem(at: CloudProvider.allCases.firstIndex(of: connection.provider) ?? 0)
        name.stringValue = connection.name; bucket.stringValue = connection.bucket
        region.stringValue = connection.region ?? "us-east-1"; account.stringValue = connection.account ?? ""
        providerChanged(nil)
    }
    @objc private func removeSaved(_ sender: Any?) {
        let index = saved.indexOfSelectedItem - 1
        guard savedConnections.indices.contains(index), pending == nil else { return }
        do {
            try CloudAccounts.shared.remove(savedConnections[index].id)
            reloadSaved(); selectSaved(nil)
        } catch { status.stringValue = L10n.text("cloud.error.io"); status.textColor = .systemRed }
    }
    @objc private func providerChanged(_ sender: Any?) {
        let selected = CloudProvider.allCases[provider.indexOfSelectedItem]
        for key in ["cloud.region", "cloud.access_key", "cloud.secret", "cloud.session_token"] { rows[key]?.isHidden = selected != .s3 }
        for key in ["cloud.account", "cloud.sas"] { rows[key]?.isHidden = selected != .azure }
        rows["cloud.access_token"]?.isHidden = selected != .gcs
        status.stringValue = ""
    }
    @objc private func connect(_ sender: Any?) {
        guard pending == nil else { return }
        func value(_ field: NSTextField) -> String? {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let index = saved.indexOfSelectedItem - 1
        let id = automationConnectionID ?? (savedConnections.indices.contains(index) ? savedConnections[index].id : UUID())
        let providerValue = CloudProvider.allCases[provider.indexOfSelectedItem]
        let connection = CloudConnection(id: id, name: value(name) ?? "\(provider.titleOfSelectedItem ?? "Cloud") · \(value(bucket) ?? "")",
            provider: providerValue, bucket: value(bucket) ?? "", region: value(region), account: value(account))
        let credentials = CloudCredentials(accessKeyID: value(accessKey), secretAccessKey: value(secret),
            sessionToken: value(sessionToken), sasToken: value(sas), accessToken: value(token))
        status.stringValue = L10n.text("cloud.testing")
        status.textColor = .secondaryLabelColor
        setEditingEnabled(false)
        pending = Task { [weak self] in
            guard let self else { return }
            defer { self.pending = nil; self.setEditingEnabled(true) }
            do {
                let client = try CloudStorageClient(connection: connection, credentials: credentials)
                _ = try await client.list(prefix: "", continuationToken: nil)
                try Task.checkCancellation()
                if let onAuthenticate { onAuthenticate(connection, credentials) }
                else { try await CloudAccounts.shared.save(connection, credentials: credentials) }
                guard !Task.isCancelled, self.window?.isVisible == true else { return }
                self.onConnected?(RemoteLocation.url(connectionID: connection.id))
                self.close()
            } catch {
                if !(error is CancellationError) {
                    let reason = (error as? CloudFailure)?.reason.rawValue ?? "io"
                    self.status.stringValue = L10n.text("cloud.error.\(reason)")
                    self.status.textColor = .systemRed
                }
            }
        }
    }
    private func setEditingEnabled(_ enabled: Bool) {
        saved.isEnabled = enabled && automationConnectionID == nil; provider.isEnabled = enabled && automationConnectionID == nil; saveButton.isEnabled = enabled
        for field in [name, bucket, region, account, accessKey, secret, sessionToken, sas, token] { field.isEnabled = enabled }
    }
    func windowWillClose(_ notification: Notification) { pending?.cancel() }
}
