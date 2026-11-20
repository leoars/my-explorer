// SPDX-License-Identifier: Apache-2.0
import AppKit
import ExplorerCore

@MainActor
final class FontSettingsController: DialogWindowController {
    private var pickers: [FontArea: NSPopUpButton] = [:]
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("font.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        for (index, area) in FontArea.allCases.enumerated() {
            let title = NSTextField(labelWithString: L10n.text("font.\(area.rawValue)"))
            title.widthAnchor.constraint(equalToConstant: 280).isActive = true
            let picker = NSPopUpButton()
            picker.tag = index
            picker.addItems(withTitles: (10...24).map { L10n.current.text("font.points", L10n.current.number($0)) })
            picker.selectItem(at: Int(ExplorerStyle.preferences.fontSize(for: area)) - 10)
            picker.target = self; picker.action = #selector(changed)
            picker.setAccessibilityLabel(title.stringValue)
            picker.widthAnchor.constraint(equalToConstant: 110).isActive = true
            pickers[area] = picker
            stack.addArrangedSubview(ExplorerStyle.stack([title, picker]))
        }
        let reset = NSButton(title: L10n.text("font.reset"), target: self, action: #selector(reset))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed(_ sender: NSPopUpButton) {
        ExplorerStyle.preferences.setFontSize(Double(sender.indexOfSelectedItem + 10), for: FontArea.allCases[sender.tag])
    }
    @objc private func reset(_ sender: Any?) {
        ExplorerStyle.preferences.resetFonts()
        refreshValues()
    }
    func refreshValues() {
        for (area, picker) in pickers {
            picker.selectItem(at: Int(ExplorerStyle.preferences.fontSize(for: area)) - 10)
        }
    }
}
