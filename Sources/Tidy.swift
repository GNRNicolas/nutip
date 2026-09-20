// What a page looks like once the pictures are gone.
//
// Nutip is text only, on purpose, and an extracted page does not know that: it
// arrives carrying image lines, rows of shield badges, and the odd non-breaking
// space. None of it is text, and all of it is read as text — in an editor a
// row of six badges is six broken images, which is a hole in the middle of the
// page. This is the one pass that runs between the extractor and the file, so
// what lands in the folder is the thing a person meant to keep.
//
// It never touches a fenced code block: the whitespace in there is the content.
import Foundation

enum Tidy {

    /// An alt text worth keeping as a sentence. Most are a file name or a
    /// layout hint — `line`, `Blur`, `hero-screenshot`, the project's own name
    /// — and dropping those loses nothing. The few that are a real description
    /// of the picture are the only text the picture ever had, so they stay, as
    /// plain prose.
    private static let descriptiveAlt = 30

    static func markdown(_ raw: String) -> String {
        var out: [String] = []
        var blanks = 0
        var fence: String?

        for original in unwrapped(spaces(raw)).components(separatedBy: "\n") {
            let line = trimmedEnd(original)
            let marker = line.trimmingCharacters(in: .whitespaces)

            // Inside a fence, every character is content, including the spaces.
            if let open = fence {
                out.append(line)
                if marker.hasPrefix(open) { fence = nil }
                continue
            }
            if marker.hasPrefix("```") || marker.hasPrefix("~~~") {
                fence = String(marker.prefix(3))
                blanks = 0
                out.append(line)
                continue
            }

            var cleaned = withoutImages(line)
            // A table's empty cells are its shape, not stray spacing.
            if !cleaned.contains("|") { cleaned = collapsed(cleaned) }
            cleaned = trimmedEnd(cleaned)

            if cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
                // A line that was nothing but pictures becomes a blank, not an
                // empty line of its own: six badges in a row used to leave six
                // gaps behind them.
                blanks += 1
                if blanks == 1, !out.isEmpty { out.append("") }
                continue
            }
            blanks = 0
            out.append(cleaned)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        while out.first?.isEmpty == true { out.removeFirst() }
        return out.joined(separator: "\n")
    }

    /// Markdown wrapped across lines, put back on one. A link or an image whose
    /// target is long is regularly broken mid-URL by whatever produced the
    /// file, and everything here reads one line at a time: the opening half
    /// would stay put and the tail turn up on its own as `.webp)`.
    static func unwrapped(_ text: String) -> String {
        var out: [String] = []
        var held = ""
        var joins = 0
        for raw in text.components(separatedBy: "\n") {
            let line = held.isEmpty ? raw : held + raw.trimmingCharacters(in: .whitespaces)
            let opens = line.filter { $0 == "(" }.count
            let closes = line.filter { $0 == ")" }.count
            // Five is well past any real URL split, and it stops one stray
            // bracket from swallowing the rest of the page.
            if line.contains("]("), opens > closes, joins < 5 {
                held = line
                joins += 1
                continue
            }
            out.append(line)
            held = ""
            joins = 0
        }
        if !held.isEmpty { out.append(held) }
        return out.joined(separator: "\n")
    }

    // MARK: Pieces

    /// The spaces that are not the space bar: a non-breaking space reads as a
    /// space and sorts, searches and wraps as something else. Zero-width
    /// characters go entirely — they are invisible in every editor and they
    /// break a search for the word they sit inside.
    private static func spaces(_ text: String) -> String {
        var s = text
        for exotic in ["\u{00a0}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
                       "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200a}",
                       "\u{202f}", "\u{205f}", "\u{3000}"] {
            s = s.replacingOccurrences(of: exotic, with: " ")
        }
        for invisible in ["\u{200b}", "\u{200c}", "\u{200d}", "\u{feff}"] {
            s = s.replacingOccurrences(of: invisible, with: "")
        }
        return s
    }

    /// Images out, and a badge — an image wrapped in a link — out with them.
    /// The link is taken first: strip the picture inside it and what is left is
    /// `[](href)`, which no longer looks like anything.
    private static func withoutImages(_ line: String) -> String {
        var s = replacing(line, #"\[\s*!\[([^\]]*)\]\([^)]*\)\s*\]\([^)]*\)"#, with: rescued)
        s = replacing(s, #"!\[([^\]]*)\]\([^)]*\)"#, with: rescued)
        return s
    }

    private static func rescued(_ alt: String) -> String {
        let text = alt.trimmingCharacters(in: .whitespaces)
        return text.count >= descriptiveAlt && text.contains(" ") ? text : ""
    }

    /// Runs of spaces left inside a line, usually where a picture used to be.
    /// The indent is kept: it is what tells a nested list item from a new one,
    /// and an indented code block from a paragraph.
    private static func collapsed(_ line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        return indent + rest.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }

    private static func trimmedEnd(_ line: String) -> String {
        String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }

    /// `replacingOccurrences` cannot decide per match, and whether an alt text
    /// survives depends on what it says.
    private static func replacing(_ s: String, _ pattern: String,
                                  with transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let text = s as NSString
        var out = ""
        var last = 0
        for match in re.matches(in: s, range: NSRange(location: 0, length: text.length)) {
            out += text.substring(with: NSRange(location: last, length: match.range.location - last))
            let group = match.range(at: 1)
            out += transform(group.location == NSNotFound ? "" : text.substring(with: group))
            last = match.range.location + match.range.length
        }
        return out + text.substring(from: last)
    }
}
