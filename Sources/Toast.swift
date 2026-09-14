// A small confirmation in the bottom-right corner after a clip is saved, with
// an Undo button. Gone by itself after a few seconds.
import AppKit

final class Toast {
    private var panel: NSPanel?
    private var timer: Timer?
    private var onUndo: (() -> Void)?
    /// ⌘Z is held only while the toast is on screen: five seconds during which
    /// undo means "undo the clip", then the key goes back to the active app.
    private let undoKey = GlobalHotkey()

    func show(_ text: String, detail: String, undo: @escaping () -> Void) {
        dismiss()
        onUndo = undo

        let panel = makePanel()
        let background = panel.contentView as! NSVisualEffectView
        let row = makeRow(text: text, detail: detail)
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.setContentSize(background.fittingSize)
        present(panel)

        self.panel = panel
        undoKey.register(.commandZ) { [weak self] in self?.undoPressed() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        panel.contentView = background
        return panel
    }

    /// Checkmark, what was saved, and the Undo button with its shortcut.
    private func makeRow(text: String, detail: String) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.contentTintColor = .systemGreen

        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [title, sub])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true

        let button = NSButton(title: "", target: self, action: #selector(undoPressed))
        button.bezelStyle = .roundRect
        button.controlSize = .small
        let undoTitle = NSMutableAttributedString(string: "Undo", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.labelColor])
        undoTitle.append(NSAttributedString(string: "  ⌘Z", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor]))
        button.attributedTitle = undoTitle

        let row = NSStackView(views: [icon, labels, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Bottom-right of the main screen, faded in.
    private func present(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.minY + 16))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    @objc private func undoPressed() {
        let undo = onUndo
        dismiss()
        undo?()
    }

    func dismiss() {
        undoKey.unregister()
        timer?.invalidate()
        timer = nil
        onUndo = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}
