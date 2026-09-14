// `nutip search|recent|add|tags|reindex|path`: the same folder and index,
// from a terminal or a script. Runs when the binary gets arguments, without
// starting the GUI. Prints plain text by default, JSON with --json.
import Foundation

enum CLI {
    static let usage = """
    Usage:
      nutip recent [N] [--json]          the N most recent clips (default 20)
      nutip search <query> [--json]      full-text search; #tag restricts to a tag
      nutip add <url|text> [--tag t]... [--why "..."] [--title "..."] [--extract]
                                         save a clip; --extract also reads the page
      nutip rm <path>                    move a clip to the Trash and update the indexes
      nutip extract <url>                print a page as Markdown (what a clip gets)
      nutip tags                         the configured tags
      nutip tags add <tag>...            add tags to the palette (also: rm)
      nutip folder [path]                the clips folder; with a path, move to it
      nutip reindex                      rebuild INDEX.md, tags/*.md and the search index
      nutip doctor                       permissions, folder, hotkey
      nutip --help

    NUTIP_DIR=<folder> overrides the clips folder for one command.
    """

    /// True when the arguments were a CLI command and the process should exit.
    static func run(_ args: [String]) -> Bool {
        guard let command = args.first else { return false }
        var rest = Array(args.dropFirst())
        let json = rest.contains("--json")
        rest.removeAll { $0 == "--json" }

        switch command {
        case "--help", "-h", "help":
            print(usage)
        case "doctor":
            print("app        \(Bundle.main.bundlePath)")
            print("folder     \(Settings.folder?.path ?? "(none)")")
            print("hotkey     \(Hotkey.current.label)")
            print("permissions none needed: copy, then press the hotkey")
            print("tags       \(Settings.tags.joined(separator: ", "))")
            print("log        ~/Library/Logs/nutip.log")
        case "path", "folder":
            folder(rest)
        case "tags":
            tags(rest)
        case "reindex":
            Index.open()
            let started = Date()
            let n = Index.rebuild()
            Store.regenerateIndexes(full: true)
            print("reindexed \(n) clip\(n == 1 ? "" : "s") in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        case "recent":
            Index.open()
            let n = rest.first.flatMap(Int.init) ?? 20
            emit(Index.search("", limit: n), json: json)
        case "search":
            Index.open()
            let query = rest.joined(separator: " ")
            guard !query.trimmed.isEmpty else { fail("search needs a query") }
            emit(Index.search(query, limit: 50), json: json)
        case "add":
            add(rest)
        case "rm", "remove", "delete":
            guard let path = rest.first else { fail("rm needs the path of a clip") }
            remove(path)
        case "extract":
            guard let url = rest.first.flatMap(URL.init(string:)), url.absoluteString.isURL else { fail("extract needs a URL") }
            extract(url)
        default:
            return false
        }
        return true
    }

    /// `nutip folder` prints it, `nutip folder <path>` moves to it. An agent
    /// setting Nutip up has no other way in: everything else is in a window.
    private static func folder(_ rest: [String]) {
        guard let raw = rest.first else {
            print(Settings.folder?.path ?? "(no folder set)")
            return
        }
        if ProcessInfo.processInfo.environment["NUTIP_DIR"] != nil {
            fail("NUTIP_DIR is set: it overrides the folder for this command, so setting one would have no effect")
        }
        let path = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { fail("\(url.path) is a file, not a folder") }
        } else {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { fail("cannot create \(url.path): \(error.localizedDescription)") }
        }
        Settings.folder = url
        Index.open()
        Store.regenerateIndexes(full: true)
        print(url.path)
        if announce(), isAppRunning() {
            print("Nutip is running: it has switched to this folder.")
        }
    }

    /// `nutip tags` lists them, `nutip tags add|rm <tag>...` edits the list the
    /// palette offers. Existing clips keep whatever they were tagged with.
    private static func tags(_ rest: [String]) {
        guard let verb = rest.first else {
            Settings.tags.forEach { print($0) }
            return
        }
        let names = Array(rest.dropFirst()).map(Slug.tag).filter { !$0.isEmpty }
        switch verb {
        case "add":
            guard !names.isEmpty else { fail("tags add needs at least one tag") }
            Settings.tags = (Settings.tags + names).uniquedTags()
        case "rm", "remove", "delete":
            guard !names.isEmpty else { fail("tags rm needs at least one tag") }
            Settings.tags = Settings.tags.filter { !names.containsTag($0) }
        default:
            fail("tags takes add or rm, not \(verb)")
        }
        Index.open()
        Store.regenerateIndexes(full: true)
        _ = announce()
        Settings.tags.forEach { print($0) }
    }

    /// Wakes the running app, if any: preferences do not cross processes on
    /// their own. Returns false when the message could not be sent.
    @discardableResult
    private static func announce() -> Bool {
        Settings.defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Settings.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }

    private static func isAppRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "Nutip.app/Contents/MacOS/Nutip"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// `nutip add <text|url> [-t tag]... [-w why] [--title t] [-x]`
    private struct AddOptions {
        var tags: [String] = []
        var why = ""
        var title = ""
        var extractPage = false
        var words: [String] = []

        init(_ args: [String]) {
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--tag", "-t": if i + 1 < args.count { tags.append(args[i + 1]); i += 1 }
                case "--why", "-w": if i + 1 < args.count { why = args[i + 1]; i += 1 }
                case "--title": if i + 1 < args.count { title = args[i + 1]; i += 1 }
                case "--extract", "-x": extractPage = true
                default: words.append(args[i])
                }
                i += 1
            }
        }
    }

    private static func add(_ rest: [String]) {
        let options = AddOptions(rest)
        var text = options.words.joined(separator: " ")
        if text.isEmpty || text == "-" {
            text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        text = text.trimmed
        guard !text.isEmpty else { fail("nothing to add") }
        Index.open()
        let isURL = text.isURL
        do {
            let fallbackTitle = isURL ? (URL(string: text)?.domain ?? text) : text.excerpt(70)
            let clip = try Store.add(title: options.title.isEmpty ? fallbackTitle : options.title,
                                     url: isURL ? text : nil, source: "CLI",
                                     tags: options.tags, why: options.why, body: isURL ? "" : text)
            if options.extractPage, isURL, let url = URL(string: text) {
                readPage(url, into: clip, keepTitle: !options.title.isEmpty)
            }
            print(clip.fileURL?.path ?? clip.path)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// The GUI extracts in the background after the palette closes; a command
    /// has nowhere to hide it, so this is opt-in and blocking.
    private static func readPage(_ url: URL, into clip: Clip, keepTitle: Bool) {
        guard let page = page(at: url), !page.markdown.trimmed.isEmpty else {
            FileHandle.standardError.write("nutip: saved, but could not read the page\n".data(using: .utf8)!)
            return
        }
        var updated = clip
        // Title first, then the text: `append` re-reads the file, so saving the
        // title afterwards would drop the body.
        if !keepTitle, !page.title.trimmed.isEmpty, page.title.trimmed != clip.title {
            updated.title = page.title.trimmed
            try? Store.save(updated)
        }
        try? Store.append(page.markdown, to: updated)
    }

    /// Trashes a clip and brings the indexes back in line. The path may be
    /// the one printed by `search` (2026-09/…md) or an absolute one.
    private static func remove(_ path: String) {
        Index.open()
        var relative = path
        if let root = Settings.folder?.path, path.hasPrefix(root) {
            relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let clip = try? Store.read(path: relative) else { fail("no clip at \(path) (inside \(Settings.folder?.path ?? "the folder"))") }
        do {
            try Store.delete(clip)
            print("trashed \(relative)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Runs the hidden web view from the command line: a run loop until the
    /// page is read or the extractor gives up.
    private static func extract(_ url: URL) {
        guard let result = page(at: url) else {
            fail("could not extract \(url)")
        }
        print("# \(result.title)\n")
        if !result.byline.isEmpty { print("*\(result.byline)*\n") }
        print(result.markdown)
    }

    private static func page(at url: URL) -> Extracted? {
        var out: Extracted?
        var done = false
        Extractor.shared.extract(url) { result in
            out = result
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        return out
    }

    private static func emit(_ clips: [Clip], json: Bool) {
        if json {
            let rows = clips.map { c -> [String: Any] in
                // `file` is absolute on purpose: an agent reads it without
                // having to know where the folder is.
                ["path": c.path, "file": c.fileURL?.path ?? c.path, "title": c.title, "url": c.url ?? "",
                 "source": c.source, "captured_at": Dates.iso.string(from: c.capturedAt),
                 "tags": c.tags, "why": c.why]
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) { print(s) }
            return
        }
        for c in clips {
            var line = "\(Dates.day(c.capturedAt))  \(c.title)"
            if !c.tags.isEmpty { line += "  " + c.tags.map { "#\($0)" }.joined(separator: " ") }
            print(line)
            if let url = c.url, !url.isEmpty { print("            \(url)") }
            if !c.why.isEmpty { print("            · \(c.why)") }
            print("            \(c.path)")
        }
        if clips.isEmpty { print("(no clips)") }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("nutip: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
