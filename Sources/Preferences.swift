// One window for first launch and for Preferences: folder, tags, permissions,
// hotkey, login item. A classic macOS form: labels in a right-aligned column,
// controls in the other, 20 pt margins, nothing decorative.
import AppKit
import ServiceManagement

final class Preferences: NSObject, NSWindowDelegate, NSTokenFieldDelegate {
    var onChange: (() -> Void)?

    private var window: NSWindow?
    private let folderField = NSTextField(labelWithString: "")
    private let tagsField = NSTokenField()
    private let hotkeyPopup = NSPopUpButton()
    private let loginCheck = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)

    private static let width: CGFloat = 560
    private static let margin: CGFloat = 20

    func show(firstRun: Bool) {
        if window == nil { build(firstRun: firstRun) }
        refresh()
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
            [NSGridCell.emptyContentView, hint("Return or comma adds a tag, backspace removes one. The first nine answer to keys 1–9 in the palette.")],
            [label("How it works:"), howItWorks()],
            [label("Shortcut:"), hotkeyControl()],
            [NSGridCell.emptyContentView, loginControl()],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.column(at: 1).width = Preferences.width - 2 * Preferences.margin - 100 - 12
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

    /// A token field: type a name, press return or comma, it becomes a token;
    /// backspace removes one. The native macOS way to edit a list of words.
    private func tagsBox() -> NSTokenField {
        tagsField.delegate = self
        tagsField.tokenStyle = .rounded
        tagsField.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        tagsField.font = .systemFont(ofSize: 13)
        tagsField.placeholderString = "Type a tag and press return"
        tagsField.cell?.wraps = true
        tagsField.cell?.isScrollable = false
        tagsField.translatesAutoresizingMaskIntoConstraints = false
        tagsField.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        tagsField.target = self
        tagsField.action = #selector(tagsEdited)
        return tagsField
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
        let footer = NSStackView(views: [NSView(), done])
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
        tagsField.objectValue = Settings.tags
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

    /// Every token is a slug, so "Pricing Model" becomes pricing-model as you type it.
    func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
        tokens.compactMap { ($0 as? String).map(Slug.tag) }.filter { !$0.isEmpty }
    }

    func controlTextDidEndEditing(_ obj: Notification) { tagsEdited() }

    @objc private func tagsEdited() {
        var tags = (tagsField.objectValue as? [Any] ?? []).compactMap { $0 as? String }
        guard tags != Settings.tags else { return }
        // Backspace on a token is one keystroke; losing a tag should not be.
        let removed = Settings.tags.filter { !tags.contains($0) }
        if !removed.isEmpty {
            let used = Index.count(anyOf: removed)
            let alert = NSAlert()
            alert.messageText = removed.count == 1 ? "Remove the tag “\(removed[0])”?" : "Remove \(removed.count) tags?"
            alert.informativeText = used == 0
                ? "It disappears from the palette. No clip uses it."
                : "It disappears from the palette. The \(used) clip\(used == 1 ? "" : "s") already tagged keep it in their files."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Keep")
            if alert.runModal() != .alertFirstButtonReturn {
                tags = Settings.tags
                tagsField.objectValue = tags
                return
            }
        }
        Settings.tags = tags
        onChange?()
    }

    @objc private func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        if Settings.folder == nil { Settings.folder = Settings.defaultFolder }
        Settings.onboarded = true
        onChange?()
    }
}
