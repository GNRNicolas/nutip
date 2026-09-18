// `nutip search|recent|add|tags|reindex|path`: the same folder and index,
// from a terminal or a script. Runs when the binary gets arguments, without
// starting the GUI. Prints plain text by default, JSON with --json.
import Foundation

enum CLI {
    static let usage = """
    Usage:
      nutip recent [N] [--json]          the N most recent nuts (default 20)
      nutip search <query> [--json]      full-text search; #tag restricts to a tag
      nutip add <url|text> [--tag t]... [--why "..."] [--title "..."] [--extract]
                                         save a nut; --extract also reads the page
      nutip rm <path>                    move a nut to the Trash and update the indexes
      nutip extract <url>                print a page as Markdown (what a nut gets)
      nutip tags                         the configured tags
      nutip tags add <tag>...            add tags to the palette (also: rm)
      nutip folder [path]                the nuts folder; with a path, use that one
      nutip reindex                      rebuild INDEX.md, tags/*.md and the search index
      nutip doctor                       permissions, folder, hotkey
      nutip filters                      every @ filter there is, read from your nuts
      nutip enrich [--dry-run]           give keywords to the nuts that have none
      nutip --help

    NUTIP_DIR=<folder> overrides the nuts folder for one command.
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
            print("app        \(Resources.appPath)")
            // A folder that is not there is the one thing in here that is
            // worth a warning: everything else keeps working without it.
            let missing = Store.missingFolder != nil
                ? "  \u{26A0} not found: moved, renamed, or on a disk that is not connected"
                : ""
            print("folder     \(Settings.folder?.path ?? "(none)")\(missing)")
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
            print("reindexed \(n) nut\(n == 1 ? "" : "s") in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        case "recent":
            Index.open()
            let n = rest.first.flatMap(Int.init) ?? 20
            emit(Index.search("", limit: n), json: json)
        case "search":
            Index.open()
            let query = rest.joined(separator: " ")
            guard !query.trimmed.isEmpty else { fail("search needs a query") }
            // `@week`, `@links`, `@github.com` — the same filters the palette
            // offers, so an agent can narrow the way a person does.
            var words: [String] = []
            var facets: [Index.Facet] = []
            for word in query.split(separator: " ") {
                guard word.hasPrefix("@"), word.count > 1 else { words.append(String(word)); continue }
                let wanted = String(word.dropFirst())
                if let facet = Index.facets(matching: wanted).first { facets.append(facet) }
                else { fail("no filter called @\(wanted). Try: nutip filters") }
            }
            let found = Index.search(words.joined(separator: " "), facets: facets, limit: 50)
            emit(found, json: json)
            if found.isEmpty { suggest() }
        case "filters":
            Index.open()
            for facet in Index.facets() { print("@\(facet.value)\(facet.label == facet.value ? "" : "   \(facet.label)")") }
        case "enrich":
            enrich(dry: rest.contains("--dry-run"))
        case "add":
            add(rest)
        case "rm", "remove", "delete":
            guard let path = rest.first else { fail("rm needs the path of a nut") }
            remove(path)
        case "extract":
            guard let url = rest.first.flatMap(URL.init(string:)), url.absoluteString.isURL else { fail("extract needs a URL") }
            extract(url)
        default:
            return false
        }
        return true
    }

    /// An empty result is a dead end for an agent that has no other idea, and
    /// "nothing was saved about that" is usually wrong: the nut is there, in
    /// the language the page was written in. Said on stderr, so --json output
    /// stays machine-readable.
    private static func suggest() {
        fflush(stdout)   // or the hint lands above the "(no nuts)" it explains
        let tags = Index.tagCounts().prefix(12).map { "\($0.0) (\($0.1))" }
        FileHandle.standardError.write(Data("""

        Nothing matched those words. Before concluding that nothing was saved:
          · ask again in the language the page was probably written in \
        (a French question rarely matches an English article)
          · nutip tags, then the page of the likeliest tag
          · nutip recent 200, or INDEX.md at the root: one line per nut, to read and judge
        tags in use: \(tags.isEmpty ? "(none)" : tags.joined(separator: ", "))

        """.replacingOccurrences(of: "        ", with: "").utf8))
    }

    /// Gives keywords to the nuts that have none: the ones saved before this
    /// existed, and the ones whose page arrived after the file was written.
    /// Counted locally from the nut's own text — nothing is sent anywhere, and
    /// a `keywords:` line already in a file is never touched.
    private static func enrich(dry: Bool) {
        Index.open()
        var done = 0
        for nut in Store.all() where nut.keywords.isEmpty {
            let words = Keywords.derive(title: nut.title, why: nut.why, body: nut.body, tags: nut.tags)
            guard !words.isEmpty else { continue }
            done += 1
            print("\(nut.path)\n  \(words.joined(separator: ", "))")
            if dry { continue }
            var updated = nut
            updated.keywords = words
            do { try Store.save(updated) } catch { fail("could not write \(nut.path): \(error.localizedDescription)") }
        }
        print(done == 0 ? "nothing to enrich: every nut already has keywords"
                        : "\(done) nut\(done == 1 ? "" : "s")\(dry ? " would be enriched (--dry-run)" : " enriched")")
    }

    /// `nutip folder` prints it, `nutip folder <path>` points Nutip at another
    /// one. It moves no file — and a folder swap that silently leaves every nut
    /// behind is the kind of thing you notice a week later, so it says so.
    /// An agent setting Nutip up has no other way in: everything else is in a
    /// window.
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
        let previous = Settings.folder
        let leftBehind = previous?.standardizedFileURL == url ? 0 : Store.stamps().count

        Settings.folder = url
        Index.open()
        Store.regenerateIndexes(full: true)
        print(url.path)
        if announce(), isAppRunning() {
            print("Nutip is running: it has switched to this folder.")
        }
        if leftBehind > 0, let old = previous, Store.stamps().isEmpty {
            warn("\(leftBehind) nut\(leftBehind == 1 ? "" : "s") stayed in \(old.path). "
                 + "This command points Nutip at a folder; it never moves files. To bring them along:\n"
                 + "       mv \(shellQuoted(old.path))/* \(shellQuoted(url.path))/ && nutip reindex")
        }
    }

    /// `nutip tags` lists them, `nutip tags add|rm <tag>...` edits the list the
    /// palette offers. Existing nuts keep whatever they were tagged with.
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
        /// Arguments that look like flags but are not any of ours. Silently
        /// folded into the text, a mistyped or badly quoted flag ended up
        /// *inside* the saved URL — a nut that looks right and whose link is
        /// dead. Better to refuse the command.
        var unknown: [String] = []
        /// A flag whose argument never came: `-w` at the end of the line, or
        /// `-w $EMPTY` from a shell. Dropping it saved a nut with no reason
        /// and said nothing, which is the same silence as the bug above.
        var starved: String?

        init(_ args: [String]) {
            var i = 0
            /// The argument after a flag, or nil at the end of the line.
            func value(_ flag: String) -> String? {
                guard i + 1 < args.count else { starved = starved ?? flag; return nil }
                i += 1
                return args[i]
            }
            while i < args.count {
                switch args[i] {
                case "--tag", "-t": if let tag = value(args[i]) { tags.append(tag) }
                case "--why", "-w": if let reason = value(args[i]) { why = reason }
                case "--title": if let given = value(args[i]) { title = given }
                case "--extract", "-x": extractPage = true
                case let arg where arg.hasPrefix("-") && arg != "-": unknown.append(arg)
                default: words.append(args[i])
                }
                i += 1
            }
        }
    }

    private static func add(_ rest: [String]) {
        let options = AddOptions(rest)
        if let bad = options.unknown.first {
            fail("unknown option \(bad). Options are -t <tag>, -w <why>, --title <title>, -x. "
                 + "Each takes one argument: quote it as a single word.")
        }
        if let starved = options.starved {
            fail("\(starved) needs an argument. Quote it as a single word: \(starved) \"…\"")
        }
        var text = options.words.joined(separator: " ")
        if text.isEmpty || text == "-" {
            text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        text = text.trimmed
        guard !text.isEmpty else { fail("nothing to add") }
        Index.open()
        let isURL = text.isURL
        // The palette says "already saved" before you press Save; the CLI said
        // nothing and quietly made a second file. Still saved - it may well be
        // deliberate - but said out loud.
        if isURL, let existing = Index.existing(url: text) {
            let when = Dates.day(existing.capturedAt)
            warn("already saved on \(when) as \(existing.path)"
                 + (existing.why.isEmpty ? "" : " (\(existing.why))") + ". Saving anyway.")
        }
        do {
            let fallbackTitle = isURL ? (URL(string: text)?.domain ?? text) : text.excerpt(70)
            let nut = try Store.add(title: options.title.isEmpty ? fallbackTitle : options.title,
                                     url: isURL ? text : nil, source: "CLI",
                                     tags: options.tags, why: options.why, body: isURL ? "" : text)
            if options.extractPage, isURL, let url = URL(string: text) {
                readPage(url, into: nut, keepTitle: !options.title.isEmpty)
            }
            print(nut.fileURL?.path ?? nut.path)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// The GUI extracts in the background after the palette closes; a command
    /// has nowhere to hide it, so this is opt-in and blocking.
    private static func readPage(_ url: URL, into nut: Nut, keepTitle: Bool) {
        guard let page = page(at: url) else {
            warn("saved, but could not read the page")
            return
        }
        if page.markdown.trimmed.isEmpty {
            warn("saved, but this page has no readable text (a video, a paywall or an app). "
                 + "Only its title and link are searchable — a -w reason would help.")
        }
        do {
            try Store.complete(nut, title: keepTitle ? nil : page.title.trimmed,
                               byline: page.byline, markdown: page.markdown)
        } catch {
            // Used to be three silent `try?`: the nut stayed empty and the
            // command still exited 0, which is the worst of both.
            warn("saved, but could not write the page text: \(error.localizedDescription)")
        }
    }

    /// Trashes a nut and brings the indexes back in line. The path may be
    /// the one printed by `search` (2026-09/…md) or an absolute one.
    private static func remove(_ path: String) {
        Index.open()
        var relative = path
        if let root = Settings.folder?.path, path.hasPrefix(root) {
            relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let nut = try? Store.read(path: relative) else { fail("no nut at \(path) (inside \(Settings.folder?.path ?? "the folder"))") }
        do {
            try Store.delete(nut)
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

    private static func emit(_ nuts: [Nut], json: Bool) {
        if json {
            let rows = nuts.map { c -> [String: Any] in
                // `file` is absolute on purpose: an agent reads it without
                // having to know where the folder is.
                ["path": c.path, "file": c.fileURL?.path ?? c.path, "title": c.title, "url": c.url ?? "",
                 "source": c.source, "captured_at": Dates.iso.string(from: c.capturedAt),
                 "tags": c.tags, "why": c.why,
                 // Why this nut is in the list: the passage that matched,
                 // cut around the words. Lets an agent judge a row without
                 // opening the file.
                 "match": c.match.plainMatch]
            }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) { print(s) }
            return
        }
        for c in nuts {
            var line = "\(Dates.day(c.capturedAt))  \(c.title)"
            if !c.tags.isEmpty { line += "  " + c.tags.map { "#\($0)" }.joined(separator: " ") }
            print(line)
            if let url = c.url, !url.isEmpty { print("            \(url)") }
            if !c.why.isEmpty { print("            · \(c.why)") }
            if !c.match.isEmpty { print("            ~ \(c.match.plainMatch)") }
            print("            \(c.path)")
        }
        if nuts.isEmpty { print("(no nuts)") }
    }

    /// Everything Nutip says that is not a result goes here: prefixed, and
    /// after the standard output it comments on, so a hint never lands above
    /// the line it explains.
    /// A path is about to be pasted into a shell by whoever reads the advice.
    private static func shellQuoted(_ path: String) -> String {
        path.contains(where: { !$0.isLetter && !$0.isNumber && !"/._-".contains($0) })
            ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            : path
    }

    private static func warn(_ message: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data("nutip: \(message)\n".utf8))
    }

    private static func fail(_ message: String) -> Never {
        warn(message)
        exit(1)
    }
}
