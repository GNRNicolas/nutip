// The folder of Markdown files: writing nuts, reading them back, and the
// generated indexes. This is the whole product; everything else is a way in.
import Foundation

/// One nut, as stored in the frontmatter of its file.
struct Nut: Equatable {
    var path: String            // relative to the folder, e.g. 2026-09/2026-09-13-title.md
    var title: String
    var url: String?
    var source: String          // "Safari · example.com", "Notes", "Clipboard"
    var capturedAt: Date
    var tags: [String]
    var why: String
    /// Words this nut is about, counted from its own text by `Keywords`.
    /// Indexed like the body, so a question that paraphrases the page still
    /// finds it. Editable by hand; regenerated only when empty.
    var keywords: [String] = []
    /// The piece of text a search matched, with the matched words marked by
    /// FTS5. Only ever set by a search: it is not in the file.
    var match: String = ""
    var body: String            // everything after the frontmatter
    /// False for a row that came from the search index, which stores no body.
    /// `Store.save` reloads the body first, so such a row can never truncate a file.
    var bodyLoaded: Bool = true

    var fileURL: URL? { Settings.folder?.appendingPathComponent(path) }
    var domain: String { url.flatMap(URL.init(string:))?.domain ?? "" }
    var month: String { String(path.prefix(7)) }
}

enum Store {
    // MARK: Paths

    static var folder: URL? { Settings.folder }

    /// Files Nutip generates. Never parsed as nuts, never counted.
    static let generatedNames: Set<String> = ["INDEX.md", "README.md", "AGENTS.md"]
    static let tagsDirectory = "tags"

    static func ensureFolder() throws -> URL {
        guard let folder else { throw StoreError.noFolder }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Writing

    /// Writes a new nut and returns it with its final path. Regenerates the
    /// indexes and updates the search index.
    @discardableResult
    static func add(title: String, url: String?, source: String, tags: [String], why: String,
                    body: String, at date: Date = Date()) throws -> Nut {
        let root = try ensureFolder()
        let month = Dates.month(date)
        let dir = root.appendingPathComponent(month, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cleanTitle = title.trimmed.isEmpty ? (url ?? "Untitled nut") : title.trimmed
        let base = "\(Dates.day(date))-\(Slug.make(cleanTitle))"
        var name = base + ".md"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base)-\(n).md"
            n += 1
        }

        var nut = Nut(path: "\(month)/\(name)", title: cleanTitle, url: url?.trimmed,
                        source: source, capturedAt: date, tags: canonical(tags),
                        why: why.trimmed, body: body)
        if nut.url?.isEmpty == true { nut.url = nil }
        try save(nut)
        return nut
    }

    /// Tags as the user spells them: a tag that matches one in Settings takes
    /// the spelling from Settings, so `pricing-model` typed in a script and
    /// `Pricing-Model` in the palette do not write two spellings into files.
    private static func canonical(_ tags: [String]) -> [String] {
        let known = Dictionary(Settings.tags.map { ($0.tagKey, $0) }, uniquingKeysWith: { a, _ in a })
        return tags.map(Slug.tag).map { known[$0.tagKey] ?? $0 }.uniquedTags()
    }

    /// Rewrites a nut in place (frontmatter and body), then regenerates only
    /// the index pages that mention it.
    /// `old` is the nut as it is on disk. Callers that have just read it say
    /// so: `append` used to read the file, hand the result here, and have it
    /// read and parse the same file a second time.
    static func save(_ nut: Nut, old known: Nut? = nil) throws {
        guard let file = nut.fileURL else { throw StoreError.noFolder }
        var nut = nut
        let old = known ?? (try? read(path: nut.path)) ?? nil
        if !nut.bodyLoaded {
            // This nut came from the index, which carries no body and no
            // keywords. Taking them from the file is what keeps editing a tag
            // from truncating the page text and rewriting the keywords.
            nut.body = old?.body ?? ""
            if nut.keywords.isEmpty { nut.keywords = old?.keywords ?? [] }
            nut.bodyLoaded = true
        }
        nut.keywords = keywords(for: nut)
        try writeText(render(nut), to: file)
        Index.upsert(nut)
        regenerateIndexes(months: [nut.month], tags: Set(nut.tags).union(old?.tags ?? []))
    }

    /// Keywords are derived once, when there is finally something to derive
    /// them from: a nut is written before its page is fetched, so the first
    /// save of a link has nothing but a title. A spelling the user edited by
    /// hand is never overwritten.
    static func keywords(for nut: Nut) -> [String] {
        guard nut.keywords.isEmpty else { return nut.keywords }
        return Keywords.derive(title: nut.title, why: nut.why, body: nut.body, tags: nut.tags)
    }

    /// Writes an extracted page into a nut that is already on disk. Both the
    /// palette and `nutip add -x` end here, because both had grown their own
    /// copy of the same four steps and the copies had drifted apart.
    ///
    /// Title first: `append` re-reads the file, so saving the title afterwards
    /// would drop the body that was just written.
    static func complete(_ nut: Nut, title: String?, byline: String, markdown: String) throws {
        var updated = nut
        if let title, !title.isEmpty, title != nut.title {
            updated.title = title
            try save(updated)
        }
        var article = markdown.trimmed
        if article.isEmpty {
            // A video, a paywall, an app: the link and the title are all there
            // is. Said in the file, so that reading it later — or an agent
            // searching it — is not left wondering where the text went.
            article = "*(no readable text on this page — the link above is the nut.)*"
        } else if !byline.isEmpty {
            article = "*\(byline)*\n\n" + article
        }
        try append(article, to: updated)
    }

    /// Appends extracted page content to an existing nut's body.
    static func append(_ markdown: String, to nut: Nut) throws {
        var updated = try read(path: nut.path) ?? nut
        var trimmed = markdown.trimmed
        guard !trimmed.isEmpty else { return }
        // A nut is meant to be read, by a person or an agent, in one go. A
        // page that runs past the limit keeps its beginning and its link.
        if trimmed.count > Settings.bodyLimit {
            let cut = trimmed.index(trimmed.startIndex, offsetBy: Settings.bodyLimit)
            trimmed = String(trimmed[..<cut]).trimmed
                + "\n\n*(truncated by Nutip at \(Settings.bodyLimit) characters. The link above has the rest.)*"
        }
        let onDisk = updated
        updated.body = updated.body.trimmed.isEmpty ? trimmed : updated.body.trimmed + "\n\n---\n\n" + trimmed
        try save(updated, old: onDisk)
    }

    static func delete(_ nut: Nut) throws {
        guard let file = nut.fileURL else { throw StoreError.noFolder }
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        Index.remove(path: nut.path)
        regenerateIndexes(months: [nut.month], tags: Set(nut.tags))
    }

    // MARK: Reading

    /// Parses one nut file. Nil when the file is not a Nutip nut (no frontmatter).
    static func read(path: String) throws -> Nut? {
        guard let file = try url(for: path) else { return nil }
        let text = try String(contentsOf: file, encoding: .utf8)
        return parse(text, path: path)
    }

    /// Resolves a nut path inside the folder, or nil when it points outside
    /// it. `..` in a path handed over by a script or an agent must not reach a
    /// file Nutip was never meant to touch.
    static func url(for path: String) throws -> URL? {
        guard let root = folder else { throw StoreError.noFolder }
        let file = root.appendingPathComponent(path).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard file.path == base || file.path.hasPrefix(base + "/") else {
            Log.write("store: refused a path outside the folder: \(path)")
            return nil
        }
        return file
    }

    /// Every nut file in the folder with its modification date and size,
    /// without opening any of them: this is how the index knows what changed.
    /// Every nut file with its size and modification date, read one directory
    /// at a time. `includingPropertiesForKeys` is the point: it asks the file
    /// system for those two values in bulk, where a per-file
    /// `attributesOfItem` builds a twenty-entry dictionary each time. On five
    /// thousand nuts that was a quarter of a second, paid on every single
    /// command before anything else happened.
    static func stamps() -> [String: Stamp] {
        guard let root = folder,
              let months = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [:] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var out: [String: Stamp] = [:]
        for month in months where month.range(of: "^\\d{4}-\\d{2}$", options: .regularExpression) != nil {
            let dir = root.appendingPathComponent(month)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for file in files {
                let name = file.lastPathComponent
                guard name.hasSuffix(".md"), !generatedNames.contains(name) else { continue }
                guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
                out["\(month)/\(name)"] = Stamp(
                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    size: values.fileSize ?? 0)
            }
        }
        return out
    }

    static func stamp(_ url: URL) -> Stamp? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return nil }
        return Stamp(modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0, size: v.fileSize ?? 0)
    }

    /// Every nut in the folder, newest first. Reads every file: this is the
    /// slow path, kept for `nutip reindex` and for when the index is missing.
    static func all() -> [Nut] {
        stamps().keys.compactMap { try? read(path: $0) }.sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: Format

    /// The frontmatter is deliberately plain: quoted strings, a flow-style
    /// list for tags, ISO 8601 for the date. Obsidian, pandoc and a regex all
    /// read it. Keys never change order, so diffs stay small.
    static func render(_ nut: Nut) -> String {
        var lines = ["---"]
        lines.append("title: \(quote(nut.title))")
        if let url = nut.url, !url.isEmpty { lines.append("url: \(url)") }
        lines.append("source: \(quote(nut.source))")
        lines.append("captured_at: \(Dates.iso.string(from: nut.capturedAt))")
        lines.append("tags: [\(nut.tags.joined(separator: ", "))]")
        if !nut.why.isEmpty { lines.append("why: \(quote(nut.why))") }
        if !nut.keywords.isEmpty { lines.append("keywords: [\(nut.keywords.joined(separator: ", "))]") }
        lines.append("---")
        lines.append("")
        lines.append("# \(nut.title)")
        lines.append("")
        if let url = nut.url, !url.isEmpty {
            lines.append("<\(url)>")
            lines.append("")
        }
        // A short text nut is its own title: no point writing it twice.
        let body = nut.body.trimmed
        if !body.isEmpty, body != nut.title {
            lines.append(body)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String, path: String) -> Nut? {
        guard text.hasPrefix("---\n") else { return nil }
        let afterOpen = text.index(text.startIndex, offsetBy: 4)
        guard let close = text.range(of: "\n---\n", range: afterOpen..<text.endIndex)
                ?? text.range(of: "\n---", range: afterOpen..<text.endIndex) else { return nil }
        let head = String(text[afterOpen..<close.lowerBound])
        var rest = String(text[close.upperBound...])

        var fields: [String: String] = [:]
        for line in head.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmed
            let value = String(line[line.index(after: colon)...]).trimmed
            fields[key] = value
        }
        guard let rawTitle = fields["title"] else { return nil }
        let title = unquote(rawTitle)

        // Drop the H1 and the bare URL that `render` writes, so a re-render
        // does not stack them up.
        rest = rest.trimmed
        if rest.hasPrefix("# \(title)") {
            rest = String(rest.dropFirst(2 + title.count)).trimmed
        }
        if let url = fields["url"], rest.hasPrefix("<\(url)>") {
            rest = String(rest.dropFirst(url.count + 2)).trimmed
        }

        let tags = (fields["tags"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",").map { Slug.tag(String($0)) }.uniquedTags()
        let date = fields["captured_at"].flatMap { Dates.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            ?? (try? FileManager.default.attributesOfItem(atPath: (folder?.appendingPathComponent(path).path) ?? "")[.creationDate] as? Date)
            ?? Date()

        return Nut(path: path, title: title, url: fields["url"].map(unquote), source: unquote(fields["source"] ?? ""),
                    capturedAt: date, tags: tags, why: unquote(fields["why"] ?? ""),
                    keywords: list(fields["keywords"]), body: rest)
    }

    /// A flow-style list, the one shape the frontmatter uses: `[a, b, c]`.
    private static func list(_ raw: String?) -> [String] {
        (raw ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    private static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped.components(separatedBy: .newlines).joined(separator: " "))\""
    }

    private static func unquote(_ s: String) -> String {
        var v = s.trimmed
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
            v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }

    // MARK: Generated files

    /// Written at the top of every page Nutip generates, and the test for
    /// "may I overwrite this?".
    static let marker = "<!-- generated by Nutip. Do not edit: it is rewritten after every nut -->"

    /// The wordings this marker has had. Nutip has to keep recognising the
    /// pages it wrote under an older one: the day the sentence changed, every
    /// existing INDEX.md stopped matching, and Nutip quietly refused to touch
    /// its own files ever again — frozen folders, no error anywhere.
    static let markers = [
        marker,
        "<!-- generated by Nutip. Do not edit: it is rewritten after every clip -->",
    ]

    /// True when this text is a page Nutip generated, whichever version wrote it.
    static func isGenerated(_ text: String) -> Bool { markers.contains { text.contains($0) } }

    /// The pages that describe the folder: `INDEX.md` at the root, one page
    /// per month inside the month, one per tag under `tags/`, plus `AGENTS.md`
    /// and `README.md`.
    ///
    /// A save touches one month and a handful of tags, and writes only those:
    /// the cost of a nut does not grow with the size of the folder. `full`
    /// rewrites everything and removes what is stale (`nutip reindex`).
    static func regenerateIndexes(months: Set<String> = [], tags: Set<String> = [], full: Bool = false) {
        // Without the cache, every count below comes back zero and the pages
        // would be rewritten empty over perfectly good ones — and `recent`
        // would fall back to reading every file in the folder, on a save.
        // Leaving them untouched is the safe failure.
        guard let root = folder, Index.isOpen else { return }
        let limit = Settings.indexLimit
        let monthCounts = Index.months()
        let tagCounts = Index.tagCounts()
        let total = monthCounts.reduce(0) { $0 + $1.1 }

        write(rootIndex(nuts: Index.recent(limit: limit), total: total, months: monthCounts, tags: tagCounts),
              to: root.appendingPathComponent("INDEX.md"))

        for month in (full ? monthCounts.map(\.0) : Array(months)) where !month.isEmpty {
            let dir = root.appendingPathComponent(month, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let nuts = Index.month(month)
            if nuts.isEmpty {
                removeGenerated(dir.appendingPathComponent("INDEX.md"))
            } else {
                write(index(title: month, subtitle: "\(nuts.count) nut\(nuts.count == 1 ? "" : "s"), oldest first.",
                            nuts: nuts, prefix: "", stripMonth: true, parents: ["../INDEX.md"]),
                      to: dir.appendingPathComponent("INDEX.md"))
            }
        }

        let tagsDir = root.appendingPathComponent(tagsDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: tagsDir, withIntermediateDirectories: true)
        let counts = Dictionary(tagCounts.map { ($0.0.tagKey, $0.1) }, uniquingKeysWith: +)
        // One page per tag, named the way `tagCounts` spells it: two nuts
        // written `Réflexions` and `reflexions` share a tag, so they share a
        // page, and the other spelling of it is removed.
        let spelling = Dictionary(tagCounts.map { ($0.0.tagKey, $0.0) }, uniquingKeysWith: { a, _ in a })
        let pages = (try? FileManager.default.contentsOfDirectory(atPath: tagsDir.path))?
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) } ?? []
        // In `full`, every page on disk is visited too, so a tag nobody uses
        // any more loses its page instead of lingering.
        let targets = full ? (tagCounts.map(\.0) + Settings.tags + pages).uniquedTags() : Array(tags).uniquedTags()
        for tag in targets where !tag.isEmpty {
            let name = spelling[tag.tagKey] ?? tag
            let file = tagsDir.appendingPathComponent("\(name).md")
            let n = counts[tag.tagKey] ?? 0
            // Whatever else spells this tag is not a second tag.
            for page in pages where page.tagKey == tag.tagKey && page != name {
                removeGenerated(tagsDir.appendingPathComponent("\(page).md"))
            }
            // A page is written for a tag that has nuts. A configured tag
            // nobody has used yet would only be an empty page to open.
            if n == 0 {
                removeGenerated(file)
                continue
            }
            let nuts = Index.recent(tag: tag, limit: limit)
            write(index(title: "#\(name)",
                        subtitle: n == nuts.count
                            ? "\(n) nut\(n == 1 ? "" : "s"), newest first."
                            : "\(nuts.count) most recent of \(n) nuts.",
                        nuts: nuts, prefix: "../", parents: ["../INDEX.md"]),
                  to: file)
        }

        writeAgents(root: root)
        writeReadme(root: root)
    }

    private static func removeGenerated(_ file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8), isGenerated(text) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// The root index: what the folder holds, then the most recent nuts, then
    /// every tag and every month as a link. One read tells an agent the shape
    /// of the whole folder, however large it has become.
    private static func rootIndex(nuts: [Nut], total: Int, months: [(String, Int)], tags: [(String, Int)]) -> String {
        var lines = [marker, "", "# Nuts", ""]
        if total == 0 {
            lines.append("Nothing saved yet.")
            lines.append("")
            return lines.joined(separator: "\n")
        }
        lines.append("\(total) nut\(total == 1 ? "" : "s") in \(months.count) month\(months.count == 1 ? "" : "s"). "
                     + "One Markdown file each, under `YYYY-MM/`. Start here, then open what you need.")
        lines.append("")
        if !tags.isEmpty {
            lines.append("**Tags** · " + tags.map { "[#\($0.0)](tags/\($0.0).md) \($0.1)" }.joined(separator: " · "))
            lines.append("")
        }
        if !months.isEmpty {
            lines.append("**Months** · " + months.map { "[\($0.0)](\($0.0)/INDEX.md) \($0.1)" }.joined(separator: " · "))
            lines.append("")
        }
        lines.append(total == nuts.count
                     ? "## All \(total) nut\(total == 1 ? "" : "s"), newest first"
                     : "## The \(nuts.count) most recent of \(total), newest first")
        lines.append("")
        lines += nuts.map { line(for: $0, prefix: "") }
        if total > nuts.count {
            lines.append("")
            lines.append("Older nuts: the month pages above, or `nutip search \"…\"`.")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func index(title: String, subtitle: String, nuts: [Nut], prefix: String,
                              stripMonth: Bool = false, parents: [String]) -> String {
        var lines = [marker, "", "# \(title)", "", subtitle, ""]
        lines += nuts.map { line(for: $0, prefix: prefix, stripMonth: stripMonth) }
        lines.append("")
        lines.append("[All nuts](\(parents[0]))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// One index line. Inside a month page the file sits next to the page, so
    /// the month drops out of the link.
    private static func line(for nut: Nut, prefix: String, stripMonth: Bool = false) -> String {
        let path = stripMonth ? String(nut.path.dropFirst(nut.month.count + 1)) : nut.path
        var line = "- \(Dates.day(nut.capturedAt)) · [\(nut.title.replacingOccurrences(of: "]", with: "\\]"))](\(prefix)\(path))"
        if !nut.domain.isEmpty { line += " · \(nut.domain)" }
        if !nut.tags.isEmpty { line += " · " + nut.tags.map { "#\($0)" }.joined(separator: " ") }
        if !nut.why.isEmpty { line += " · \(nut.why.excerpt(140))" }
        return line
    }

    /// The file an agent reads first. Short on purpose: what is here, what to
    /// read, what not to touch.
    /// The folder's note to an agent. Deliberately free of any figure that
    /// moves: written on every save, it would otherwise show up in `git
    /// status` after each nut for the sake of a counter INDEX.md already has.
    private static func writeAgents(root: URL) {
        let text = """
        \(marker)

        # AGENTS.md

        A folder of nuts: things a person saved on purpose, with a one-line reason.
        Written by [Nutip](https://github.com/GNRNicolas/nutip). Plain Markdown, no database
        needed to read it.

        ## Read in this order

        1. `INDEX.md` at the root: the counts, every tag, every month, and the most recent
           \(Settings.indexLimit) nuts with their `why` line. One read, whatever the folder
           holds — the count is at the top of it.
        2. `tags/<tag>.md` for one subject, `YYYY-MM/INDEX.md` for one month.
        3. The nut files themselves for the full text.

        Never read every file to answer a question: the index pages carry the title, the
        date, the source, the tags and the `why` of each nut, which is usually enough to
        pick the three or four worth opening.

        ## One nut

        ```markdown
        ---
        title: "Page or selection title"
        url: https://example.com/article        (absent for plain text)
        source: "Safari · example.com"           (the app it came from, and the site)
        captured_at: 2026-09-13T14:03:22+02:00
        tags: [reading, competitors]
        why: "one line from the person who saved it"   (optional)
        keywords: [what, the, page, is, about]        (optional, counted locally)
        ---

        # Page or selection title

        <https://example.com/article>

        What was selected, then the readable text of the page if it is a web page.
        ```

        Search matches words, and a question rarely uses the words a page used. If a
        search comes back empty, read a tag page or this INDEX.md and make the link
        yourself rather than reporting that nothing was saved.

        `why` is the only thing here that cannot be inferred from the content: it is the
        person's intent. Weigh it accordingly.

        ## Searching

        ```sh
        nutip search "pricing #competitors" --json   # full text and tags, if the CLI is installed
        grep -rl "^tags:.*competitors" .             # plain grep works just as well
        grep -rh "^why:" 2026-*/                     # every reason, cheaply
        ```

        ## Rules

        - `INDEX.md`, `AGENTS.md`, `README.md`, `tags/*.md` and `YYYY-MM/INDEX.md` are
          generated: they are rewritten after every nut, so edits to them are lost.
          They all start with an HTML comment saying so.
        - Nut files are the truth and are safe to edit, move or delete; the indexes catch
          up on the next save, or on `nutip reindex`.
        - Adding a nut: `nutip add <text or url> -t tag -w "why"`, or write the file
          yourself under `YYYY-MM/` with the frontmatter above and run `nutip reindex`.

        """
        write(text, to: root.appendingPathComponent("AGENTS.md"))
    }

    /// Written once, then left alone if the user edited it (the marker is gone).
    private static func writeReadme(root: URL) {
        let text = """
        \(marker)

        # This folder

        Nuts saved with [Nutip](https://github.com/GNRNicolas/nutip), a macOS app that turns
        whatever you copied into a Markdown file. Everything here is plain text you own;
        Nutip only adds files, and it never needs to be running for them to be useful.

        ## Layout

        - `INDEX.md`: the counts, the tags, the months, and the \(Settings.indexLimit) most recent nuts.
        - `tags/<tag>.md`: the same list, one tag.
        - `YYYY-MM/INDEX.md`: everything saved that month.
        - `YYYY-MM/YYYY-MM-DD-title.md`: one file per nut.
        - `AGENTS.md`: the same layout, written for an AI agent.

        Generated pages start with an HTML comment and are rewritten after every nut.
        Delete the comment and the page becomes yours: Nutip stops touching it.

        ## One nut

        ```markdown
        ---
        title: "Page or selection title"
        url: https://example.com/article        (absent for plain text)
        source: "Safari · example.com"           (app it came from, and the site)
        captured_at: 2026-09-13T14:03:22+02:00
        tags: [reading, competitors]
        why: "one line from the person who saved it"   (optional)
        keywords: [what, the, page, is, about]        (optional, counted locally)
        ---

        # Page or selection title

        <https://example.com/article>

        Selected text, then the readable article text if it came from a web page.
        ```

        Point an AI agent at this folder and tell it to read `AGENTS.md`.

        """
        write(text, to: root.appendingPathComponent("README.md"))
    }

    /// Writes a generated page, unless the user has taken it over (no marker)
    /// or nothing changed.
    /// Writes a generated page, unless the file there is not ours to write.
    /// The read has to distinguish "no file" from "unreadable file": one is
    /// permission to write, the other is a file whose contents we cannot see
    /// and therefore cannot claim.
    private static func write(_ text: String, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
            if existing == text || !isGenerated(existing) { return }
        }
        try? writeText(text, to: url)
    }

    /// Atomic when the system allows it. Some sandboxes refuse the temporary
    /// file an atomic write goes through while allowing the file itself.
    static func writeText(_ text: String, to url: URL) throws {
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { try text.write(to: url, atomically: false, encoding: .utf8) }
    }
}

enum StoreError: LocalizedError {
    case noFolder
    var errorDescription: String? {
        switch self {
        case .noFolder: return "No nuts folder is set. Open Nutip and choose one."
        }
    }
}
