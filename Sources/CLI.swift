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
      nutip reindex                      rebuild INDEX.md, tags/*.md and the search index
      nutip path                         the clips folder
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
        case "path":
            print(Settings.folder?.path ?? "(no folder set)")
        case "tags":
            Settings.tags.forEach { print($0) }
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
        guard let clip = try? Store.read(path: relative) else { fail("no clip at \(path)") }
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
