// Full-text search over the clips, in SQLite (FTS5), rebuilt from the
// Markdown files so it can always be thrown away.
import Foundation
import SQLite3

enum Index {
    private static var db: OpaquePointer?
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Settings.appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One database per folder, so switching folders never mixes results.
        let key = Slug.make(Settings.folder?.path ?? "none", limit: 80)
        return dir.appendingPathComponent("index-\(key).sqlite")
    }

    /// Opens (or creates) the database and brings it in line with the folder.
    /// A full rebuild is a few milliseconds per hundred clips, so it simply
    /// runs at every launch: no staleness to reason about.
    static func open() {
        close()
        guard sqlite3_open(file.path, &db) == SQLITE_OK else {
            Log.write("index: cannot open \(file.path)")
            db = nil
            return
        }
        exec("""
        CREATE TABLE IF NOT EXISTS clips (
            path TEXT PRIMARY KEY, title TEXT, url TEXT, domain TEXT, source TEXT,
            captured_at REAL, tags TEXT, why TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(path UNINDEXED, title, tags, why, body, tokenize='unicode61 remove_diacritics 2');
        """)
        rebuild()
    }

    static func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    static func rebuild() {
        guard db != nil else { return }
        exec("BEGIN; DELETE FROM clips; DELETE FROM fts;")
        for clip in Store.all() { insert(clip) }
        exec("COMMIT;")
    }

    static func upsert(_ clip: Clip) {
        guard db != nil else { return }
        exec("BEGIN;")
        remove(path: clip.path, inTransaction: true)
        insert(clip)
        exec("COMMIT;")
    }

    static func remove(path: String, inTransaction: Bool = false) {
        guard db != nil else { return }
        run("DELETE FROM clips WHERE path = ?", [path])
        run("DELETE FROM fts WHERE path = ?", [path])
    }

    private static func insert(_ clip: Clip) {
        run("INSERT INTO clips (path, title, url, domain, source, captured_at, tags, why) VALUES (?,?,?,?,?,?,?,?)",
            [clip.path, clip.title, clip.url ?? "", clip.domain, clip.source,
             clip.capturedAt.timeIntervalSince1970, clip.tags.joined(separator: " "), clip.why])
        run("INSERT INTO fts (path, title, tags, why, body) VALUES (?,?,?,?,?)",
            [clip.path, clip.title, clip.tags.joined(separator: " "), clip.why, String(clip.body.prefix(20_000))])
    }

    // MARK: Queries

    /// Newest first. Empty query → the most recent clips.
    static func search(_ query: String, tags: [String] = [], limit: Int = 50) -> [Clip] {
        guard db != nil else {
            return Array(Store.all().filter { Set(tags).isSubset(of: $0.tags) }.prefix(limit))
        }
        let q = query.trimmed
        let paths: [String]
        if q.isEmpty, tags.isEmpty {
            paths = rows("SELECT path FROM clips ORDER BY captured_at DESC LIMIT ?", [limit])
        } else {
            // Every word as a prefix, all required. `#tag` restricts to the tags column.
            let terms = q.split(separator: " ").map { word -> String in
                let w = String(word)
                let clean = w.trimmingCharacters(in: CharacterSet(charactersIn: "#\"'*"))
                    .replacingOccurrences(of: "\"", with: "")
                guard !clean.isEmpty else { return "" }
                return w.hasPrefix("#") ? "tags:\"\(clean)\"*" : "\"\(clean)\"*"
            }.filter { !$0.isEmpty } + tags.map { "tags:\"\($0)\"" }
            paths = rows("""
                SELECT fts.path FROM fts JOIN clips ON clips.path = fts.path
                WHERE fts MATCH ? ORDER BY clips.captured_at DESC LIMIT ?
                """, [terms.joined(separator: " AND "), limit])
        }
        return paths.compactMap { try? Store.read(path: $0) }
    }

    /// The clip already saved from this URL, if any (ignoring the fragment).
    static func existing(url: String) -> Clip? {
        guard db != nil else { return Store.all().first { normalize($0.url ?? "") == normalize(url) } }
        let norm = normalize(url)
        let candidates = rows("SELECT path FROM clips WHERE url != '' ORDER BY captured_at DESC LIMIT 5000", [])
        for path in candidates {
            if let clip = try? Store.read(path: path), normalize(clip.url ?? "") == norm { return clip }
        }
        return nil
    }

    private static func normalize(_ url: String) -> String {
        var s = url.trimmed.lowercased()
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.replacingOccurrences(of: "^https?://(www\\.)?", with: "", options: .regularExpression)
    }

    // MARK: SQLite plumbing

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

    private static func rows(_ sql: String, _ args: [Any]) -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Log.write("index: prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
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
