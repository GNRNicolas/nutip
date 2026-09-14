// A small confirmation in the bottom-right corner after a nut is saved, with
// an Undo button. Gone by itself after a few seconds.
import AppKit

final class Toast {
    private var panel: NSPanel?
    private var timer: Timer?
    private var onUndo: (() -> Void)?
    private var onReason: (() -> Void)?
    /// ⌘Z is held only while the toast is on screen: five seconds during which
    /// undo means "undo the nut", then the key goes back to the active app.
    private let undoKey = GlobalHotkey()
    /// Same five seconds for ⌘Y, offered only when the nut was saved without
    /// a reason — the one field nothing else can reconstruct later.
    private let reasonKey = GlobalHotkey()

    func show(_ text: String, detail: String, reason: (() -> Void)? = nil,
              undo: @escaping () -> Void) {
        dismiss()
        onUndo = undo
        onReason = reason

        let panel = makePanel()
        let background = panel.contentView as! NSVisualEffectView
        let row = makeRow(text: text, detail: detail, offersReason: reason != nil)
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
        if reason != nil { reasonKey.register(.commandY) { [weak self] in self?.reasonPressed() } }
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

        // The same chrome as the palette, down to the wash: the toast is the
        // palette's own answer, a second later. A different material read as a
        // different app's notification.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = PaletteShape.roundedMask(radius: 14)
        panel.contentView = background

        let wash = NSBox()
        wash.boxType = .custom
        wash.borderWidth = 0
        wash.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72)
        wash.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(wash)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            wash.topAnchor.constraint(equalTo: background.topAnchor),
            wash.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return panel
    }

    /// Checkmark, what was saved, and the Undo button with its shortcut.
    private func makeRow(text: String, detail: String, offersReason: Bool) -> NSStackView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

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

        var views: [NSView] = [icon, labels]
        if offersReason { views.append(small("Why?", "⌘Y", #selector(reasonPressed))) }
        views.append(button)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 14)
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

    /// A second, quieter button: the same shape as Undo, so the two read as a
    /// pair of afterthoughts rather than a choice to make.
    private func small(_ title: String, _ key: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .roundRect
        button.controlSize = .small
        let label = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor])
        label.append(NSAttributedString(string: "  \(key)", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor]))
        button.attributedTitle = label
        return button
    }

    @objc private func reasonPressed() {
        let reason = onReason
        dismiss()
        reason?()
    }

    @objc private func undoPressed() {
        let undo = onUndo
        dismiss()
        undo?()
    }

    func dismiss() {
        undoKey.unregister()
        reasonKey.unregister()
        onReason = nil
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
