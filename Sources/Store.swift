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

    var fileURL: URL? { Settings.folder?.appendingPathComponent(path) }
    var domain: String { url.flatMap(URL.init(string:))?.domain ?? "" }
}

enum Store {
    // MARK: Paths

    static var folder: URL? { Settings.folder }

    /// Files Nutip generates. Never parsed as clips, never counted.
    static let generatedNames: Set<String> = ["INDEX.md", "README.md"]
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

    /// Rewrites a clip in place (frontmatter and body).
    static func save(_ clip: Clip) throws {
        guard let file = clip.fileURL else { throw StoreError.noFolder }
        try writeText(render(clip), to: file)
        Index.upsert(clip)
        regenerateIndexes()
    }

    /// Appends extracted page content to an existing clip's body.
    static func append(_ markdown: String, to clip: Clip) throws {
        var updated = try read(path: clip.path) ?? clip
        let trimmed = markdown.trimmed
        guard !trimmed.isEmpty else { return }
        updated.body = updated.body.trimmed.isEmpty ? trimmed : updated.body.trimmed + "\n\n---\n\n" + trimmed
        try save(updated)
    }

    static func delete(_ clip: Clip) throws {
        guard let file = clip.fileURL else { throw StoreError.noFolder }
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        Index.remove(path: clip.path)
        regenerateIndexes()
    }

    // MARK: Reading

    /// Parses one clip file. Nil when the file is not a Nutip clip (no frontmatter).
    static func read(path: String) throws -> Clip? {
        guard let root = folder else { throw StoreError.noFolder }
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return parse(text, path: path)
    }

    /// Every clip in the folder, newest first. Walks `YYYY-MM/*.md` only, so
    /// whatever else the user keeps in the folder is left alone.
    static func all() -> [Clip] {
        guard let root = folder,
              let months = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var clips: [Clip] = []
        for month in months where month.range(of: "^\\d{4}-\\d{2}$", options: .regularExpression) != nil {
            let dir = root.appendingPathComponent(month)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.hasSuffix(".md") {
                let rel = "\(month)/\(file)"
                if let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
                   let clip = parse(text, path: rel) {
                    clips.append(clip)
                }
            }
        }
        return clips.sorted { $0.capturedAt > $1.capturedAt }
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

    /// INDEX.md at the root, one file per tag under tags/, and a README that
    /// tells a reader (or an AI agent) how the folder is laid out. Regenerated
    /// after every change; a few milliseconds even for thousands of clips.
    static func regenerateIndexes() {
        guard let root = folder else { return }
        let clips = all()
        let limit = Settings.indexLimit

        write(index(title: "Nutip clips", clips: Array(clips.prefix(limit)), total: clips.count, depth: 0),
              to: root.appendingPathComponent("INDEX.md"))

        let tagsDir = root.appendingPathComponent(tagsDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: tagsDir, withIntermediateDirectories: true)
        var seen = Set<String>()
        for tag in (Settings.tags + clips.flatMap(\.tags)).uniqued() where !tag.isEmpty {
            seen.insert(tag)
            let tagged = clips.filter { $0.tags.contains(tag) }
            write(index(title: "#\(tag)", clips: Array(tagged.prefix(limit)), total: tagged.count, depth: 1),
                  to: tagsDir.appendingPathComponent("\(tag).md"))
        }
        // A tag that no longer exists anywhere leaves no stale page behind.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tagsDir.path) {
            for file in files where file.hasSuffix(".md") && !seen.contains(String(file.dropLast(3))) {
                if let text = try? String(contentsOf: tagsDir.appendingPathComponent(file), encoding: .utf8),
                   text.contains(marker) {
                    try? FileManager.default.removeItem(at: tagsDir.appendingPathComponent(file))
                }
            }
        }
        writeReadme(root: root)
    }

    static let marker = "<!-- generated by Nutip. Do not edit: it is rewritten after every clip -->"

    private static func index(title: String, clips: [Clip], total: Int, depth: Int) -> String {
        let prefix = depth == 0 ? "" : "../"
        var lines = [marker, "", "# \(title)", ""]
        lines.append(total == clips.count
                     ? "\(total) clip\(total == 1 ? "" : "s"), newest first."
                     : "\(clips.count) most recent of \(total) clips. Older ones are in the monthly folders.")
        lines.append("")
        for clip in clips {
            var line = "- \(Dates.day(clip.capturedAt)) · [\(clip.title.replacingOccurrences(of: "]", with: "\\]"))](\(prefix)\(clip.path))"
            if !clip.domain.isEmpty { line += " · \(clip.domain)" }
            if !clip.tags.isEmpty { line += " · " + clip.tags.map { "#\($0)" }.joined(separator: " ") }
            if !clip.why.isEmpty { line += " · \(clip.why.excerpt(140))" }
            lines.append(line)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Written once, then left alone if the user edited it (the marker is gone).
    private static func writeReadme(root: URL) {
        let file = root.appendingPathComponent("README.md")
        if let existing = try? String(contentsOf: file, encoding: .utf8), !existing.contains(marker) { return }
        let text = """
        \(marker)

        # This folder

        Clips saved with [Nutip](https://github.com/GNRNicolas/nutip), a macOS app that turns
        a selection or a web page into a Markdown file. Everything here is plain text you own;
        Nutip only adds files, it never needs to be running to read them.

        ## Layout

        - `INDEX.md`: the \(Settings.indexLimit) most recent clips, newest first, with tags and notes.
        - `tags/<tag>.md`: the same list filtered by one tag.
        - `YYYY-MM/YYYY-MM-DD-title.md`: one file per clip, in the month it was saved.

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

        Selected text, if any.

        ---

        Readable article text extracted from the page, if it is a web page.
        ```

        ## For AI agents

        Start with `INDEX.md` or a `tags/*.md` page: they fit in one read and carry the
        `why` line, which is the human's intent. Open individual files for the full text.
        `grep -l "^tags: .*\\bpricing\\b" */*.md` finds every clip with a tag; `why:` lines
        are the best signal of what mattered to the person.

        """
        write(text, to: file)
    }

    private static func write(_ text: String, to url: URL) {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == text { return }
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
