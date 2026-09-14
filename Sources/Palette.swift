// The floating palette: a non-activating panel that appears over whatever the
// user is doing, takes a few keystrokes, and gets out of the way. Three
// modes share one window: capturing something new, editing an existing
// clip's tags and note, and browsing/searching what was saved.
import AppKit


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
    /// Ticked tags, held as keys so `Reading` in Settings and `reading` in a
    /// file are the same tick.
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
    /// Separator above the why field. It doubles the header separator when
    /// the clip block between them is hidden, so it follows the block.
    private let fieldLine = NSBox()
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
        let background = configurePanel()
        configureLabels()
        configureList()
        assemble(in: background)
    }

    /// The window: floating, non-activating, rounded, and washed so text stays
    /// readable over anything. Returns the view everything else goes into.
    private func configurePanel() -> NSVisualEffectView {
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
        background.maskImage = PaletteShape.roundedMask(radius: 14)
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
        return background
    }

    /// Type and behaviour of every piece of text. Where they sit is `assemble`.
    private func configureLabels() {
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        clipTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        clipMeta.font = .systemFont(ofSize: 12)
        clipMeta.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel, clipTitle, clipMeta] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true

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
    }

    private func configureList() {
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
    }

    /// Icon, name and folder path, with the settings gear pushed to the right.
    private func makeHeader() -> NSStackView {
        let headerText = NSStackView(views: [titleLabel, subtitleLabel])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        logo.image = NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 44).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let header = NSStackView(views: [logo, headerText, spacer(), gear])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 18, left: Palette.pad, bottom: 10, right: Palette.pad)
        // The name block yields before the gear does: a long folder path
        // truncates instead of pushing the gear off the edge.
        headerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [titleLabel, subtitleLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        gear.setContentCompressionResistancePriority(.required, for: .horizontal)
        return header
    }

    /// What is about to be saved: title, then source, link or warning.
    private func makeClipBlock() -> NSStackView {
        clipBlock.setViews([clipTitle, clipMeta], in: .leading)
        clipBlock.orientation = .vertical
        clipBlock.alignment = .leading
        clipBlock.spacing = 2
        clipBlock.edgeInsets = NSEdgeInsets(top: 10, left: Palette.pad, bottom: 10, right: Palette.pad)
        // A long title must give way, not widen the panel: low resistance, hard right edge.
        for label in [clipTitle, clipMeta] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.trailingAnchor.constraint(equalTo: clipBlock.trailingAnchor, constant: -Palette.pad).isActive = true
        }
        return clipBlock
    }

    /// The note in a capture, the search field in browse, with the pinned
    /// `#tag` chips in front of it.
    private func makeFieldBox() -> NSView {
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
        return fieldBox
    }

    /// Key hints on the left, the actions as small buttons on the right.
    /// Everything a key does, a click does.
    private func makeFooter() -> NSStackView {
        hints.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.setContentHuggingPriority(.required, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [hints, spacer(), buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 12, left: Palette.pad, bottom: Palette.pad + 6, right: Palette.pad)
        return footer
    }

    /// One fixed-width column: header, clip, field, list, footer, separated by
    /// hairlines. Every row is pinned to the panel width so nothing reflows.
    private func assemble(in background: NSVisualEffectView) {
        let header = makeHeader()
        let clip = makeClipBlock()
        let fieldBox = makeFieldBox()
        let footer = makeFooter()
        let topLine = separatorLine()
        let line = separatorLine()
        fieldLine.boxType = .separator

        let stack = NSStackView(views: [header, topLine, clip, fieldLine, fieldBox, line, scroll, footer])
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
        ])
        for row in [header, topLine, clip, fieldLine, fieldBox, line, scroll, footer] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 200)
        scrollHeight.isActive = true
        // Sits over the (empty) list; a scroll view keeps its own subviews on top.
        background.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    private func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// An empty view that takes the slack in a row, so what follows is flush right.
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return view
    }

    private var scrollHeight: NSLayoutConstraint!


    // MARK: Showing

    var isVisible: Bool { panel.isVisible }

    func show(_ mode: PaletteMode) {
        if case .capture(let ctx) = self.mode, case .browse = mode, panel.isVisible { cameFrom = ctx }
        if case .capture = mode { cameFrom = nil }
        self.mode = mode
        resetChrome()
        switch mode {
        case .capture(let ctx): showCapture(ctx)
        case .edit(let clip): showEdit(clip)
        case .browse: showBrowse()
        }
        present()
    }

    /// What every mode starts from, before it fills in its own text.
    private func resetChrome() {
        existing = nil
        logo.isHidden = false
        titleLabel.stringValue = "Nutip"
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = Settings.folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? ""
        clipBlock.isHidden = false
        fieldLine.isHidden = false
        // Leaving browse: the pinned #tag chips belong to the search field,
        // not to the note, and there is no way to remove them from here.
        activeTags = []
        suggestions = []
        renderChips()
    }

    private func showCapture(_ ctx: CaptureContext) {
        tags = Settings.tags
        checked = []
        clipTitle.stringValue = ctx.suggestedTitle
        var sub = ctx.source
        if let url = ctx.url { sub += " · \(url)" }
        else if !ctx.selection.isEmpty { sub += " · \(ctx.selection.excerpt(90))" }
        if ctx.isStale {
            sub = "Same clipboard as your last clip. Copy something new, or save it again."
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
    }

    private func showEdit(_ clip: Clip) {
        tags = (Settings.tags + clip.tags).uniquedTags()
        checked = Set(clip.tags.map(\.tagKey))
        clipTitle.stringValue = clip.title
        clipMeta.textColor = .secondaryLabelColor
        clipMeta.stringValue = "Editing · \(clip.source) · \(Dates.relative(clip.capturedAt))"
        field.stringValue = clip.why
        field.placeholderString = "Why did you save this? (optional)"
        hints.stringValue = "↑↓ pick · ↩ or 1–9 toggle · ← note"
        setButtons([("Back", "esc", #selector(cancelPressed), false), ("Save", "→", #selector(savePressed), true)])
    }

    private func showBrowse() {
        clipBlock.isHidden = true
        fieldLine.isHidden = true
        field.stringValue = ""
        renderChips()   // sets the placeholder, with or without chips
        hints.stringValue = "type to search · # then tab picks a tag"
        var specs: [(String, String, Selector, Bool)] = []
        if cameFrom != nil { specs.append(("Back", "esc", #selector(cancelPressed), false)) }
        specs += [("Delete", "⌘⌫", #selector(deletePressed), false), ("Edit", "⌘E", #selector(editPressed), false),
                  ("Open Link", "⌘↩", #selector(openLinkPressed), false), ("Open File", "↩", #selector(openPressed), true)]
        setButtons(specs)
        results = Index.search("", tags: activeTags)
    }

    /// Size the list, put the panel on screen, and start listening for keys.
    private func present() {
        if !panel.isVisible { anchorTop = nil }
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
        anchorTop = nil
        panel.orderOut(nil)
    }

    /// The y of the panel's top edge. Set when the panel appears and kept
    /// while it is up: a list that grows or shrinks must not move the header.
    private var anchorTop: CGFloat?

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
        if let top = anchorTop {
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: top - panel.frame.height))
        }
    }

    private func place() {
        if let top = anchorTop {
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: top - panel.frame.height))
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2)
        panel.setFrameOrigin(origin)
        anchorTop = origin.y + size.height
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

    /// Returns true when the event was consumed. Keys that mean the same
    /// thing everywhere come first, then the ones the mode owns.
    private func handle(_ event: NSEvent) -> Bool {
        let key = Key(event)
        if handleEverywhere(key) { return true }
        return isTagMode ? handleTagMode(key) : handleBrowse(key)
    }

    /// One keystroke, read the way the palette cares about it.
    private struct Key {
        let code: UInt16
        let chars: String
        let command: Bool
        let control: Bool

        init(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            code = event.keyCode
            chars = event.charactersIgnoringModifiers ?? ""
            command = flags.contains(.command)
            control = flags.contains(.control)
        }

        /// Position of this key in the physical digit row, if it is one.
        var digit: Int? { Palette.digitKeys.firstIndex(of: code) }
        var isPrintable: Bool {
            guard !command, !control, let scalar = chars.unicodeScalars.first else { return false }
            return !CharacterSet.controlCharacters.contains(scalar)
        }

        static let escape: UInt16 = 53
        static let up: UInt16 = 126
        static let down: UInt16 = 125
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
    }

    private func handleEverywhere(_ key: Key) -> Bool {
        switch key.code {
        case Key.escape:
            goBack()
            return true
        case Key.up: moveSelection(-1); return true
        case Key.down: moveSelection(1); return true
        case 36, 76: // return, enter: toggles a tag while picking, opens in browse
            if isTagMode { toggleSelected() } else if suggesting { pickSuggestion() } else { confirm(command: key.command) }
            return true
        default: break
        }
        guard key.command else { return false }
        if key.chars == "f", isTagMode {
            show(.browse)
            return true
        }
        if key.chars == "o", let existing {
            open(existing)
            hide()
            return true
        }
        if key.chars == "q" { NSApp.terminate(nil); return true }
        return false
    }

    /// Capture and edit: pick tags, write the note, save. Arrows only, so the
    /// hand never leaves them: ← is the note, → saves.
    private func handleTagMode(_ key: Key) -> Bool {
        if key.command, let n = key.digit {
            toggle(index: n)
            return true
        }
        if key.code == Key.right, !key.command {
            // Only from the end of the note, so → still moves the caret inside it.
            if fieldIsEditing, let editor = field.currentEditor(), editor.selectedRange.location < editor.string.count { return false }
            confirm(command: false)
            return true
        }
        if key.code == Key.left, !key.command {
            if fieldIsEditing {
                guard let editor = field.currentEditor(), editor.selectedRange.location == 0 else { return false }
                panel.makeFirstResponder(nil)
            } else {
                focusField()
            }
            return true
        }
        if key.code == Key.tab {
            if fieldIsEditing { panel.makeFirstResponder(nil) } else { focusField() }
            return true
        }
        guard !fieldIsEditing else { return false }
        if key.code == Key.space { toggleSelected(); return true }
        if let n = key.digit, !key.command {
            toggle(index: n)
            return true
        }
        // Any other printable character starts the note.
        if key.isPrintable {
            focusField()
            field.currentEditor()?.insertText(key.chars)
            return true
        }
        return false
    }

    private func handleBrowse(_ key: Key) -> Bool {
        if key.code == Key.tab { if suggesting { pickSuggestion() }; return true }
        if key.code == Key.delete, !key.command, field.stringValue.isEmpty, !activeTags.isEmpty {
            removeLastChip()
            return true
        }
        if key.command, key.chars == "e", let clip = selectedClip { show(.edit(clip)); return true }
        if key.command, key.code == Key.delete, let clip = selectedClip { // ⌘⌫
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
        if checked.contains(tag.tagKey) { checked.remove(tag.tagKey) } else { checked.insert(tag.tagKey) }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    private func confirm(command: Bool) {
        switch mode {
        case .capture(let ctx):
            let why = field.stringValue
            hide()
            delegate?.palette(self, didCapture: ctx, tags: tags.filter { checked.contains($0.tagKey) }, why: why)
        case .edit(var clip):
            clip.tags = tags.filter { checked.contains($0.tagKey) }
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
            suggestions = Settings.tags.filter { !activeTags.containsTag($0) && (partial.isEmpty || $0.tagKey.hasPrefix(partial.tagKey)) }
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
            cell.set(number: row < 9 ? "\(row + 1)" : "", tag: tag, checked: checked.contains(tag.tagKey))
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
