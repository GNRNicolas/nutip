// One window for first launch and for Preferences: folder, tags, permissions,
// hotkey, login item. A classic macOS form: labels in a right-aligned column,
// controls in the other, 20 pt margins, nothing decorative.
import AppKit
import ServiceManagement

final class Preferences: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: (() -> Void)?

    private var window: NSWindow?
    private let folderField = NSTextField(labelWithString: "")
    private let tagTable = NSTableView()
    private let tagButtons = NSSegmentedControl()
    private let tagStatus = NSTextField(labelWithString: "")
    /// Tags as they are being edited. Written to Settings on every change, and
    /// remembered here so a removal can be taken back.
    private var tags: [String] = []
    private var undoStack: [[String]] = []
    private var redoStack: [[String]] = []
    private var keyMonitor: Any?
    private let hotkeyPopup = NSPopUpButton()
    private let loginCheck = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)

    private static let width: CGFloat = 560
    private static let margin: CGFloat = 20

    func show(firstRun: Bool) {
        if window == nil { build(firstRun: firstRun) }
        refresh()
        installUndoMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func build(firstRun: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Preferences.width, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = firstRun ? "Welcome to Nutip" : "Nutip Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let separator = NSBox()
        separator.boxType = .separator
        install([makeHeader(), separator, makeForm(), makeFooter(firstRun: firstRun)], in: window)
    }

    /// Icon, name, and the one sentence that says what the app does.
    private func makeHeader() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "Nutip")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        let tagline = NSTextField(wrappingLabelWithString:
            "Copy anything with ⌘C, then press \(Hotkey.current.label): what you copied becomes a Markdown file in your folder, with your tags and a one-line note.")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        let headerText = NSStackView(views: [name, tagline])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        let header = NSStackView(views: [icon, headerText])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 16
        return header
    }

    /// The form: label column right-aligned, control column fills the rest.
    private func makeForm() -> NSGridView {
        let grid = NSGridView(views: [
            [label("Folder:"), folderRow()],
            [NSGridCell.emptyContentView, hint("One Markdown file per clip, plus INDEX.md. Your Obsidian vault, a Git repo, iCloud Drive: any folder.")],
            [label("Tags:"), tagsBox()],
            [NSGridCell.emptyContentView, tagStatus],
            [label("How it works:"), howItWorks()],
            [label("Shortcut:"), hotkeyControl()],
            [NSGridCell.emptyContentView, loginControl()],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.column(at: 1).width = Preferences.width - 2 * Preferences.margin - 100 - 12
        // The tag list fills the column; a popup or a checkbox stretched to
        // the window edge would look wrong, so only this row is filled.
        grid.cell(atColumnIndex: 1, rowIndex: 2).xPlacement = .fill
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .top }
        grid.cell(atColumnIndex: 0, rowIndex: 0).yPlacement = .center
        grid.cell(atColumnIndex: 0, rowIndex: 5).yPlacement = .center
        // Breathing room between groups, tight between a control and its hint.
        for row in [1, 3, 4] { grid.row(at: row).bottomPadding = 14 }
        return grid
    }

    private func folderRow() -> NSStackView {
        folderField.font = .systemFont(ofSize: 13)
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        let row = NSStackView(views: [folderField, choose])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// A plain list with + and −, the way macOS edits a list of anything.
    /// A text field would let one keystroke wipe every tag.
    private func tagsBox() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        column.resizingMask = .autoresizingMask
        tagTable.addTableColumn(column)
        tagTable.headerView = nil
        tagTable.dataSource = self
        tagTable.delegate = self
        tagTable.rowHeight = 24
        tagTable.style = .plain
        tagTable.usesAlternatingRowBackgroundColors = true
        tagTable.gridStyleMask = [.solidHorizontalGridLineMask]
        tagTable.gridColor = .separatorColor
        tagTable.allowsMultipleSelection = true
        tagTable.doubleAction = #selector(renameSelectedTag)
        tagTable.target = self

        let scroll = NSScrollView()
        scroll.documentView = tagTable
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 108).isActive = true

        tagButtons.segmentStyle = .smallSquare
        tagButtons.segmentCount = 2
        tagButtons.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a tag"), forSegment: 0)
        tagButtons.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove the selected tags"), forSegment: 1)
        tagButtons.setWidth(28, forSegment: 0)
        tagButtons.setWidth(28, forSegment: 1)
        tagButtons.trackingMode = .momentary
        tagButtons.target = self
        tagButtons.action = #selector(tagButtonPressed)
        tagButtons.translatesAutoresizingMaskIntoConstraints = false

        tagStatus.font = .systemFont(ofSize: 11)
        tagStatus.textColor = .secondaryLabelColor
        tagStatus.lineBreakMode = .byTruncatingTail

        let box = NSStackView(views: [scroll, tagButtons])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        scroll.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        return box
    }

    /// One line, because there is nothing to configure.
    private func howItWorks() -> NSTextField {
        let row = NSTextField(wrappingLabelWithString: "Copy anything (⌘C), then press the hotkey. Nutip reads the clipboard: text, a link, or text copied from a web page together with the page it came from. No permission to grant, ever.")
        row.font = .systemFont(ofSize: 13)
        return row
    }

    private func hotkeyControl() -> NSPopUpButton {
        hotkeyPopup.removeAllItems()
        for key in Hotkey.presets { hotkeyPopup.addItem(withTitle: key.label) }
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)
        return hotkeyPopup
    }

    private func loginControl() -> NSButton {
        loginCheck.target = self
        loginCheck.action = #selector(loginChanged)
        return loginCheck
    }

    private func makeFooter(firstRun: Bool) -> NSStackView {
        let done = NSButton(title: firstRun ? "Start Clipping" : "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        // Nutip has no Dock icon and no menu bar of its own, so the only way
        // out is the tray menu. This window is the other one.
        let quit = NSButton(title: "", target: self, action: #selector(quit))
        quit.bezelStyle = .roundRect
        quit.controlSize = .small
        let title = NSMutableAttributedString(string: "Quit Nutip", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(string: "  ⌘Q", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor]))
        quit.attributedTitle = title
        let footer = NSStackView(views: [quit, NSView(), done])
        footer.orientation = .horizontal
        return footer
    }

    /// Stacks the rows with the window's margins and sizes the window to fit.
    private func install(_ rows: [NSView], in window: NSWindow) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Preferences.margin
        stack.edgeInsets = NSEdgeInsets(top: Preferences.margin, left: Preferences.margin,
                                        bottom: Preferences.margin, right: Preferences.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let inner = Preferences.width - 2 * Preferences.margin
        for row in rows { row.widthAnchor.constraint(equalToConstant: inner).isActive = true }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Preferences.width),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        l.alignment = .right
        return l
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    // MARK: State

    private func refresh() {
        folderField.stringValue = (Settings.folder ?? Settings.defaultFolder).path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        tags = Settings.tags
        tagTable.reloadData()
        showTagHint()
        hotkeyPopup.selectItem(at: Hotkey.presets.firstIndex(of: Hotkey.current) ?? 0)
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }


    // MARK: Actions

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.directoryURL = Settings.folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        if panel.runModal() == .OK, let url = panel.url {
            Settings.folder = url
            refresh()
            onChange?()
        }
    }


    @objc private func hotkeyChanged() {
        Hotkey.current = Hotkey.presets[max(0, hotkeyPopup.indexOfSelectedItem)]
        onChange?()
    }

    @objc private func loginChanged() {
        do {
            if loginCheck.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Tags

    func numberOfRows(in tableView: NSTableView) -> Int { tags.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: TagRow.id, owner: nil) as? TagRow ?? TagRow()
        cell.field.stringValue = tags[row]
        cell.field.target = self
        cell.field.action = #selector(tagRenamed)
        return cell
    }

    @objc private func tagButtonPressed() {
        tagButtons.selectedSegment == 0 ? addTag() : removeSelectedTags()
    }

    private func addTag() {
        remember()
        tags.append("")
        tagTable.reloadData()
        let row = tags.count - 1
        tagTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tagTable.scrollRowToVisible(row)
        tagTable.editColumn(0, row: row, with: nil, select: true)
        tagStatus.stringValue = "Type the tag, then press return."
    }

    /// No confirmation: ⌘Z takes it back, which is the macOS answer to a
    /// removal, and it costs nothing when the removal was intended.
    private func removeSelectedTags() {
        let rows = tagTable.selectedRowIndexes.sorted(by: >)
        guard !rows.isEmpty else { return }
        remember()
        let removed = rows.reversed().map { tags[$0] }
        for row in rows { tags.remove(at: row) }
        commit()
        let used = Index.count(anyOf: removed)
        let names = removed.map { "#\($0)" }.joined(separator: " ")
        tagStatus.stringValue = used == 0
            ? "Removed \(names). No clip used it. ⌘Z to undo."
            : "Removed \(names). The \(used) clip\(used == 1 ? "" : "s") already tagged keep it in their files. ⌘Z to undo."
    }

    @objc private func renameSelectedTag() {
        let row = tagTable.selectedRow
        guard row >= 0, row < tags.count else { return }
        tagTable.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func tagRenamed(_ sender: NSTextField) {
        let row = tagTable.row(for: sender)
        guard row >= 0, row < tags.count else { return }
        let name = Slug.tag(sender.stringValue)
        let wasBlank = tags[row].isEmpty
        // An empty name, or one that already exists, is not a tag: undo the row.
        guard !name.isEmpty, !tags.enumerated().contains(where: { $0.offset != row && $0.element.tagKey == name.tagKey }) else {
            if wasBlank { tags.remove(at: row) } // the row + just added, abandoned
            tagTable.reloadData()
            showTagHint()
            return
        }
        if !wasBlank { remember() }   // a rename is undoable too; an add already remembered
        tags[row] = name
        commit()
        tagTable.reloadData()
        showTagHint()
    }

    private func showTagHint() {
        tagStatus.stringValue = "Double-click to rename."
    }

    // MARK: Undo

    /// One snapshot per change. Shallow and bounded: this is a list of words.
    private func remember() {
        undoStack.append(tags)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func commit() {
        tags = tags.map(Slug.tag).uniquedTags()
        Settings.tags = tags
        tagTable.reloadData()
        onChange?()
    }

    @objc private func undoTags() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(tags)
        tags = previous
        commit()
        tagStatus.stringValue = "Undone. ⇧⌘Z to redo."
    }

    @objc private func redoTags() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(tags)
        tags = next
        commit()
        tagStatus.stringValue = "Redone. ⌘Z to undo."
    }

    /// The app has no menu bar (it is an agent app), so ⌘Z has to be caught
    /// here. Only while this window is the key one.
    private func installUndoMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            // By key code, not by character: those letters are elsewhere on AZERTY.
            switch UInt32(event.keyCode) {
            case KeyCodes.forCharacter("z"):
                flags.contains(.shift) ? self.redoTags() : self.undoTags()
                return nil
            case KeyCodes.forCharacter("q"):
                self.quit()
                return nil
            case KeyCodes.forCharacter("w"):
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    private func removeUndoMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @objc private func close() { window?.close() }

    @objc private func quit() {
        window?.close()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        removeUndoMonitor()
        if Settings.folder == nil { Settings.folder = Settings.defaultFolder }
        Settings.onboarded = true
        onChange?()
    }
}

/// One tag in the list: a label that turns into a field on a double-click.
private final class TagRow: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("tagRow")
    let field = NSTextField()

    init() {
        super.init(frame: .zero)
        identifier = TagRow.id
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
