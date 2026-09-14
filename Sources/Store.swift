// The folder of Markdown files: writing clips, reading them back, and the
// generated indexes. This is the whole product; everything else is a way in.
import Foundation

/// One clip, as stored in the frontmatter of its file.
struct Clip: Equatable {
    var path: String            // relative to the folder, e.g. 2026-09/2026-09-13-title.md
    var title: String
    var url: String?
    var source: String          // "Safari · example.com", "Notes", "Clipboard"
    var capturedAt: Date
    var tags: [String]
    var why: String
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

    /// Files Nutip generates. Never parsed as clips, never counted.
    static let generatedNames: Set<String> = ["INDEX.md", "README.md", "AGENTS.md"]
    static let tagsDirectory = "tags"

    static func ensureFolder() throws -> URL {
        guard let folder else { throw StoreError.noFolder }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Writing

    /// Writes a new clip and returns it with its final path. Regenerates the
    /// indexes and updates the search index.
    @discardableResult
    static func add(title: String, url: String?, source: String, tags: [String], why: String,
                    body: String, at date: Date = Date()) throws -> Clip {
        let root = try ensureFolder()
        let month = Dates.month(date)
        let dir = root.appendingPathComponent(month, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cleanTitle = title.trimmed.isEmpty ? (url ?? "Untitled clip") : title.trimmed
        let base = "\(Dates.day(date))-\(Slug.make(cleanTitle))"
        var name = base + ".md"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(base)-\(n).md"
            n += 1
        }

        var clip = Clip(path: "\(month)/\(name)", title: cleanTitle, url: url?.trimmed,
                        source: source, capturedAt: date, tags: tags.map(Slug.tag).filter { !$0.isEmpty }.uniqued(),
                        why: why.trimmed, body: body)
        if clip.url?.isEmpty == true { clip.url = nil }
        try save(clip)
        return clip
    }

    /// Rewrites a clip in place (frontmatter and body), then regenerates only
    /// the index pages that mention it.
    static func save(_ clip: Clip) throws {
        guard let file = clip.fileURL else { throw StoreError.noFolder }
        var clip = clip
        let old = try? read(path: clip.path)
        if !clip.bodyLoaded {
            clip.body = old?.body ?? ""
            clip.bodyLoaded = true
        }
        try writeText(render(clip), to: file)
        Index.upsert(clip)
        regenerateIndexes(months: [clip.month], tags: Set(clip.tags).union(old?.tags ?? []))
    }

    /// Appends extracted page content to an existing clip's body.
    static func append(_ markdown: String, to clip: Clip) throws {
        var updated = try read(path: clip.path) ?? clip
        var trimmed = markdown.trimmed
        guard !trimmed.isEmpty else { return }
        // A clip is meant to be read, by a person or an agent, in one go. A
        // page that runs past the limit keeps its beginning and its link.
        if trimmed.count > Settings.bodyLimit {
            let cut = trimmed.index(trimmed.startIndex, offsetBy: Settings.bodyLimit)
            trimmed = String(trimmed[..<cut]).trimmed
                + "\n\n*(truncated by Nutip at \(Settings.bodyLimit) characters. The link above has the rest.)*"
        }
        updated.body = updated.body.trimmed.isEmpty ? trimmed : updated.body.trimmed + "\n\n---\n\n" + trimmed
        try save(updated)
    }

    static func delete(_ clip: Clip) throws {
        guard let file = clip.fileURL else { throw StoreError.noFolder }
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        Index.remove(path: clip.path)
        regenerateIndexes(months: [clip.month], tags: Set(clip.tags))
    }

    // MARK: Reading

    /// Parses one clip file. Nil when the file is not a Nutip clip (no frontmatter).
    static func read(path: String) throws -> Clip? {
        guard let root = folder else { throw StoreError.noFolder }
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return parse(text, path: path)
    }

    /// Every clip file in the folder with its modification date and size,
    /// without opening any of them: this is how the index knows what changed.
    static func stamps() -> [String: Stamp] {
        guard let root = folder,
              let months = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [:] }
        var out: [String: Stamp] = [:]
        for month in months where month.range(of: "^\\d{4}-\\d{2}$", options: .regularExpression) != nil {
            let dir = root.appendingPathComponent(month)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.hasSuffix(".md") && !generatedNames.contains(file) {
                if let s = stamp(dir.appendingPathComponent(file)) { out["\(month)/\(file)"] = s }
            }
        }
        return out
    }

    static func stamp(_ url: URL) -> Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     size: (a[.size] as? Int) ?? 0)
    }

    /// Every clip in the folder, newest first. Reads every file: this is the
    /// slow path, kept for `nutip reindex` and for when the index is missing.
    static func all() -> [Clip] {
        stamps().keys.compactMap { try? read(path: $0) }.sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: Format

    /// The frontmatter is deliberately plain: quoted strings, a flow-style
    /// list for tags, ISO 8601 for the date. Obsidian, pandoc and a regex all
    /// read it. Keys never change order, so diffs stay small.
    static func render(_ clip: Clip) -> String {
        var lines = ["---"]
        lines.append("title: \(quote(clip.title))")
        if let url = clip.url, !url.isEmpty { lines.append("url: \(url)") }
        lines.append("source: \(quote(clip.source))")
        lines.append("captured_at: \(Dates.iso.string(from: clip.capturedAt))")
        lines.append("tags: [\(clip.tags.joined(separator: ", "))]")
        if !clip.why.isEmpty { lines.append("why: \(quote(clip.why))") }
        lines.append("---")
        lines.append("")
        lines.append("# \(clip.title)")
        lines.append("")
        if let url = clip.url, !url.isEmpty {
            lines.append("<\(url)>")
            lines.append("")
        }
        // A short text clip is its own title: no point writing it twice.
        let body = clip.body.trimmed
        if !body.isEmpty, body != clip.title {
            lines.append(body)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String, path: String) -> Clip? {
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
            .split(separator: ",").map { Slug.tag(String($0)) }.filter { !$0.isEmpty }
        let date = fields["captured_at"].flatMap { Dates.iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            ?? (try? FileManager.default.attributesOfItem(atPath: (folder?.appendingPathComponent(path).path) ?? "")[.creationDate] as? Date)
            ?? Date()

        return Clip(path: path, title: title, url: fields["url"].map(unquote), source: unquote(fields["source"] ?? ""),
                    capturedAt: date, tags: tags, why: unquote(fields["why"] ?? ""), body: rest)
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

    static let marker = "<!-- generated by Nutip. Do not edit: it is rewritten after every clip -->"

    /// The pages that describe the folder: `INDEX.md` at the root, one page
    /// per month inside the month, one per tag under `tags/`, plus `AGENTS.md`
    /// and `README.md`.
    ///
    /// A save touches one month and a handful of tags, and writes only those:
    /// the cost of a clip does not grow with the size of the folder. `full`
    /// rewrites everything and removes what is stale (`nutip reindex`).
    static func regenerateIndexes(months: Set<String> = [], tags: Set<String> = [], full: Bool = false) {
        guard let root = folder else { return }
        let limit = Settings.indexLimit
        let monthCounts = Index.months()
        let tagCounts = Index.tagCounts()
        let total = monthCounts.reduce(0) { $0 + $1.1 }

        write(rootIndex(clips: Index.recent(limit: limit), total: total, months: monthCounts, tags: tagCounts),
              to: root.appendingPathComponent("INDEX.md"))

        for month in (full ? monthCounts.map(\.0) : Array(months)) where !month.isEmpty {
            let dir = root.appendingPathComponent(month, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let clips = Index.month(month)
            if clips.isEmpty {
                removeGenerated(dir.appendingPathComponent("INDEX.md"))
            } else {
                write(index(title: month, subtitle: "\(clips.count) clip\(clips.count == 1 ? "" : "s"), oldest first.",
                            clips: clips, prefix: "", stripMonth: true, parents: ["../INDEX.md"]),
                      to: dir.appendingPathComponent("INDEX.md"))
            }
        }

        let tagsDir = root.appendingPathComponent(tagsDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: tagsDir, withIntermediateDirectories: true)
        let counts = Dictionary(uniqueKeysWithValues: tagCounts)
        let targets = full ? Set(tagCounts.map(\.0)).union(Settings.tags) : tags
        for tag in targets where !tag.isEmpty {
            let file = tagsDir.appendingPathComponent("\(tag).md")
            let n = counts[tag] ?? 0
            // A page is written for a tag that has clips. A configured tag
            // nobody has used yet would only be an empty page to open.
            if n == 0 {
                removeGenerated(file)
                continue
            }
            let clips = Index.recent(tag: tag, limit: limit)
            write(index(title: "#\(tag)",
                        subtitle: n == clips.count
                            ? "\(n) clip\(n == 1 ? "" : "s"), newest first."
                            : "\(clips.count) most recent of \(n) clips.",
                        clips: clips, prefix: "../", parents: ["../INDEX.md"]),
                  to: file)
        }

        writeAgents(root: root, total: total)
        writeReadme(root: root)
    }

    private static func removeGenerated(_ file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(marker) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// The root index: what the folder holds, then the most recent clips, then
    /// every tag and every month as a link. One read tells an agent the shape
    /// of the whole folder, however large it has become.
    private static func rootIndex(clips: [Clip], total: Int, months: [(String, Int)], tags: [(String, Int)]) -> String {
        var lines = [marker, "", "# Nutip clips", ""]
        if total == 0 {
            lines.append("Nothing saved yet.")
            lines.append("")
            return lines.joined(separator: "\n")
        }
        lines.append("\(total) clip\(total == 1 ? "" : "s") in \(months.count) month\(months.count == 1 ? "" : "s"). "
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
        lines.append(total == clips.count
                     ? "## All \(total) clip\(total == 1 ? "" : "s"), newest first"
                     : "## The \(clips.count) most recent of \(total), newest first")
        lines.append("")
        lines += clips.map { line(for: $0, prefix: "") }
        if total > clips.count {
            lines.append("")
            lines.append("Older clips: the month pages above, or `nutip search \"…\"`.")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func index(title: String, subtitle: String, clips: [Clip], prefix: String,
                              stripMonth: Bool = false, parents: [String]) -> String {
        var lines = [marker, "", "# \(title)", "", subtitle, ""]
        lines += clips.map { line(for: $0, prefix: prefix, stripMonth: stripMonth) }
        lines.append("")
        lines.append("[All clips](\(parents[0]))")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// One index line. Inside a month page the file sits next to the page, so
    /// the month drops out of the link.
    private static func line(for clip: Clip, prefix: String, stripMonth: Bool = false) -> String {
        let path = stripMonth ? String(clip.path.dropFirst(clip.month.count + 1)) : clip.path
        var line = "- \(Dates.day(clip.capturedAt)) · [\(clip.title.replacingOccurrences(of: "]", with: "\\]"))](\(prefix)\(path))"
        if !clip.domain.isEmpty { line += " · \(clip.domain)" }
        if !clip.tags.isEmpty { line += " · " + clip.tags.map { "#\($0)" }.joined(separator: " ") }
        if !clip.why.isEmpty { line += " · \(clip.why.excerpt(140))" }
        return line
    }

    /// The file an agent reads first. Short on purpose: what is here, what to
    /// read, what not to touch.
    private static func writeAgents(root: URL, total: Int) {
        let text = """
        \(marker)

        # AGENTS.md

        A folder of clips: things a person saved on purpose, with a one-line reason.
        Written by [Nutip](https://github.com/GNRNicolas/nutip). Plain Markdown, no database
        needed to read it.

        ## Read in this order

        1. `INDEX.md` at the root: the counts, every tag, every month, and the most recent
           \(Settings.indexLimit) clips with their `why` line. One read, whatever the folder holds
           (currently \(total) clip\(total == 1 ? "" : "s")).
        2. `tags/<tag>.md` for one subject, `YYYY-MM/INDEX.md` for one month.
        3. The clip files themselves for the full text.

        Never read every file to answer a question: the index pages carry the title, the
        date, the source, the tags and the `why` of each clip, which is usually enough to
        pick the three or four worth opening.

        ## One clip

        ```markdown
        ---
        title: "Page or selection title"
        url: https://example.com/article        (absent for plain text)
        source: "Safari · example.com"           (the app it came from, and the site)
        captured_at: 2026-09-13T14:03:22+02:00
        tags: [reading, competitors]
        why: "one line from the person who saved it"   (optional)
        ---

        # Page or selection title

        <https://example.com/article>

        What was selected, then the readable text of the page if it is a web page.
        ```

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
          generated: they are rewritten after every clip, so edits to them are lost.
          They all start with an HTML comment saying so.
        - Clip files are the truth and are safe to edit, move or delete; the indexes catch
          up on the next save, or on `nutip reindex`.
        - Adding a clip: `nutip add <text or url> -t tag -w "why"`, or write the file
          yourself under `YYYY-MM/` with the frontmatter above and run `nutip reindex`.

        """
        write(text, to: root.appendingPathComponent("AGENTS.md"))
    }

    /// Written once, then left alone if the user edited it (the marker is gone).
    private static func writeReadme(root: URL) {
        let text = """
        \(marker)

        # This folder

        Clips saved with [Nutip](https://github.com/GNRNicolas/nutip), a macOS app that turns
        whatever you copied into a Markdown file. Everything here is plain text you own;
        Nutip only adds files, and it never needs to be running for them to be useful.

        ## Layout

        - `INDEX.md`: the counts, the tags, the months, and the \(Settings.indexLimit) most recent clips.
        - `tags/<tag>.md`: the same list, one tag.
        - `YYYY-MM/INDEX.md`: everything saved that month.
        - `YYYY-MM/YYYY-MM-DD-title.md`: one file per clip.
        - `AGENTS.md`: the same layout, written for an AI agent.

        Generated pages start with an HTML comment and are rewritten after every clip.
        Delete the comment and the page becomes yours: Nutip stops touching it.

        ## One clip

        ```markdown
        ---
        title: "Page or selection title"
        url: https://example.com/article        (absent for plain text)
        source: "Safari · example.com"           (app it came from, and the site)
        captured_at: 2026-09-13T14:03:22+02:00
        tags: [reading, competitors]
        why: "one line from the person who saved it"   (optional)
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
    private static func write(_ text: String, to url: URL) {
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            if existing == text { return }
            if !existing.contains(marker) { return }
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
        case .noFolder: return "No clips folder is set. Open Nutip and choose one."
        }
    }
}
