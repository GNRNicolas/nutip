// The floating palette: a non-activating panel that appears over whatever the
// user is doing, takes a few keystrokes, and gets out of the way. Three
// modes share one window: capturing something new, editing an existing
// clip's tags and note, and browsing/searching what was saved.
import AppKit

/// A borderless NSPanel refuses to become key by default, and a panel that is
/// not key receives no keyboard events at all. This is the whole subclass.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum PaletteMode {
    case capture(CaptureContext)
    case edit(Clip)
    case browse
}

protocol PaletteDelegate: AnyObject {
    func palette(_ palette: Palette, didCapture context: CaptureContext, tags: [String], why: String)
    func palette(_ palette: Palette, didEdit clip: Clip)
    func palette(_ palette: Palette, didDelete clip: Clip)
    func paletteWantsSettings(_ palette: Palette)
}

final class Palette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: PaletteDelegate?

    private let panel: KeyPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hints = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private let gear = NSButton()
    private let buttons = NSStackView()
    private var monitor: Any?

    private var mode: PaletteMode = .browse
    private var tags: [String] = []
    private var checked = Set<String>()
    private var results: [Clip] = []
    /// Browse: tags pinned as blue chips before the field, and the tag
    /// suggestions shown while the user types `#…`.
    private var activeTags: [String] = []
    private var suggestions: [String] = []
    private var suggesting: Bool {
        guard case .browse = mode else { return false }
        return currentHashToken != nil
    }
    /// The `#partial` the caret is on, if any.
    private var currentHashToken: String? {
        guard let range = field.stringValue.range(of: "#[^\\s#]*$", options: .regularExpression) else { return nil }
        return String(field.stringValue[range].dropFirst())
    }
    private let chips = NSStackView()
    private let logo = NSImageView()
    private let clipTitle = NSTextField(labelWithString: "")
    private let clipMeta = NSTextField(labelWithString: "")
    private let clipBlock = NSStackView()
    /// Gap between the chips and the field: 8 pt with chips, otherwise pulled
    /// back so the field's 2 pt cell inset lines the text up with the labels.
    private var fieldGap: NSLayoutConstraint!
    private var existing: Clip?
    /// The capture that was open when Browse was entered, so esc brings it back.
    private var cameFrom: CaptureContext?

    private static let width: CGFloat = 720
    private static let pad: CGFloat = 24
    private static let tagRowHeight: CGFloat = 30
    private static let clipRowHeight: CGFloat = 46
    private static let maxRows = 8
    /// Key codes of the digit row, 1 to 9, so tags answer to the physical key
    /// on every layout (AZERTY needs shift for the digit itself).
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    // MARK: Setup

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Palette.width, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        // Behind-window blur ignores a layer's cornerRadius: the blur is drawn
        // by the window server, so the rounding has to be a mask image.
        background.maskImage = Palette.roundedMask(radius: 14)
        panel.contentView = background
        // Blur alone lets whatever is behind bleed through; a wash of the
        // window colour on top keeps the text readable on any background.
        let wash = NSBox()
        wash.boxType = .custom
        wash.borderWidth = 0
        wash.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72)   // dynamic: follows dark mode
        wash.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(wash)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            wash.topAnchor.constraint(equalTo: background.topAnchor),
            wash.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.allowsEmptySelection = true
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false

        hints.font = .systemFont(ofSize: 11)
        hints.textColor = .tertiaryLabelColor
        hints.lineBreakMode = .byTruncatingTail
        hints.maximumNumberOfLines = 1

        // Settings gear, top right, level with the app name.
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        gear.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        gear.contentTintColor = .secondaryLabelColor
        gear.isBordered = false
        gear.bezelStyle = .regularSquare
        gear.imagePosition = .imageOnly
        gear.toolTip = "Settings"
        gear.target = self
        gear.action = #selector(openSettings)
        gear.setContentHuggingPriority(.required, for: .horizontal)
        hints.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        hints.setContentHuggingPriority(.required, for: .horizontal)

        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        // The app icon sits left of the name in browse mode only; a capture
        // shows the page or text being saved, not Nutip.
        logo.image = NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 44).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [logo, headerText, headerSpacer, gear])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 18, left: Palette.pad, bottom: 10, right: Palette.pad)

        // What is about to be saved: title, then source / link / warnings.
        clipTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        clipTitle.lineBreakMode = .byTruncatingTail
        clipTitle.maximumNumberOfLines = 1
        clipMeta.font = .systemFont(ofSize: 12)
        clipMeta.textColor = .secondaryLabelColor
        clipMeta.lineBreakMode = .byTruncatingTail
        clipMeta.maximumNumberOfLines = 1
        clipBlock.setViews([clipTitle, clipMeta], in: .leading)
        clipBlock.orientation = .vertical
        clipBlock.alignment = .leading
        clipBlock.spacing = 2
        clipBlock.edgeInsets = NSEdgeInsets(top: 10, left: Palette.pad, bottom: 10, right: Palette.pad)
        for label in [clipTitle, clipMeta] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.trailingAnchor.constraint(equalTo: clipBlock.trailingAnchor, constant: -Palette.pad).isActive = true
        }
        // A long title must give way, not widen the panel: low resistance, hard right edge.
        // The name block yields before the gear does: a long folder path
        // truncates instead of pushing the gear off the edge.
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        headerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gear.setContentCompressionResistancePriority(.required, for: .horizontal)

        let fieldBox = NSView()
        fieldGap = field.leadingAnchor.constraint(equalTo: chips.trailingAnchor, constant: -2)
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.setContentHuggingPriority(.required, for: .horizontal)
        chips.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.addSubview(chips)
        fieldBox.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: Palette.pad),
            chips.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            fieldGap,
            field.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -Palette.pad),
            field.topAnchor.constraint(equalTo: fieldBox.topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: -10),
        ])

        let line = NSBox()
        line.boxType = .separator

        // Footer: key hints on the left, the actions as small buttons on the
        // right. Everything a key does, a click does.
        let footer = NSStackView(views: [hints, spacer, buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 12, left: Palette.pad, bottom: Palette.pad + 6, right: Palette.pad)

        let topLine = NSBox()
        topLine.boxType = .separator
        let fieldLine = NSBox()
        fieldLine.boxType = .separator
        let stack = NSStackView(views: [header, topLine, clipBlock, fieldLine, fieldBox, line, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            topLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fieldLine.widthAnchor.constraint(equalTo: stack.widthAnchor),
            clipBlock.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fieldBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            line.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 200)
        scrollHeight.isActive = true
        // Sits over the (empty) list; a scroll view keeps its own subviews on top.
        background.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    private var scrollHeight: NSLayoutConstraint!

    /// A stretchable rounded rectangle for `NSVisualEffectView.maskImage`.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Showing

    var isVisible: Bool { panel.isVisible }

    func show(_ mode: PaletteMode) {
        if case .capture(let ctx) = self.mode, case .browse = mode, panel.isVisible { cameFrom = ctx }
        if case .capture = mode { cameFrom = nil }
        self.mode = mode
        existing = nil
        logo.isHidden = false
        titleLabel.stringValue = "Nutip"
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = Settings.folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? ""
        clipBlock.isHidden = false
        switch mode {
        case .capture(let ctx):
            tags = Settings.tags
            checked = []
            clipTitle.stringValue = ctx.suggestedTitle
            var sub = ctx.source
            if let url = ctx.url { sub += " · \(url)" }
            else if !ctx.selection.isEmpty { sub += " · \(ctx.selection.excerpt(90))" }
            if ctx.isStale {
                sub = "Same clipboard as your last clip. Copy something new, or save it again."
            }
            if ctx.isStale {
                clipMeta.textColor = .systemOrange
            } else if let url = ctx.url, let dup = Index.existing(url: url) {
                existing = dup
                sub = "Already saved \(Dates.relative(dup.capturedAt))"
                    + (dup.tags.isEmpty ? "" : " · " + dup.tags.map { "#\($0)" }.joined(separator: " "))
                    + " · ⌘O opens it"
                clipMeta.textColor = .systemOrange
            } else {
                clipMeta.textColor = .secondaryLabelColor
            }
            clipMeta.stringValue = sub
            field.stringValue = ""
            field.placeholderString = "Why are you saving this? (optional, press ←)"
            hints.stringValue = "↑↓ pick · ↩ or 1–9 toggle · ← note"
            setButtons([("Browse", "⌘F", #selector(browsePressed), false), ("Cancel", "esc", #selector(cancelPressed), false),
                        ("Save", "→", #selector(savePressed), true)])
        case .edit(let clip):
            tags = (Settings.tags + clip.tags).uniqued()
            checked = Set(clip.tags)
            clipTitle.stringValue = clip.title
            clipMeta.textColor = .secondaryLabelColor
            clipMeta.stringValue = "Editing · \(clip.source) · \(Dates.relative(clip.capturedAt))"
            field.stringValue = clip.why
            field.placeholderString = "Why did you save this? (optional)"
            hints.stringValue = "↑↓ pick · ↩ or 1–9 toggle · ← note"
            setButtons([("Back", "esc", #selector(cancelPressed), false), ("Save", "→", #selector(savePressed), true)])
        case .browse:
            clipBlock.isHidden = true
            field.stringValue = ""
            field.placeholderString = "Search clips… (# for tags)"
            activeTags = []
            suggestions = []
            renderChips()
            hints.stringValue = "type to search · # then tab picks a tag"
            var specs: [(String, String, Selector, Bool)] = []
            if cameFrom != nil { specs.append(("Back", "esc", #selector(cancelPressed), false)) }
            specs += [("Delete", "⌘⌫", #selector(deletePressed), false), ("Edit", "⌘E", #selector(editPressed), false),
                      ("Open Link", "⌘↩", #selector(openLinkPressed), false), ("Open File", "↩", #selector(openPressed), true)]
            setButtons(specs)
            results = Index.search("", tags: activeTags)
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        resize()
        place()

        panel.makeKeyAndOrderFront(nil)
        switch mode {
        case .browse, .edit: focusField()
        case .capture: panel.makeFirstResponder(nil)
        }
        installMonitor()
    }

    /// Small bordered buttons, flush right, each with its shortcut in grey
    /// after the title. Keys are handled by the monitor, so no keyEquivalent.
    private func setButtons(_ specs: [(title: String, glyph: String, action: Selector, primary: Bool)]) {
        buttons.views.forEach { $0.removeFromSuperview() }
        for spec in specs {
            let b = NSButton(title: "", target: self, action: spec.action)
            b.bezelStyle = .roundRect
            b.controlSize = .small
            let title = NSMutableAttributedString(string: spec.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: spec.primary ? .semibold : .regular),
                .foregroundColor: spec.primary ? NSColor.controlAccentColor : NSColor.labelColor,
            ])
            title.append(NSAttributedString(string: "  " + spec.glyph, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            b.attributedTitle = title
            b.setContentHuggingPriority(.required, for: .horizontal)
            buttons.addArrangedSubview(b)
        }
    }

    @objc private func openSettings() { hide(); delegate?.paletteWantsSettings(self) }
    @objc private func savePressed() { confirm(command: false) }
    @objc private func openPressed() { confirm(command: false) }
    @objc private func openLinkPressed() { confirm(command: true) }
    @objc private func cancelPressed() { goBack() }

    /// esc / Back: edit → browse, browse → the capture it was opened from, else close.
    private func goBack() {
        switch mode {
        case .edit: show(.browse)
        case .browse: if let ctx = cameFrom { show(.capture(ctx)) } else { hide() }
        case .capture: hide()
        }
    }
    @objc private func browsePressed() { show(.browse) }
    @objc private func editPressed() { if let clip = selectedClip { show(.edit(clip)) } }
    @objc private func deletePressed() { if let clip = selectedClip { confirmDelete(clip) } }

    func hide() {
        removeMonitor()
        cameFrom = nil
        panel.orderOut(nil)
    }

    private func resize() {
        let rows = table.numberOfRows
        if suggesting {
            empty.stringValue = "No tag matches."
        } else if case .browse = mode {
            empty.stringValue = field.stringValue.trimmed.isEmpty ? "Nothing saved yet. Copy something, then press \(Hotkey.current.label)." : "No clips match."
        } else {
            empty.stringValue = "No tags yet. Add some in Settings."
        }
        empty.isHidden = rows > 0
        let rowHeight = showsTagRows ? Palette.tagRowHeight : Palette.clipRowHeight
        let visible = max(1, min(rows, Palette.maxRows))
        scrollHeight.constant = rows == 0 ? 56 : CGFloat(visible) * rowHeight + 4
        panel.layoutIfNeeded()
        panel.setContentSize(NSSize(width: Palette.width, height: panel.contentView!.fittingSize.height))
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2)
        panel.setFrameOrigin(origin)
    }

    private var isTagMode: Bool {
        if case .browse = mode { return false }
        return true
    }

    private var fieldIsEditing: Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    private func focusField() {
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: editor.string.count, length: 0)
        }
    }

    // MARK: Keys

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let key = event.keyCode
        let chars = event.charactersIgnoringModifiers ?? ""

        // Keys that mean the same thing everywhere.
        switch key {
        case 53: // esc
            goBack()
            return true
        case 126: moveSelection(-1); return true
        case 125: moveSelection(1); return true
        case 36, 76: // return, enter: toggles a tag while picking, opens in browse
            if isTagMode { toggleSelected() } else if suggesting { pickSuggestion() } else { confirm(command: cmd) }
            return true
        default: break
        }

        if cmd, chars == "f", isTagMode {
            show(.browse)
            return true
        }
        if cmd, chars == "o", let existing {
            open(existing)
            hide()
            return true
        }
        if cmd, chars == "q" { NSApp.terminate(nil); return true }

        if isTagMode {
            if cmd, let n = Palette.digitKeys.firstIndex(of: key) {
                toggle(index: n)
                return true
            }
            // ← and → : the note and Save, so the whole flow is arrows only.
            if key == 124, !cmd { // →
                if fieldIsEditing, let editor = field.currentEditor(), editor.selectedRange.location < editor.string.count { return false }
                confirm(command: false)
                return true
            }
            if key == 123, !cmd { // ←
                if fieldIsEditing {
                    guard let editor = field.currentEditor(), editor.selectedRange.location == 0 else { return false }
                    panel.makeFirstResponder(nil)
                } else {
                    focusField()
                }
                return true
            }
            if key == 48 { // tab: toggle between list and note
                if fieldIsEditing { panel.makeFirstResponder(nil) } else { focusField() }
                return true
            }
            guard !fieldIsEditing else { return false }
            if key == 49 { toggleSelected(); return true }
            if let n = Palette.digitKeys.firstIndex(of: key), !cmd {
                toggle(index: n)
                return true
            }
            // Any other printable character starts the note.
            if !cmd, !flags.contains(.control), let scalar = chars.unicodeScalars.first,
               !CharacterSet.controlCharacters.contains(scalar) {
                focusField()
                field.currentEditor()?.insertText(chars)
                return true
            }
            return false
        }

        // Browse mode.
        if key == 48 { if suggesting { pickSuggestion() }; return true }              // tab
        if key == 51, !cmd, field.stringValue.isEmpty, !activeTags.isEmpty {        // ⌫ on empty field
            removeLastChip()
            return true
        }
        if cmd, chars == "e", let clip = selectedClip { show(.edit(clip)); return true }
        if cmd, key == 51, let clip = selectedClip { // ⌘⌫
            confirmDelete(clip)
            return true
        }
        return false
    }

    private func moveSelection(_ delta: Int) {
        let count = table.numberOfRows
        guard count > 0 else { return }
        let current = table.selectedRow < 0 ? 0 : table.selectedRow
        let next = min(max(0, current + delta), count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func toggleSelected() {
        guard table.selectedRow >= 0 else { return }
        toggle(index: table.selectedRow)
    }

    private func toggle(index: Int) {
        guard index < tags.count else { return }
        let tag = tags[index]
        if checked.contains(tag) { checked.remove(tag) } else { checked.insert(tag) }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    private func confirm(command: Bool) {
        switch mode {
        case .capture(let ctx):
            let why = field.stringValue
            hide()
            delegate?.palette(self, didCapture: ctx, tags: tags.filter { checked.contains($0) }, why: why)
        case .edit(var clip):
            clip.tags = tags.filter { checked.contains($0) }
            clip.why = field.stringValue.trimmed
            hide()
            delegate?.palette(self, didEdit: clip)
        case .browse:
            guard let clip = selectedClip else { return }
            if command, let url = clip.url.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            } else {
                open(clip)
            }
            hide()
        }
    }

    /// Blue pills for the pinned tags, Slack-style.
    private func renderChips() {
        chips.views.forEach { $0.removeFromSuperview() }
        for tag in activeTags {
            // A coloured container with the label inset: a bare label with a
            // background hugs its glyphs and descenders touch the edge.
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            pill.layer?.cornerRadius = 6
            let label = NSTextField(labelWithString: "#\(tag)")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
                label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
            ])
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
            chips.addArrangedSubview(pill)
        }
        chips.isHidden = activeTags.isEmpty
        fieldGap.constant = activeTags.isEmpty ? -2 : 8
        field.placeholderString = activeTags.isEmpty ? "Search clips… (# for tags)" : "Search in these tags…"
    }

    /// Browse query without any `#…` token: those are chips, not words.
    private var searchText: String {
        field.stringValue.replacingOccurrences(of: "#[^\\s#]*", with: "", options: .regularExpression).trimmed
    }

    private func refreshBrowse() {
        if let partial = currentHashToken {
            suggestions = Settings.tags.filter { !activeTags.contains($0) && (partial.isEmpty || $0.hasPrefix(partial.lowercased())) }
        } else {
            suggestions = []
            results = Index.search(searchText, tags: activeTags)
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        resize()
    }

    /// Tab / return on a suggestion: the `#partial` becomes a chip.
    private func pickSuggestion() {
        guard suggesting else { return }
        let row = max(0, table.selectedRow)
        guard row < suggestions.count else { return }
        activeTags.append(suggestions[row])
        field.stringValue = field.stringValue.replacingOccurrences(of: "#[^\\s#]*$", with: "", options: .regularExpression)
        renderChips()
        refreshBrowse()
        focusField()
    }

    private func removeLastChip() {
        guard !activeTags.isEmpty else { return }
        activeTags.removeLast()
        renderChips()
        refreshBrowse()
    }

    private func open(_ clip: Clip) {
        if let file = clip.fileURL { NSWorkspace.shared.open(file) }
    }

    private func confirmDelete(_ clip: Clip) {
        let alert = NSAlert()
        alert.messageText = "Move “\(clip.title)” to the Trash?"
        alert.informativeText = clip.path
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            delegate?.palette(self, didDelete: clip)
            refreshBrowse()
        }
        panel.makeKeyAndOrderFront(nil)
        focusField()
    }

    private var selectedClip: Clip? {
        guard case .browse = mode, !suggesting, table.selectedRow >= 0, table.selectedRow < results.count else { return nil }
        return results[table.selectedRow]
    }

    @objc private func rowClicked() {
        if isTagMode { toggleSelected() } else if suggesting { pickSuggestion() }
    }

    @objc private func rowDoubleClicked() {
        if !isTagMode { confirm(command: false) }
    }

    // MARK: Text field

    func controlTextDidChange(_ obj: Notification) {
        guard case .browse = mode else { return }
        refreshBrowse()
    }

    // MARK: Table

    private var showsTagRows: Bool { isTagMode || suggesting }

    func numberOfRows(in tableView: NSTableView) -> Int {
        isTagMode ? tags.count : suggesting ? suggestions.count : results.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        showsTagRows ? Palette.tagRowHeight : Palette.clipRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isTagMode {
            let cell = tableView.makeView(withIdentifier: TagCell.id, owner: nil) as? TagCell ?? TagCell()
            let tag = tags[row]
            cell.set(number: row < 9 ? "\(row + 1)" : "", tag: tag, checked: checked.contains(tag))
            return cell
        }
        if suggesting {
            let cell = tableView.makeView(withIdentifier: TagCell.id, owner: nil) as? TagCell ?? TagCell()
            cell.set(number: "#", tag: suggestions[row], checked: false, hint: "tab")
            return cell
        }
        let cell = tableView.makeView(withIdentifier: ClipCell.id, owner: nil) as? ClipCell ?? ClipCell()
        cell.set(results[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRow() }
}

// MARK: - Rows

private final class PaletteRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 14, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

private final class TagCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("tag")
    private let number = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = TagCell.id
        hintLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.isHidden = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)
        number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        number.textColor = .tertiaryLabelColor
        number.alignment = .center
        name.font = .systemFont(ofSize: 14)
        check.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        check.contentTintColor = .controlAccentColor
        for v in [number, name, check] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            number.widthAnchor.constraint(equalToConstant: 16),
            number.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(number n: String, tag: String, checked: Bool, hint: String? = nil) {
        number.stringValue = n
        name.stringValue = tag
        if let hint {
            check.image = nil
            hintLabel.stringValue = hint
            hintLabel.isHidden = false
        } else {
            hintLabel.isHidden = true
            check.image = NSImage(systemSymbolName: checked ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
            check.contentTintColor = checked ? .controlAccentColor : .quaternaryLabelColor
        }
    }
}

private final class ClipCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("clip")
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = ClipCell.id
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        meta.font = .systemFont(ofSize: 11.5)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meta.maximumNumberOfLines = 1
        for v in [title, meta] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ clip: Clip) {
        title.stringValue = clip.title
        var parts = [Dates.relative(clip.capturedAt)]
        if !clip.domain.isEmpty { parts.append(clip.domain) } else { parts.append(clip.source) }
        if !clip.tags.isEmpty { parts.append(clip.tags.map { "#\($0)" }.joined(separator: " ")) }
        var line = parts.joined(separator: " · ")
        if !clip.why.isEmpty { line += " · \(clip.why)" }
        meta.stringValue = line
    }
}
