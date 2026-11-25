// SPDX-License-Identifier: Apache-2.0
#if !APP_STORE
import AppKit

@MainActor
final class UpdateProgressController: DialogWindowController {
    private let phase = NSTextField(wrappingLabelWithString: "")
    private let percentage = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let totalBytes: Int64

    init(version: String, totalBytes: Int) {
        self.totalBytes = Int64(totalBytes)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 112),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.format("updates.progress_title", version)
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        phase.setAccessibilityIdentifier("updates.phase")
        percentage.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        percentage.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        let labels = NSStackView(views: [phase, percentage])
        labels.distribution = .fill
        let stack = NSStackView(views: [labels, bar])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        showPhase("updates.downloading")
        received(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func received(_ bytes: Int64) {
        guard !bar.isIndeterminate else { return }
        let fraction = min(1, max(bar.doubleValue, Double(bytes) / Double(totalBytes)))
        bar.doubleValue = fraction
        percentage.stringValue = fraction.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down))
    }

    func showPhase(_ key: String) {
        phase.stringValue = L10n.text(key)
        bar.setAccessibilityLabel(phase.stringValue)
        if key != "updates.downloading" {
            percentage.isHidden = true
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }
}
#endif
