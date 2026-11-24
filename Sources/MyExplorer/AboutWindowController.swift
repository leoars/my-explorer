// SPDX-License-Identifier: Apache-2.0
import AppKit

/// The About window, in the model shared by the My suite: name, version, what the application
/// is, who makes it, the licence, where the code lives and the other applications of the suite.
@MainActor
final class AboutWindowController: DialogWindowController {
    init() {
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("app.about")
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = false
        super.init(window: window)
        window.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    private func link(_ title: String, _ destination: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.identifier = .init(destination)
        button.setAccessibilityRole(.link)
        return button
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func build() {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "", number = info["CFBundleVersion"] as? String ?? ""
        let versionLabel = text(L10n.format("about.version", number.isEmpty ? short : "\(short) (\(number))"))
        versionLabel.textColor = .secondaryLabelColor
        let summary = text(L10n.text("about.description"))
        summary.preferredMaxLayoutWidth = 355
        summary.widthAnchor.constraint(equalToConstant: 355).isActive = true
        let author = text(L10n.text("about.author"), size: 14, weight: .semibold)
        let github = "https://github.com/leoars", linkedin = "https://www.linkedin.com/in/leonardoars/"
        let details = column([text("My Explorer", size: 25, weight: .semibold), versionLabel,
                              summary, author, link(github, github), link(linkedin, linkedin)], spacing: 4)
        details.setCustomSpacing(14, after: versionLabel)
        details.setCustomSpacing(14, after: summary)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 80), icon.heightAnchor.constraint(equalToConstant: 80)])
        let header = NSStackView(views: [icon, details])
        header.alignment = .top
        header.spacing = 20
        let suite = NSStackView(views: [text(L10n.text("about.suite")), link("My Notepad", github + "/My-Notepad"), text("·"),
                                        link("My Paint", github + "/my-paint"), text("·"),
                                        link("My Calc", github + "/my-calc")])
        let legalLinks = NSStackView(views: [link(L10n.text("about.license"), "LICENSE"), text("·"),
                                             link(L10n.text("about.notices"), "THIRD_PARTY_NOTICES.md")])
        let repository = github + "/my-explorer"
        let close = NSButton(title: L10n.text("about.close"), target: self, action: #selector(dismiss(_:)))
        close.keyEquivalent = "\r"
        close.setAccessibilityIdentifier("about.close")
        let footer = NSStackView(views: [link(L10n.text("about.repository"), repository), text("·"),
                                         link(L10n.text("about.issues"), repository + "/issues"), NSView(), close])
        let rule = NSBox()
        rule.boxType = .separator
        let content = column([header, rule, suite, text("© 2026 Leonardo Santos  ·  Apache License 2.0"), legalLinks, footer], spacing: 6)
        content.setCustomSpacing(18, after: header)
        content.setCustomSpacing(14, after: rule)
        content.setCustomSpacing(12, after: suite)
        content.setCustomSpacing(16, after: legalLinks)
        footer.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        rule.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        // The margins are constraints of a container, not insets of the stack: with insets the
        // fitting size came out narrower than the rows, and the Close button, the only thing
        // aligned to the right, ended up against the edge of the window.
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            footer.trailingAnchor.constraint(equalTo: header.trailingAnchor)
        ])
        window?.contentView = container
        window?.setContentSize(container.fittingSize)
    }

    @objc private func dismiss(_ sender: Any?) { close() }

    /// A web address opens in the browser; anything else is a file of the bundle (the licence,
    /// the notices) and opens in TextEdit.
    @objc private func openLink(_ sender: NSButton) {
        guard let destination = sender.identifier?.rawValue else { return }
        if destination.hasPrefix("https://"), let url = URL(string: destination) {
            NSWorkspace.shared.open(url)
        } else if let url = Bundle.main.resourceURL?.appendingPathComponent(destination),
                  let viewer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: viewer, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
