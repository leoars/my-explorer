// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore
import UniformTypeIdentifiers

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
    typealias DiscoverBuckets = @Sendable (CloudCredentials, String) async throws -> S3BucketDiscovery.Result
    private let discoverBuckets: DiscoverBuckets
    private let lookupButton = NSButton()
    private var isLookingUp = false
    private let importButton = NSButton()
    private let saveButton = NSButton()
    private var rows: [String: NSView] = [:]
    private var pending: Task<Void, Never>?
    private var savedConnections: [CloudConnection] = []
    init(draft: CloudConnection? = nil, discoverBuckets: @escaping DiscoverBuckets = {
        try await S3BucketDiscovery().discover(credentials: $0, region: $1)
    }) {
        self.discoverBuckets = discoverBuckets
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
        func row(_ key: String, _ field: NSView, beside button: NSButton? = nil) {
            let label = NSTextField(labelWithString: L10n.text(key))
            label.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let input: NSView
            if let button {
                input = ExplorerStyle.stack([field, button])
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            } else { input = field }
            input.widthAnchor.constraint(equalToConstant: 350).isActive = true
            field.setAccessibilityLabel(label.stringValue)
            field.setAccessibilityIdentifier(key)
            let row = ExplorerStyle.stack([label, input])
            rows[key] = row; stack.addArrangedSubview(row)
        }
        row("cloud.provider", provider)
        lookupButton.title = L10n.text("cloud.bucket_lookup")
        lookupButton.bezelStyle = .rounded
        lookupButton.target = self
        lookupButton.action = #selector(lookupBuckets)
        lookupButton.setAccessibilityIdentifier("cloud.bucket_lookup")
        row("cloud.name", name); row("cloud.bucket", bucket, beside: lookupButton)
        row("cloud.region", region); row("cloud.account", account)
        row("cloud.access_key", accessKey); row("cloud.secret", secret); row("cloud.session_token", sessionToken)
        importButton.title = L10n.text("cloud.import_csv")
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importCSV)
        importButton.setAccessibilityIdentifier("cloud.import_csv")
        stack.addArrangedSubview(importButton)
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
        accessKey.stringValue = ""; secret.stringValue = ""; sas.stringValue = ""; token.stringValue = ""; sessionToken.stringValue = ""
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
        if sender != nil {
            accessKey.stringValue = ""; secret.stringValue = ""; sessionToken.stringValue = ""
            sas.stringValue = ""; token.stringValue = ""
        }
        lookupButton.isHidden = selected != .s3 || automationConnectionID != nil
        importButton.isHidden = selected != .s3
        for key in ["cloud.region", "cloud.access_key", "cloud.secret", "cloud.session_token"] { rows[key]?.isHidden = selected != .s3 }
        for key in ["cloud.account", "cloud.sas"] { rows[key]?.isHidden = selected != .azure }
        rows["cloud.access_token"]?.isHidden = selected != .gcs
        status.stringValue = ""
    }
    @objc private func importCSV(_ sender: Any?) {
        guard let window, pending == nil, !importButton.isHidden else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.title = L10n.text("cloud.import_csv")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.fillS3Credentials(from: url)
        }
    }

    func fillS3Credentials(from url: URL) {
        guard pending == nil, !importButton.isHidden else { return }
        setEditingEnabled(false)
        pending = Task {
            defer { pending = nil; setEditingEnabled(true) }
            do {
                let credentials = try await Task.detached(priority: .userInitiated) { try S3CredentialCSV.read(from: url) }.value
                try Task.checkCancellation()
                accessKey.stringValue = credentials.accessKeyID ?? ""
                secret.stringValue = credentials.secretAccessKey ?? ""
                sessionToken.stringValue = credentials.sessionToken ?? ""
                status.stringValue = L10n.text(bucket.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "cloud.import_bucket_needed" : "cloud.import_csv_ok")
                status.textColor = .secondaryLabelColor
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = L10n.text("cloud.import_csv_error")
                status.textColor = .systemRed
            }
        }
    }

    @objc private func lookupBuckets(_ sender: Any?) {
        if isLookingUp { pending?.cancel(); return }
        guard pending == nil, !lookupButton.isHidden, let window else { return }
        let id = accessKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !key.isEmpty else {
            status.stringValue = L10n.text("cloud.bucket_keys_needed")
            status.textColor = .systemRed
            window.makeFirstResponder(id.isEmpty ? accessKey : secret)
            return
        }
        let token = sessionToken.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = CloudCredentials(accessKeyID: id, secretAccessKey: key, sessionToken: token.isEmpty ? nil : token)
        let currentRegion = region.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isLookingUp = true
        setEditingEnabled(false)
        lookupButton.isEnabled = true
        lookupButton.title = L10n.text("dialog.cancel")
        status.stringValue = L10n.text("cloud.bucket_searching")
        status.textColor = .secondaryLabelColor
        pending = Task {
            defer {
                pending = nil; isLookingUp = false; setEditingEnabled(true)
                lookupButton.title = L10n.text("cloud.bucket_lookup")
            }
            do {
                let result = try await discoverBuckets(credentials, currentRegion.isEmpty ? "us-east-1" : currentRegion)
                try Task.checkCancellation()
                guard window.isVisible else { return }
                status.stringValue = result.isPartial ? L10n.text("cloud.bucket_partial") : ""
                guard !result.buckets.isEmpty else {
                    if !result.isPartial { status.stringValue = L10n.text("cloud.bucket_none") }
                    return
                }
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 28))
                picker.addItems(withTitles: result.buckets.map { $0.name + " · " + $0.region })
                picker.setAccessibilityLabel(L10n.text("cloud.bucket_choose"))
                let alert = NSAlert()
                alert.messageText = L10n.text("cloud.bucket_choose")
                alert.informativeText = status.stringValue
                alert.accessoryView = picker
                alert.addButton(withTitle: L10n.text("dialog.confirm"))
                alert.addButton(withTitle: L10n.text("dialog.cancel"))
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                      !Task.isCancelled, result.buckets.indices.contains(picker.indexOfSelectedItem) else { return }
                let selected = result.buckets[picker.indexOfSelectedItem]
                bucket.stringValue = selected.name
                region.stringValue = selected.region
            } catch {
                guard !Task.isCancelled else { status.stringValue = ""; return }
                let reason = (error as? CloudFailure)?.reason
                status.stringValue = L10n.text(reason == .permissionDenied ? "cloud.bucket_denied" : "cloud.error." + (reason?.rawValue ?? "io"))
                status.textColor = .systemRed
            }
        }
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
        if providerValue == .s3 && value(bucket) == nil {
            status.stringValue = L10n.text("cloud.bucket_needed")
            status.textColor = .systemRed
            if bucket.isEditable { window?.makeFirstResponder(bucket) }
            return
        }
        let connection = CloudConnection(id: id, name: value(name) ?? "\(provider.titleOfSelectedItem ?? "Cloud") · \(value(bucket) ?? "")",
            provider: providerValue, bucket: value(bucket) ?? "", region: value(region), account: value(account))
        let credentials: CloudCredentials
        switch providerValue {
        case .s3: credentials = CloudCredentials(accessKeyID: value(accessKey), secretAccessKey: value(secret), sessionToken: value(sessionToken))
        case .azure: credentials = CloudCredentials(sasToken: value(sas))
        case .gcs: credentials = CloudCredentials(accessToken: value(token))
        }
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
                let connectedID: UUID
                if let onAuthenticate {
                    onAuthenticate(connection, credentials)
                    connectedID = connection.id
                } else {
                    connectedID = try await CloudAccounts.shared.save(connection, credentials: credentials, reuseExistingS3: true)
                }
                guard !Task.isCancelled, self.window?.isVisible == true else { return }
                self.onConnected?(RemoteLocation.url(connectionID: connectedID))
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
        lookupButton.isEnabled = enabled
        importButton.isEnabled = enabled
        saved.isEnabled = enabled && automationConnectionID == nil; provider.isEnabled = enabled && automationConnectionID == nil; saveButton.isEnabled = enabled
        for field in [name, bucket, region, account, accessKey, secret, sessionToken, sas, token] { field.isEnabled = enabled }
    }
    func windowWillClose(_ notification: Notification) { pending?.cancel() }
}
