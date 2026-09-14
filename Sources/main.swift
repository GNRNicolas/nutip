// Nutip: save anything as Markdown, for you and your AI.
// Menu bar app: one hotkey, one palette, one folder of files.
import AppKit
import ServiceManagement

// Arguments mean the CLI was invoked (`nutip search …`); no GUI in that case.
if CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(0) }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, PaletteDelegate {
    private var statusItem: NSStatusItem!
    /// Last folder this app acted on, to notice when a command changes it.
    private var currentFolder: URL?
    private let hotkey = GlobalHotkey()
    private let palette = Palette()
    private let toast = Toast()
    private let preferences = Preferences()
    private var lastClip: Clip?

    private let clipItem = NSMenuItem(title: "Clip Now", action: #selector(clipNow), keyEquivalent: "")
    private let undoItem = NSMenuItem(title: "Undo Last Clip", action: #selector(undoLast), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let autoUpdateItem = NSMenuItem(title: "Check for Updates Automatically", action: #selector(toggleAutoUpdate), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launching Nutip when it is already running — from Spotlight, from
        // the Applications folder, from `open -a` — used to do nothing at all
        // that the eye could see: a menu-bar app has no window and no Dock
        // icon to bring forward, so macOS activated a process that shows
        // nothing. Hand the gesture to the copy already running, which answers
        // it by opening the palette, and get out of its way.
        if handOverToRunningCopy() { return }
        Log.write("launch \(Updater.currentVersion)")

        palette.delegate = self
        preferences.onChange = { [weak self] in self?.settingsChanged() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Nutip")
        statusItem.button?.image?.isTemplate = true
        buildMenu()

        registerHotkey()
        currentFolder = Settings.folder
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(defaultsChanged),
                                                            name: Settings.changedNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(browse),
                                                            name: Settings.openNotification, object: nil)
        if Settings.folder != nil {
            let changed = Index.open()
            Store.regenerateIndexes(full: changed)
        }
        if !Settings.onboarded || Settings.folder == nil {
            preferences.show(firstRun: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Updater.check(manual: false) }
        installTestHooks()
    }

    /// `kill -USR1 <pid>` opens the palette in browse mode, `-USR2` in capture
    /// mode with a fake page, `-INFO` opens Preferences. Lets a script drive
    /// the UI without a mouse; harmless otherwise.
    private var signalSources: [DispatchSourceSignal] = []
    private func installTestHooks() {
        let hooks: [(Int32, () -> Void)] = [
            (SIGUSR1, { [weak self] in self?.palette.show(.browse) }),
            (SIGUSR2, { [weak self] in
                let ctx = CaptureContext(appName: "Safari", selection: "Markdown is a lightweight markup language.",
                                         url: "https://en.wikipedia.org/wiki/Markdown",
                                         pageTitle: "Markdown - Wikipedia", changeCount: -2)
                self?.palette.show(.capture(ctx))
            }),
            (SIGINFO, { [weak self] in self?.preferences.show(firstRun: false) }),
        ]
        for (sig, action) in hooks {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: action)
            source.resume()
            signalSources.append(source)
        }
    }

    /// True when another copy is already running and has been asked to open
    /// the palette: this process has nothing left to do. Two running copies
    /// would answer the same hotkey twice, so one of them has to go, and the
    /// one that keeps the open index and the registered hotkey is the old one.
    private func handOverToRunningCopy() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Settings.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
        Log.write("launch: already running, asked it to open the palette")
        NSApp.terminate(nil)
        return true
    }

    /// The Dock, Spotlight or Finder asking for an app with no window: show
    /// the one thing worth showing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Log.write("reopen: opening the palette")
        browse()
        return true
    }

    private func buildMenu() {
        // These items are properties, so a second call would hand NSMenu an
        // item that already belongs to a menu: that is an assertion failure,
        // and the app dies on the spot.
        for item in [clipItem, undoItem, loginItem, autoUpdateItem] { item.menu?.removeItem(item) }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(clipItem)
        menu.addItem(NSMenuItem(title: "Search Clips…", action: #selector(browse), keyEquivalent: ""))
        menu.addItem(undoItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Clips Folder", action: #selector(openFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Rebuild Index", action: #selector(reindex), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: ""))
        menu.addItem(autoUpdateItem)
        menu.addItem(NSMenuItem(title: "Nutip on GitHub", action: #selector(openRepository), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Nutip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.target == nil { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        clipItem.title = "Clip Now   \(Hotkey.current.label)"
        undoItem.isEnabled = lastClip != nil
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        autoUpdateItem.state = Updater.automatic ? .on : .off
    }

    private func registerHotkey() {
        hotkey.register(Hotkey.current) { [weak self] in self?.clipNow() }
    }

    private func settingsChanged() {
        registerHotkey()
        if Settings.folder != nil {
            let changed = Index.open()
            Store.regenerateIndexes(full: changed)
        }
    }

    /// `nutip folder …` or `nutip tags …` writes the same preferences this app
    /// is reading. Follow them instead of making the user relaunch.
    @objc private func defaultsChanged() {
        Settings.defaults.synchronize()
        guard Settings.folder != currentFolder else { return }
        currentFolder = Settings.folder
        Log.write("folder set from outside: \(currentFolder?.path ?? "(none)")")
        settingsChanged()
    }

    // MARK: Capture

    @objc private func clipNow() {
        guard Settings.folder != nil else { preferences.show(firstRun: true); return }
        if palette.isVisible { palette.hide(); return }
        let ctx = Capture.current()
        if ctx.isEmpty {
            palette.show(.browse)
        } else {
            palette.show(.capture(ctx))
        }
    }

    @objc private func browse() {
        guard Settings.folder != nil else { preferences.show(firstRun: true); return }
        palette.show(.browse)
    }

    func palette(_ palette: Palette, didCapture ctx: CaptureContext, tags: [String], why: String) {
        do {
            let clip = try Store.add(title: ctx.suggestedTitle, url: ctx.url, source: ctx.source,
                                     tags: tags, why: why, body: ctx.selection.trimmed)
            lastClip = clip
            Capture.lastSavedChangeCount = ctx.changeCount
            let detail = tags.isEmpty ? clip.path : tags.map { "#\($0)" }.joined(separator: " ") + " · " + clip.path
            toast.show("Saved “\(clip.title.excerpt(40))”", detail: detail) { [weak self] in self?.undoLast() }
            Log.write("saved \(clip.path)")
            if let url = ctx.url.flatMap(URL.init(string:)) { extract(url, into: clip) }
        } catch {
            Log.write("save failed: \(error.localizedDescription)")
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Fetches the page after the palette has closed, and completes the file.
    /// The title on disk is the browser's until the article gives a better one.
    private func extract(_ url: URL, into clip: Clip) {
        Extractor.shared.extract(url) { [weak self] result in
            guard let result else { return }
            guard var current = try? Store.read(path: clip.path) else { return }
            // Undo may have removed the file in the meantime.
            guard FileManager.default.fileExists(atPath: current.fileURL?.path ?? "") else { return }
            if current.title == url.domain || current.title.isEmpty, !result.title.isEmpty {
                current.title = result.title
            }
            var article = result.markdown
            if !result.byline.isEmpty { article = "*\(result.byline)*\n\n" + article }
            do {
                try Store.save(current)
                try Store.append(article, to: current)
                if self?.lastClip?.path == clip.path { self?.lastClip = try Store.read(path: clip.path) }
                Log.write("extracted \(result.markdown.count) chars into \(clip.path)")
            } catch {
                Log.write("extract save failed: \(error.localizedDescription)")
            }
        }
    }

    func paletteWantsSettings(_ palette: Palette) { preferences.show(firstRun: false) }

    func palette(_ palette: Palette, didEdit clip: Clip) {
        do { try Store.save(clip) } catch { Log.write("edit failed: \(error.localizedDescription)") }
    }

    func palette(_ palette: Palette, didDelete clip: Clip) {
        do {
            try Store.delete(clip)
            if lastClip?.path == clip.path { lastClip = nil }
        } catch { Log.write("delete failed: \(error.localizedDescription)") }
    }

    @objc private func undoLast() {
        guard let clip = lastClip else { return }
        toast.dismiss()
        // The clipboard is fair game again: undoing a clip is not "already saved".
        Capture.lastSavedChangeCount = -1
        do {
            try Store.delete(clip)
            Log.write("undo \(clip.path)")
        } catch {
            Log.write("undo failed: \(error.localizedDescription)")
        }
        lastClip = nil
    }

    // MARK: Menu actions

    @objc private func openFolder() {
        guard let folder = Settings.folder else { preferences.show(firstRun: true); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func reindex() {
        Index.open()
        Index.rebuild()
        Store.regenerateIndexes(full: true)
    }

    @objc private func showPreferences() { preferences.show(firstRun: false) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { Log.write("login item: \(error.localizedDescription)") }
    }

    @objc private func checkUpdates() { Updater.check(manual: true) }
    @objc private func toggleAutoUpdate() { Updater.automatic.toggle() }
    @objc private func openRepository() { NSWorkspace.shared.open(Updater.homepage) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
