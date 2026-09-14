// The words a clip is about, derived from the clip itself.
//
// Full-text search matches words, and the question asked months later rarely
// uses the words the page used ("le site pour save des trucs" against a page
// that says "download"). Keywords widen the target without asking the user to
// type anything: they are counted from the text already saved, in the two
// languages this user writes in, and written into the frontmatter where both a
// human and an agent can correct them.
//
// No model, no network, no API key: a frequency count and a stop list.
import Foundation

enum Keywords {
    /// How many to keep. Enough to catch a paraphrase, few enough to stay
    /// readable in the frontmatter and not to drown the index.
    static let count = 8

    /// Words too short to carry a topic, with the exception of the acronyms
    /// this user's clips are full of (API, RLS, SQL, IA).
    private static let minLength = 3

    /// How many times a word has to come back before it counts as a subject.
    /// Two is noise on a long page; three separates "benchmark" from "wanted".
    private static let repeats = 3

    static func derive(title: String, why: String, body: String, tags: [String]) -> [String] {
        // A short text clip is its own summary: counting words in three lines
        // yields the three lines back, and the index already holds them.
        guard title.count + why.count + body.count >= 200 else { return [] }

        // The title and the reason are already indexed, and weighted above the
        // body when ranking: repeating their words here would widen nothing.
        // What only a keyword can add is the vocabulary buried in the page —
        // so the body is what gets counted, and a word has to come back often
        // enough to be what the page is *about* rather than a word it used.
        var counts: [String: Int] = [:]
        var spellings: [String: String] = [:]
        for word in words(in: body) {
            let key = word.tagKey
            counts[key, default: 0] += 1
            if spellings[key] == nil { spellings[key] = word }
        }
        let titled = Set(words(in: title).map(\.tagKey))
        for key in titled where counts[key] != nil { counts[key]! += repeats * 2 }
        for tag in tags { counts[tag.tagKey] = nil }

        return counts.filter { $0.value >= repeats }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(count)
            .compactMap { spellings[$0.key] }
    }

    /// A word that says nothing about a subject. Used both when counting a
    /// clip's keywords and when reading a question: "les règles d'ergonomie
    /// pour relire une interface" carries four words that match half the
    /// folder, and they outvote the two that matter.
    static func isNoise(_ word: String) -> Bool {
        let w = word.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        return w.count < minLength || grammar.contains(w)
    }

    private static func words(in text: String) -> [String] {
        stripLinks(text).lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { word in
                word.count >= minLength && word.count <= 24
                    && !grammar.contains(word.folding(options: .diacriticInsensitive, locale: .current))
                    && !boilerplate.contains(word.folding(options: .diacriticInsensitive, locale: .current))
            }
    }

    /// Link targets, counted as words, make every clip about its own domain:
    /// a page with forty links to danluu.com has "danluu" as its first subject.
    /// The visible label of a link stays — that one is prose.
    private static func stripLinks(_ text: String) -> String {
        var out = ""
        var depth = 0          // inside (...) right after a ] — a link target
        var previous: Character = " "
        var angle = false      // inside <...> — a bare URL
        for c in text {
            if c == "(", previous == "]" { depth += 1; previous = c; continue }
            if depth > 0 {
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1 }
                previous = c
                continue
            }
            if c == "<" { angle = true; previous = c; continue }
            if angle { if c == ">" { angle = false }; previous = c; continue }
            out.append(c)
            previous = c
        }
        // Bare URLs written as plain text, which no bracket marks out.
        return out.replacingOccurrences(of: #"\bhttps?://\S+"#, with: " ", options: .regularExpression)
    }

    /// Words that carry no subject in any sentence. Dropped from a clip's
    /// keywords *and* from a question: "comment parler aux utilisateurs" is
    /// two words of subject and three of French.
    private static let grammar: Set<String> = [
        // French
        "les", "des", "une", "est", "sont", "pour", "dans", "par", "sur", "avec", "sans", "mais",
        "que", "qui", "quoi", "dont", "cette", "ces", "son", "ses", "leur", "leurs", "nous", "vous",
        "ils", "elle", "elles", "plus", "moins", "tout", "tous", "toute", "toutes", "meme", "aussi",
        "comme", "faire", "fait", "peut", "peuvent", "etre", "avoir", "cela", "donc", "alors",
        "entre", "apres", "avant", "encore", "ainsi", "chaque", "autre", "autres", "bien", "tres",
        "deux", "trois", "notre", "nos", "votre", "vos", "lui", "eux", "ont", "etait", "sera",
        // English
        "the", "and", "are", "for", "with", "that", "this", "these", "those", "from", "have", "has",
        "had", "was", "were", "been", "being", "but", "not", "you", "your", "yours", "its", "their",
        "they", "them", "there", "here", "what", "which", "who", "whom", "when", "where", "why",
        "how", "all", "any", "each", "some", "such", "only", "own", "same", "than", "then", "too",
        "very", "can", "will", "just", "dont", "should", "now", "into", "out", "off", "over",
        "under", "again", "more", "most", "other", "others", "one", "two", "also", "may", "make",
        "get", "got", "use", "used", "using", "about", "would", "could", "like", "want", "need",
        "see", "seen", "say", "said", "says", "because", "wanted", "know", "think", "thing",
        "things", "much", "many", "even", "still", "well", "way", "ways", "time", "times",
        "lot", "far", "sure", "really", "actually", "though", "while", "after", "before",
        "does", "did", "doing", "goes", "going", "gone", "take", "takes", "give", "gives",
        "come", "comes", "look", "looks", "find", "found", "work", "works", "let", "lets",
        "retrieved", "archived", "original", "good", "bad", "new", "old", "first", "last",
        "next", "back", "long", "short", "big", "small", "better", "best", "isbn", "doi",
    ]

    /// Words every web page carries — cookie banners, navigation, legal
    /// footers — which would otherwise be the most frequent words in the
    /// folder. Dropped when counting a clip's keywords, and **only** then: in a
    /// question these are ordinary subjects. Searching "privacy" returned
    /// nothing at all while a clip titled "Why is privacy so hard?" sat in the
    /// folder, because the one list was doing both jobs.
    private static let boilerplate: Set<String> = [
        "cookies", "cookie", "privacy", "policy", "terms", "login", "sign", "signup", "subscribe",
        "newsletter", "menu", "home", "search", "share", "click", "read", "reading", "page",
        "site", "website", "www", "com", "http", "https", "html", "javascript", "browser",
        "accept", "continue", "copyright", "rights", "reserved", "contact", "support", "help",
    ]
}
