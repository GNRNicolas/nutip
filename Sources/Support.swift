// Shared plumbing: logging, preferences, small string helpers.
import AppKit
import Foundation

// MARK: - Log

enum Log {
    private static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/nutip.log")

    /// Append-only file for an app that runs for months: it needs a cap.
    private static let sizeLimit = 256 * 1024

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > sizeLimit { try? handle.truncate(atOffset: 0) }
        try? handle.write(contentsOf: data)
    }
}

// MARK: - Settings

/// Every preference, with the key it is stored under. `NUTIP_DIR` in the
/// environment overrides the folder, which is how the CLI and tests point the
/// app at a scratch directory.
enum Settings {
    /// The app's own domain. Inside the bundle `.standard` is that domain (and
    /// naming it as a suite is refused); through the `nutip` symlink
    /// `Bundle.main` is /opt/homebrew/bin, so the suite has to be named.
    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == "fr.nicolasgarnier.nutip"
        ? .standard : (UserDefaults(suiteName: "fr.nicolasgarnier.nutip") ?? .standard)

    static let appName = "Nutip"
    static let defaultTags = ["reading", "ideas", "competitors", "reference"]
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Nutip")

    /// The folder every clip is written to. Nil until onboarding picked one.
    static var folder: URL? {
        get {
            if let env = ProcessInfo.processInfo.environment["NUTIP_DIR"], !env.isEmpty {
                return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
            }
            guard let path = defaults.string(forKey: "folder"), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue?.path, forKey: "folder") }
    }

    /// The user's tags, in the order the palette lists them: the first nine
    /// answer to the keys 1 to 9.
    static var tags: [String] {
        get { (defaults.stringArray(forKey: "tags") ?? defaultTags).map(Slug.tag).uniquedTags() }
        set { defaults.set(newValue.map(Slug.tag).uniquedTags(), forKey: "tags") }
    }

    static var onboarded: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded") }
    }

    /// How many entries INDEX.md and tags/*.md list. Everything older stays
    /// on disk and grep-able; the index is a window, not an archive.
    static let indexLimit = 500

    /// How much extracted page text one clip may hold. A clip is meant to be
    /// read in one go, by a person or an agent; past this the link is better
    /// than the text, and the folder stays a folder rather than an archive.
    static let bodyLimit = 40_000
}

// MARK: - Tags

extension String {
    /// What two tags are compared on: `Reading`, `reading` and `Réading` are
    /// one tag. Same folding as the search index (`remove_diacritics`), so a
    /// tag never behaves one way in the list and another in a query.
    var tagKey: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}

extension Array where Element == String {
    /// De-duplicates tags the way they compare, keeping the first spelling:
    /// the one in Settings wins over the one already in a file.
    func uniquedTags() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in self where !tag.isEmpty {
            if seen.insert(tag.tagKey).inserted { out.append(tag) }
        }
        return out
    }

    func containsTag(_ tag: String) -> Bool { contains { $0.tagKey == tag.tagKey } }
}

// MARK: - Slugs

enum Slug {
    /// `Hello, World! Ünïcode` → `hello-world-unicode`, at most `limit` chars.
    static func make(_ text: String, limit: Int = 60) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var out = ""
        var dash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
            if out.count >= limit { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "clip" : out
    }

    /// A tag keeps the letters that were typed, capitals and accents included:
    /// `Pricing-Model`, `Réflexions`, `本`. Only what would break a file name,
    /// a relative link or a `#tag` in a search is folded away: spaces and
    /// punctuation become a dash. Case never makes two tags (see `uniquedTags`).
    static func tag(_ text: String) -> String {
        var out = ""
        var dash = false
        for scalar in text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

// MARK: - Dates

enum Dates {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func month(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Small helpers

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// One line, at most `limit` characters, with an ellipsis if cut.
    func excerpt(_ limit: Int = 120) -> String {
        let flat = components(separatedBy: .newlines).map { $0.trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)).trimmed + "…" : flat
    }

    var isURL: Bool {
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }
}

extension URL {
    /// `www.example.com/path` → `example.com`.
    var domain: String {
        (host ?? "").replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}
