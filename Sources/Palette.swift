// The floating palette: a non-activating panel that appears over whatever the
// user is doing, takes a few keystrokes, and gets out of the way. Three
// modes share one window: capturing something new, editing an existing
// nut's tags and note, and browsing/searching what was saved.
import AppKit


enum PaletteMode {
    case capture(CaptureContext)
    case edit(Nut)
    case browse
}

protocol PaletteDelegate: AnyObject {
    func palette(_ palette: Palette, didCapture context: CaptureContext, tags: [String], why: String)
    func palette(_ palette: Palette, didEdit nut: Nut)
    func palette(_ palette: Palette, didDelete nut: Nut)
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
    private let preview = PreviewPane()
    private let listSplit = NSStackView()
    private let previewLine = NSBox()
    private var monitor: Any?

    private var mode: PaletteMode = .browse
    private var tags: [String] = []
    /// Ticked tags, held as keys so `Reading` in Settings and `reading` in a
    /// file are the same tick.
    private var checked = Set<String>()
    private var results: [Nut] = []
    /// Browse pages its results in, `pageSize` at a time. `exhausted` is set
    /// by a page that came back short: it is how the list knows to stop asking
    /// the database the same question with a bigger offset.
    private var exhausted = false
    private var loadingPage = false
    /// The body behind the highlighted row. An index row carries none, so it
    /// is read from the file and kept while the row stays highlighted.
    private var previewCache: (path: String, body: String)?
    /// Browse: tags pinned as blue chips before the field, and the tag
    /// suggestions shown while the user types `#…`.
    private var activeTags: [String] = []
    private var activeFacets: [Index.Facet] = []
    private var suggestions: [String] = []
    private var facetSuggestions: [Index.Facet] = []
    private var suggesting: Bool {
        guard case .browse = mode else { return false }
        return currentHashToken != nil || currentAtToken != nil
    }
    /// The `#partial` the caret is on, if any.
    private var currentHashToken: String? { token(prefix: "#") }
    /// The `@partial` the caret is on: a facet being picked.
    private var currentAtToken: String? { token(prefix: "@") }

    private func token(prefix: String) -> String? {
        guard let range = field.stringValue.range(of: "\(prefix)[^\\s#@]*$", options: .regularExpression)
        else { return nil }
        return String(field.stringValue[range].dropFirst())
    }
    private let chips = NSStackView()
    /// Separator above the why field. It doubles the header separator when
    /// the nut block between them is hidden, so it follows the block.
    private let fieldLine = NSBox()
    private let logo = NSImageView()
    private let nutTitle = NSTextField(labelWithString: "")
    private let nutMeta = NSTextField(labelWithString: "")
    private let nutBlock = NSStackView()
    /// Gap between the chips and the field: 8 pt with chips, otherwise pulled
    /// back so the field's 2 pt cell inset lines the text up with the labels.
    private var fieldGap: NSLayoutConstraint!
    private var existing: Nut?
    /// The capture that was open when Browse was entered, so esc brings it back.
    private var cameFrom: CaptureContext?

    private static let width: CGFloat = 720
    /// Browse is wider: the list keeps a readable width and the pane beside it
    /// gets a column of prose rather than a column of hyphenated words.
    private static let browseWidth: CGFloat = 1040
    private static let listColumnWidth: CGFloat = 400
    private static let pageSize = 50
    private static let pad: CGFloat = 24
    private static let tagRowHeight: CGFloat = 30
    private static let nutRowHeight: CGFloat = 60
    private static let matchRowHeight: CGFloat = 78
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
        nutTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        nutMeta.font = .systemFont(ofSize: 12)
        nutMeta.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel, nutTitle, nutMeta] {
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
        // Paging happens on scroll, so the clip view has to say when it moved.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listScrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The list and, beside it in browse, the pane that says what the
    /// highlighted nut holds. A stack rather than two pinned views, because
    /// hiding the pane has to give its width back instead of leaving a hole.
    private func makeListArea() -> NSStackView {
        previewLine.boxType = .separator
        listSplit.setViews([scroll, previewLine, preview], in: .leading)
        listSplit.orientation = .horizontal
        listSplit.spacing = 0
        listSplit.distribution = .fill
        listSplit.alignment = .centerY
        for view in [scroll, previewLine, preview] {
            view.heightAnchor.constraint(equalTo: listSplit.heightAnchor).isActive = true
        }
        previewLine.widthAnchor.constraint(equalToConstant: 1).isActive = true
        listWidth = scroll.widthAnchor.constraint(equalToConstant: Palette.listColumnWidth)
        return listSplit
    }

    /// Width of the list while the pane is up. Off, and the list takes the lot.
    private var listWidth: NSLayoutConstraint!

    /// The pane belongs to browse and to nothing else: a capture is three
    /// lines and a tag list, and widening the panel for it would be noise.
    private func setPreview(_ on: Bool) {
        preview.isHidden = !on
        previewLine.isHidden = !on
        listWidth.isActive = on
    }

    private var panelWidth: CGFloat { preview.isHidden ? Palette.width : Palette.browseWidth }

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
    private func makeNutBlock() -> NSStackView {
        nutBlock.setViews([nutTitle, nutMeta], in: .leading)
        nutBlock.orientation = .vertical
        nutBlock.alignment = .leading
        nutBlock.spacing = 2
        nutBlock.edgeInsets = NSEdgeInsets(top: 10, left: Palette.pad, bottom: 10, right: Palette.pad)
        // A long title must give way, not widen the panel: low resistance, hard right edge.
        for label in [nutTitle, nutMeta] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.trailingAnchor.constraint(equalTo: nutBlock.trailingAnchor, constant: -Palette.pad).isActive = true
        }
        return nutBlock
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

    /// One fixed-width column: header, nut, field, list, footer, separated by
    /// hairlines. Every row is pinned to the panel width so nothing reflows.
    private func assemble(in background: NSVisualEffectView) {
        let header = makeHeader()
        let nut = makeNutBlock()
        let fieldBox = makeFieldBox()
        let footer = makeFooter()
        let topLine = separatorLine()
        let line = separatorLine()
        fieldLine.boxType = .separator

        let listArea = makeListArea()
        let stack = NSStackView(views: [header, topLine, nut, fieldLine, fieldBox, line, listArea, footer])
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
        for row in [header, topLine, nut, fieldLine, fieldBox, line, listArea, footer] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        scrollHeight = listArea.heightAnchor.constraint(equalToConstant: 200)
        scrollHeight.isActive = true
        // The panel's width is a constraint rather than a `setContentSize`
        // argument. The content view's constraints determine its size, which
        // means autolayout owns the width: a `setContentSize` that disagrees
        // is overruled on the next pass, and the panel snaps back to the
        // narrowest its content allows. Browse found that out by coming up at
        // 445 points instead of 1040.
        panelWidthConstraint = stack.widthAnchor.constraint(equalToConstant: Palette.width)
        panelWidthConstraint.isActive = true
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
    private var panelWidthConstraint: NSLayoutConstraint!


    // MARK: Showing

    var isVisible: Bool { panel.isVisible }

    /// `focusingNote` puts the caret straight in the reason field. Used by the
    /// toast's "Why?": the nut is already saved and the only thing left to do
    /// is type the sentence that was skipped.
    func show(_ mode: PaletteMode, focusingNote: Bool = false) {
        if case .capture(let ctx) = self.mode, case .browse = mode, panel.isVisible { cameFrom = ctx }
        if case .capture = mode { cameFrom = nil }
        self.mode = mode
        resetChrome()
        switch mode {
        case .capture(let ctx): showCapture(ctx)
        case .edit(let nut): showEdit(nut)
        case .browse: showBrowse()
        }
        present()
        if focusingNote { focusField() }
    }

    /// What every mode starts from, before it fills in its own text.
    private func resetChrome() {
        existing = nil
        logo.isHidden = false
        titleLabel.stringValue = "Nutip"
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.stringValue = Settings.folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? ""
        nutBlock.isHidden = false
        fieldLine.isHidden = false
        setPreview(false)
        // Leaving browse: the pinned #tag chips belong to the search field,
        // not to the note, and there is no way to remove them from here.
        activeTags = []
        activeFacets = []
        suggestions = []
        facetSuggestions = []
        renderChips()
    }

    private func showCapture(_ ctx: CaptureContext) {
        tags = Settings.tags
        checked = []
        nutTitle.stringValue = ctx.suggestedTitle
        var sub = ctx.source
        if let url = ctx.url { sub += " · \(url)" }
        else if !ctx.selection.isEmpty { sub += " · \(ctx.selection.excerpt(90))" }
        if ctx.isEmpty {
            nutTitle.stringValue = "Nothing copied"
            sub = "Copy something with ⌘C, then press the hotkey again. ⌘F searches what you saved."
            nutMeta.textColor = .secondaryLabelColor
        } else if ctx.isStale {
            sub = "Same clipboard as your last nut. Copy something new, or save it again."
            nutMeta.textColor = .systemOrange
        } else if let url = ctx.url, let dup = Index.existing(url: url) {
            existing = dup
            sub = "Already saved \(Dates.relative(dup.capturedAt))"
                + (dup.tags.isEmpty ? "" : " · " + dup.tags.map { "#\($0)" }.joined(separator: " "))
                + " · ⌘O opens it"
            nutMeta.textColor = .systemOrange
        } else {
            nutMeta.textColor = .secondaryLabelColor
        }
        nutMeta.stringValue = sub
        field.stringValue = ""
        field.placeholderString = "Why are you saving this? (optional, press ←)"
        showTagHints()
        setButtons([("Browse", "⌘F", #selector(browsePressed), false), ("Cancel", "esc", #selector(cancelPressed), false),
                    ("Save", "→", #selector(confirmPressed), true)])
    }

    private func showEdit(_ nut: Nut) {
        tags = (Settings.tags + nut.tags).uniquedTags()
        checked = Set(nut.tags.map(\.tagKey))
        nutTitle.stringValue = nut.title
        nutMeta.textColor = .secondaryLabelColor
        nutMeta.stringValue = "Editing · \(nut.source) · \(Dates.relative(nut.capturedAt))"
        field.stringValue = nut.why
        field.placeholderString = "Why did you save this? (optional)"
        showTagHints()
        setButtons([("Back", "esc", #selector(cancelPressed), false), ("Save", "→", #selector(confirmPressed), true)])
    }

    private func showBrowse() {
        nutBlock.isHidden = true
        fieldLine.isHidden = true
        field.stringValue = ""
        setPreview(true)
        renderChips()   // sets the placeholder, with or without chips
        // The placeholder in the field already says "# tag  @ filter". What it
        // cannot say is that the list is something you read rather than search.
        hints.stringValue = "↑↓ reads through them"
        var specs: [(String, String, Selector, Bool)] = []
        if cameFrom != nil { specs.append(("Back", "esc", #selector(cancelPressed), false)) }
        specs += [("Delete", "⌘D", #selector(deletePressed), false), ("Edit", "⌘E", #selector(editPressed), false),
                  ("Open Link", "⌘↩", #selector(openLinkPressed), false), ("Open File", "↩", #selector(confirmPressed), true)]
        setButtons(specs)
        results = Index.search("", limit: Palette.pageSize)
        exhausted = results.count < Palette.pageSize
    }

    /// Size the list, put the panel on screen, and start listening for keys.
    private func present() {
        if !panel.isVisible { placed = false }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        updatePreview()
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
    /// Save, or Open File: the same key in the same place, named for whatever
    /// the mode makes of it.
    @objc private func confirmPressed() { confirm(command: false) }
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
    @objc private func editPressed() { if let nut = selectedClip { show(.edit(nut)) } }
    @objc private func deletePressed() { if let nut = selectedClip { confirmDelete(nut) } }

    func hide() {
        removeMonitor()
        cameFrom = nil
        placed = false
        panel.orderOut(nil)
    }

    /// Whether the panel has been put somewhere on screen. Until it has,
    /// `resize` leaves the position alone and `place` decides it.
    private var placed = false

    /// How many nut rows fit. Browse is a list: it should use the screen it
    /// is on, not a number picked for a laptop. Everything but the list —
    /// header, field, chips, buttons — is about 260pt, and the panel stops at
    /// three quarters of the usable height so it never runs off the bottom.
    private func maxNutRows(_ rowHeight: CGFloat) -> Int {
        let screen = (panel.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame.height
        return max(3, Int((screen * 0.75 - 260) / rowHeight))
    }

    private func resize() {
        let rows = table.numberOfRows
        if suggesting {
            empty.stringValue = currentAtToken != nil ? "No filter matches." : "No tag matches."
        } else if case .browse = mode {
            empty.stringValue = field.stringValue.trimmed.isEmpty && activeFacets.isEmpty && activeTags.isEmpty
                ? "Nothing saved yet. Copy something, then press \(Hotkey.current.label)."
                : "No nuts match. Try the other language, or ⌫ to drop a filter."
        } else {
            empty.stringValue = "No tags yet. Add some in Settings."
        }
        empty.isHidden = rows > 0
        // Taller rows, so fewer of them: eight nut rows plus the chrome runs
        // past the bottom of a laptop screen. And rows are not all the same
        // height — only one carrying a matched passage is three lines — so the
        // panel adds up the rows it will actually show instead of multiplying
        // the first one and being wrong about all the others.
        let visible = max(1, min(rows, showsTagRows ? Palette.maxRows : maxNutRows(Palette.nutRowHeight)))
        let height = (0..<visible).reduce(CGFloat(0)) { $0 + self.tableView(self.table, heightOfRow: $1) }
        scrollHeight.constant = rows == 0 ? 56 : height + 4
        panel.layoutIfNeeded()
        // Measured from where the panel is *now*, not from a y remembered at
        // the first show: the panel is draggable, and browse is wider than a
        // capture, so both edges move. A list that grows or shrinks must still
        // leave the header where the eye left it.
        let before = panel.frame
        panelWidthConstraint.constant = panelWidth
        panel.layoutIfNeeded()
        panel.setContentSize(NSSize(width: panelWidth, height: panel.contentView!.fittingSize.height))
        if placed {
            panel.setFrameOrigin(NSPoint(x: before.midX - panel.frame.width / 2,
                                         y: before.maxY - panel.frame.height))
        }
    }

    /// Only ever called for a panel with no anchor yet: `resize` has already
    /// moved an anchored one, immediately before, every time.
    private func place() {
        guard !placed else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2)
        panel.setFrameOrigin(origin)
        placed = true
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
        if key.code == Key.right {
            // Only from the end of the note, so → still moves the caret inside it.
            if !key.command, fieldIsEditing, let editor = field.currentEditor(),
               editor.selectedRange.location < editor.string.count { return false }
            confirm(command: false, dropTags: key.command)
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
        if key.code == Key.delete, !key.command, field.stringValue.isEmpty,
           !activeTags.isEmpty || !activeFacets.isEmpty {
            removeLastChip()
            return true
        }
        if key.command, key.chars == "e", let nut = selectedClip { show(.edit(nut)); return true }
        // ⌘D, not ⌘⌫: ⌫ is how you edit the search field, and pairing it with
        // ⌘ put deleting a nut one slipped modifier away from erasing a word.
        if key.command, key.chars == "d", let nut = selectedClip {
            confirmDelete(nut)
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
        if isTagMode { showTagHints() }
    }

    private func toggleSelected() {
        guard table.selectedRow >= 0 else { return }
        toggle(index: table.selectedRow)
    }

    /// The tags a save would write. Ticked ones if there are any; otherwise
    /// the highlighted row, so tagging with one tag is a single key. Editing a
    /// nut is exempt: unticking everything there means "no tags", and must.
    private var pickedTags: [String] {
        let ticked = tags.filter { checked.contains($0.tagKey) }
        guard ticked.isEmpty, case .capture = mode,
              table.selectedRow >= 0, table.selectedRow < tags.count else { return ticked }
        return [tags[table.selectedRow]]
    }

    /// The footer says what → is about to write, since a highlighted row and a
    /// ticked one do not mean the same thing.
    private func showTagHints() {
        let ticked = tags.filter { checked.contains($0.tagKey) }
        if !ticked.isEmpty {
            hints.stringValue = "Saving with " + ticked.map { "#\($0)" }.joined(separator: " ") + " · ↩ toggles · ← note"
        } else if let one = pickedTags.first {
            hints.stringValue = "→ saves with #\(one) · ↩ adds more · ⌘→ none · ← note"
        } else {
            hints.stringValue = "↩ or 1–9 tags this nut · ← note"
        }
    }

    private func toggle(index: Int) {
        guard index < tags.count else { return }
        let tag = tags[index]
        if checked.contains(tag.tagKey) { checked.remove(tag.tagKey) } else { checked.insert(tag.tagKey) }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        showTagHints()
    }

    private func confirm(command: Bool, dropTags: Bool = false) {
        switch mode {
        case .capture(let ctx):
            let why = field.stringValue
            hide()
            delegate?.palette(self, didCapture: ctx, tags: dropTags ? [] : pickedTags, why: why)
        case .edit(var nut):
            nut.tags = tags.filter { checked.contains($0.tagKey) }
            nut.why = field.stringValue.trimmed
            hide()
            delegate?.palette(self, didEdit: nut)
        case .browse:
            guard let nut = selectedClip else { return }
            if command, let url = nut.url.flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(url)
            } else {
                open(nut)
            }
            hide()
        }
    }

    /// Blue pills for the pinned tags, Slack-style.
    private func renderChips() {
        chips.views.forEach { $0.removeFromSuperview() }
        for facet in activeFacets { chips.addArrangedSubview(pill(facet.label, colour: .systemGray)) }
        for tag in activeTags { chips.addArrangedSubview(pill("#\(tag)", colour: .controlAccentColor)) }
        let noChips = activeTags.isEmpty && activeFacets.isEmpty
        chips.isHidden = noChips
        fieldGap.constant = noChips ? -2 : 8
        field.placeholderString = noChips ? "Search nuts…    # tag    @ filter" : "Search in these…"
    }

    /// One chip. A facet is grey and a tag keeps the accent colour: the eye
    /// has to tell "saved this week" from "tagged week" without reading.
    private func pill(_ text: String, colour: NSColor) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = colour.cgColor
        pill.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: text)
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
        return pill
    }

    /// Browse query without any `#…` token: those are chips, not words.
    private var searchText: String {
        field.stringValue.replacingOccurrences(of: "[#@][^\\s#@]*", with: "", options: .regularExpression).trimmed
    }

    private func refreshBrowse() {
        if let partial = currentHashToken {
            facetSuggestions = []
            suggestions = Settings.tags.filter { !activeTags.containsTag($0) && (partial.isEmpty || $0.tagKey.hasPrefix(partial.tagKey)) }
        } else if let partial = currentAtToken {
            suggestions = []
            facetSuggestions = Index.facets(matching: partial).filter { f in !activeFacets.contains(f) }
        } else {
            suggestions = []
            facetSuggestions = []
            results = Index.search(searchText, tags: activeTags, facets: activeFacets,
                                   limit: Palette.pageSize)
            exhausted = results.count < Palette.pageSize
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updatePreview()
        resize()
    }

    @objc private func listScrolled() { loadNextPage() }

    /// The next page, once the scroller is within a screenful of the end.
    /// Browse used to stop at fifty without saying so: the list simply ended,
    /// and a folder of five thousand nuts looked like a folder of fifty.
    ///
    /// Nothing is resized here. A list only pages once it scrolls, which means
    /// it is already as tall as it is allowed to be; calling `resize` would
    /// move the panel under a hand that is in the middle of scrolling it.
    private func loadNextPage() {
        guard case .browse = mode, !suggesting, !exhausted, !loadingPage else { return }
        let clip = scroll.contentView.bounds
        guard table.bounds.height - clip.maxY < clip.height else { return }
        loadingPage = true
        defer { loadingPage = false }
        let start = results.count
        let page = Index.search(searchText, tags: activeTags, facets: activeFacets,
                                limit: Palette.pageSize, offset: start)
        guard !page.isEmpty else { exhausted = true; return }
        exhausted = page.count < Palette.pageSize
        results += page
        table.insertRows(at: IndexSet(start..<results.count), withAnimation: [])
    }

    /// What the pane shows, kept in step with the highlighted row.
    private func updatePreview() {
        guard case .browse = mode else { return }
        if suggesting {
            preview.clear(currentAtToken != nil ? "Pick a filter." : "Pick a tag.")
            return
        }
        guard let nut = selectedClip else {
            preview.clear(results.isEmpty ? "Nothing to show." : "Nothing highlighted.")
            return
        }
        preview.show(nut, body: body(of: nut))
    }

    /// An index row carries no body — that is what makes the index cheap — so
    /// the file is read here, once, and kept while the row stays highlighted.
    /// A nut whose file has gone shows its frontmatter and an empty page
    /// rather than stopping the browse.
    private func body(of nut: Nut) -> String {
        if nut.bodyLoaded { return nut.body }
        if let cached = previewCache, cached.path == nut.path { return cached.body }
        let loaded = ((try? Store.read(path: nut.path)) ?? nil)?.body ?? ""
        previewCache = (nut.path, loaded)
        return loaded
    }

    /// Tab / return on a suggestion: the `#partial` becomes a chip.
    private func pickSuggestion() {
        guard suggesting else { return }
        let row = max(0, table.selectedRow)
        if currentAtToken != nil {
            guard row < facetSuggestions.count else { return }
            activeFacets.append(facetSuggestions[row])
        } else {
            guard row < suggestions.count else { return }
            activeTags.append(suggestions[row])
        }
        field.stringValue = field.stringValue.replacingOccurrences(of: "[#@][^\\s#@]*$", with: "", options: .regularExpression)
        renderChips()
        refreshBrowse()
        focusField()
    }

    private func removeLastChip() {
        // Newest chip first, whichever kind it is.
        if !activeFacets.isEmpty { activeFacets.removeLast() }
        else if !activeTags.isEmpty { activeTags.removeLast() }
        else { return }
        renderChips()
        refreshBrowse()
    }

    private func open(_ nut: Nut) {
        if let file = nut.fileURL { NSWorkspace.shared.open(file) }
    }

    private func confirmDelete(_ nut: Nut) {
        let alert = NSAlert()
        alert.messageText = "Move “\(nut.title)” to the Trash?"
        alert.informativeText = nut.path
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            delegate?.palette(self, didDelete: nut)
            refreshBrowse()
        }
        panel.makeKeyAndOrderFront(nil)
        focusField()
    }

    private var selectedClip: Nut? {
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
        if isTagMode { return tags.count }
        if currentAtToken != nil { return facetSuggestions.count }
        if suggesting { return suggestions.count }
        return results.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if showsTagRows { return Palette.tagRowHeight }
        // Three lines when the search has a passage to show, two when it does
        // not: browsing the most recent nuts should not leave a gap per row.
        let hasMatch = row < results.count && !results[row].match.isEmpty
        return hasMatch ? Palette.matchRowHeight : Palette.nutRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isTagMode {
            let cell = tableView.makeView(withIdentifier: TagCell.id, owner: nil) as? TagCell ?? TagCell()
            let tag = tags[row]
            cell.set(number: row < 9 ? "\(row + 1)" : "", tag: tag, checked: checked.contains(tag.tagKey))
            return cell
        }
        if currentAtToken != nil {
            let cell = tableView.makeView(withIdentifier: TagCell.id, owner: nil) as? TagCell ?? TagCell()
            cell.set(number: "@", tag: facetSuggestions[row].label, checked: false, hint: "tab")
            return cell
        }
        if suggesting {
            let cell = tableView.makeView(withIdentifier: TagCell.id, owner: nil) as? TagCell ?? TagCell()
            cell.set(number: "#", tag: suggestions[row], checked: false, hint: "tab")
            return cell
        }
        let cell = tableView.makeView(withIdentifier: NutCell.id, owner: nil) as? NutCell ?? NutCell()
        cell.set(results[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRow() }

    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
}
