// Full-text search over the clips, in SQLite (FTS5), kept in line with the
// Markdown files so it can always be thrown away. It is also what the
// generated INDEX.md and tags/ pages are written from: nothing that runs
// after a save is allowed to re-read the whole folder.
import Foundation
import SQLite3

/// One row of the index: everything but the body. Enough to list, search,
/// count and write an index line without opening a single file.
enum Index {
    private static var db: OpaquePointer?
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Bumped when the columns change: the database is rebuilt instead of migrated.
    private static let schema: Int32 = 3

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Settings.appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One database per folder, so switching folders never mixes results.
        let key = Slug.make(Settings.folder?.path ?? "none", limit: 80)
        return dir.appendingPathComponent("index-\(key).sqlite")
    }

    /// Opens (or creates) the database and brings it in line with the folder.
    /// Returns true when the folder had changed under it, which is the signal
    /// to rewrite every generated page rather than the ones a save touched.
    @discardableResult
    static func open() -> Bool {
        close()
        guard sqlite3_open(file.path, &db) == SQLITE_OK else {
            Log.write("index: cannot open \(file.path)")
            db = nil
            return false
        }
        if version() != schema {
            exec("DROP TABLE IF EXISTS clips; DROP TABLE IF EXISTS fts;")
            exec("PRAGMA user_version = \(schema);")
        }
        exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS clips (
            path TEXT PRIMARY KEY, title TEXT, url TEXT, url_key TEXT, domain TEXT, source TEXT,
            captured_at REAL, month TEXT, tags TEXT, tags_key TEXT, why TEXT, mtime REAL, size INTEGER
        );
        CREATE INDEX IF NOT EXISTS clips_date ON clips (captured_at DESC);
        CREATE INDEX IF NOT EXISTS clips_url ON clips (url_key);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(path UNINDEXED, title, tags, why, body, tokenize='unicode61 remove_diacritics 2');
        """)
        return sync()
    }

    private static func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private static func version() -> Int32 {
        guard let db else { return -1 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    /// Reads only the files that appeared or changed since last time, from
    /// their modification date and size. A folder of ten thousand clips costs
    /// one directory listing, not ten thousand file reads.
    @discardableResult
    private static func sync() -> Bool {
        guard db != nil else { return false }
        let disk = Store.stamps()
        var known: [String: Stamp] = [:]
        forEachRow("SELECT path, mtime, size FROM clips", []) { stmt in
            guard let c = sqlite3_column_text(stmt, 0) else { return }
            known[String(cString: c)] = Stamp(modified: sqlite3_column_double(stmt, 1),
                                              size: Int(sqlite3_column_int64(stmt, 2)))
        }
        let changed = disk.filter { path, stamp in known[path] != stamp }.map(\.key)
        let gone = known.keys.filter { disk[$0] == nil }
        guard !changed.isEmpty || !gone.isEmpty else { return false }
        exec("BEGIN;")
        for path in gone { remove(path: path) }
        for path in changed {
            remove(path: path)
            if let clip = try? Store.read(path: path), let stamp = disk[path] { insert(clip, stamp: stamp) }
        }
        exec("COMMIT;")
        Log.write("index: \(changed.count) read, \(gone.count) gone, \(disk.count) clips")
        return true
    }

    /// Throws the index away and reads every file again (`nutip reindex`).
    @discardableResult
    static func rebuild() -> Int {
        guard db != nil else { return 0 }
        exec("BEGIN; DELETE FROM clips; DELETE FROM fts;")
        let disk = Store.stamps()
        var n = 0
        for (path, stamp) in disk {
            if let clip = try? Store.read(path: path) { insert(clip, stamp: stamp); n += 1 }
        }
        exec("COMMIT;")
        return n
    }

    static func upsert(_ clip: Clip) {
        guard db != nil else { return }
        exec("BEGIN;")
        remove(path: clip.path)
        insert(clip, stamp: clip.fileURL.flatMap(Store.stamp) ?? Stamp(modified: 0, size: 0))
        exec("COMMIT;")
    }

    static func remove(path: String) {
        guard db != nil else { return }
        run("DELETE FROM clips WHERE path = ?", [path])
        run("DELETE FROM fts WHERE path = ?", [path])
    }

    private static func insert(_ clip: Clip, stamp: Stamp) {
        run("""
            INSERT INTO clips (path, title, url, url_key, domain, source, captured_at, month, tags, tags_key, why, mtime, size)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [clip.path, clip.title, clip.url ?? "", normalize(clip.url ?? ""), clip.domain, clip.source,
             clip.capturedAt.timeIntervalSince1970, String(clip.path.prefix(7)),
             clip.tags.joined(separator: " "), clip.tags.map(\.tagKey).joined(separator: " "),
             clip.why, stamp.modified, stamp.size])
        run("INSERT INTO fts (path, title, tags, why, body) VALUES (?,?,?,?,?)",
            [clip.path, clip.title, clip.tags.joined(separator: " "), clip.why, String(clip.body.prefix(20_000))])
    }

    // MARK: Queries

    /// Newest first. Empty query → the most recent clips. The rows carry no
    /// body: nothing here opens a file.
    static func search(_ query: String, tags: [String] = [], limit: Int = 50) -> [Clip] {
        guard db != nil else {
            return Array(Store.all().filter { Set(tags).isSubset(of: $0.tags) }.prefix(limit))
        }
        let q = query.trimmed
        if q.isEmpty, tags.isEmpty {
            return clips("SELECT \(columns) FROM clips ORDER BY captured_at DESC LIMIT ?", [limit])
        }
        // Every word as a prefix, all required. `#tag` restricts to the tags column.
        let terms = q.split(separator: " ").map { word -> String in
            let w = String(word)
            let clean = w.trimmingCharacters(in: CharacterSet(charactersIn: "#\"'*"))
                .replacingOccurrences(of: "\"", with: "")
            guard !clean.isEmpty else { return "" }
            return w.hasPrefix("#") ? "tags:\"\(clean)\"*" : "\"\(clean)\"*"
        }.filter { !$0.isEmpty } + tags.map { "tags:\"\($0)\"" }
        return clips("""
            SELECT \(columns) FROM clips JOIN fts ON clips.path = fts.path
            WHERE fts MATCH ? ORDER BY clips.captured_at DESC LIMIT ?
            """, [terms.joined(separator: " AND "), limit])
    }

    /// The most recent clips, optionally of one tag: what an index page lists.
    static func recent(tag: String? = nil, limit: Int) -> [Clip] {
        guard db != nil else {
            let all = Store.all().filter { tag == nil || $0.tags.containsTag(tag!) }
            return Array(all.prefix(limit))
        }
        if let tag {
            return clips("""
                SELECT \(columns) FROM clips WHERE (' ' || tags_key || ' ') LIKE ?
                ORDER BY captured_at DESC LIMIT ?
                """, ["% \(tag.tagKey) %", limit])
        }
        return clips("SELECT \(columns) FROM clips ORDER BY captured_at DESC LIMIT ?", [limit])
    }

    /// Every clip of one month, oldest first: a monthly index is complete.
    static func month(_ month: String) -> [Clip] {
        guard db != nil else { return Store.all().filter { $0.path.hasPrefix(month) }.reversed() }
        return clips("SELECT \(columns) FROM clips WHERE month = ? ORDER BY captured_at ASC", [month])
    }

    /// Months that hold clips, newest first, with how many each holds.
    static func months() -> [(String, Int)] {
        var out: [(String, Int)] = []
        forEachRow("SELECT month, COUNT(*) FROM clips GROUP BY month ORDER BY month DESC", []) { stmt in
            guard let c = sqlite3_column_text(stmt, 0) else { return }
            out.append((String(cString: c), Int(sqlite3_column_int64(stmt, 1))))
        }
        return out
    }

    /// Every tag in use, with its count, most used first. Spellings that
    /// differ only by case or accent are one tag. The spelling shown is the
    /// one in Settings, or failing that the one most files use: whichever it
    /// is, it does not change between two runs.
    static func tagCounts() -> [(String, Int)] {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        forEachRow("SELECT tags FROM clips", []) { stmt in
            guard let c = sqlite3_column_text(stmt, 0) else { return }
            for raw in String(cString: c).split(separator: " ") {
                let tag = String(raw)
                counts[tag.tagKey, default: 0] += 1
                spellings[tag.tagKey, default: [:]][tag, default: 0] += 1
            }
        }
        let configured = Dictionary(Settings.tags.map { ($0.tagKey, $0) }, uniquingKeysWith: { a, _ in a })
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { key, n in
                let best = (spellings[key] ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first?.key
                return (configured[key] ?? best ?? key, n)
            }
    }

    /// How many clips carry any of these tags: what the Settings alert counts
    /// before it lets a tag go.
    static func count(anyOf tags: [String]) -> Int {
        guard db != nil else { return Store.all().filter { $0.tags.contains { tags.containsTag($0) } }.count }
        guard !tags.isEmpty else { return 0 }
        let clause = tags.map { _ in "(' ' || tags_key || ' ') LIKE ?" }.joined(separator: " OR ")
        return count("SELECT COUNT(*) FROM clips WHERE \(clause)", tags.map { "% \($0.tagKey) %" })
    }

    /// The clip already saved from this URL, if any (ignoring the fragment).
    static func existing(url: String) -> Clip? {
        guard db != nil else { return Store.all().first { normalize($0.url ?? "") == normalize(url) } }
        return clips("SELECT \(columns) FROM clips WHERE url_key = ? AND url_key != '' ORDER BY captured_at DESC LIMIT 1",
                     [normalize(url)]).first
    }

    private static func normalize(_ url: String) -> String {
        var s = url.trimmed.lowercased()
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.replacingOccurrences(of: "^https?://(www\\.)?", with: "", options: .regularExpression)
    }

    // MARK: SQLite plumbing

    private static let columns = "clips.path, clips.title, clips.url, clips.source, clips.captured_at, clips.tags, clips.why"

    /// Rows as clips without their body. `Store.save` reloads it before
    /// writing, so an index row can never truncate a file.
    private static func clips(_ sql: String, _ args: [Any]) -> [Clip] {
        var out: [Clip] = []
        forEachRow(sql, args) { stmt in
            func text(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            let url = text(2)
            out.append(Clip(path: text(0), title: text(1), url: url.isEmpty ? nil : url, source: text(3),
                            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                            tags: text(5).split(separator: " ").map(String.init), why: text(6),
                            body: "", bodyLoaded: false))
        }
        return out
    }

    private static func count(_ sql: String, _ args: [Any]) -> Int {
        var n = 0
        forEachRow(sql, args) { stmt in n = Int(sqlite3_column_int64(stmt, 0)) }
        return n
    }

    private static func exec(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.write("index: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func run(_ sql: String, _ args: [Any]) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Log.write("index: prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.write("index: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(60))")
        }
    }

    private static func forEachRow(_ sql: String, _ args: [Any], _ body: (OpaquePointer) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Log.write("index: prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        while sqlite3_step(stmt) == SQLITE_ROW { body(stmt) }
    }

    private static func bind(_ stmt: OpaquePointer, _ args: [Any]) {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }
}

/// What tells the index a file has changed without reading it.
struct Stamp: Equatable {
    var modified: Double
    var size: Int
}
