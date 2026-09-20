// The right-hand pane in browse: what the highlighted nut actually says.
//
// Browsing used to stop at a two-line row — to find out whether a nut was the
// one you wanted you opened the file in another app, which ends the browse.
// The pane turns the list into something you can walk down: ↑↓ moves, the text
// follows. It only ever reads. Editing is still ⌘E, and the file is still the
// truth.
import AppKit

final class PreviewPane: NSView {
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let why = NSTextField(labelWithString: "")
    private let line = NSBox()
    private let text = NSTextView()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "")
    private let head = NSStackView()

    /// Past this, the pane is showing more than anyone reads at a glance and
    /// the layout starts costing something. The file has the rest.
    private static let bodyLimit = 8_000

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.maximumNumberOfLines = 3
        meta.font = .systemFont(ofSize: 11.5)
        meta.textColor = .secondaryLabelColor
        meta.maximumNumberOfLines = 2
        why.font = .systemFont(ofSize: 12.5)
        why.textColor = .controlAccentColor
        why.maximumNumberOfLines = 3
        for label in [title, meta, why] {
            // Wrapping, not truncating on the first line: a label told to take
            // three lines still stops at one unless its cell is allowed to
            // wrap, and a nut's title is regularly longer than the pane.
            label.lineBreakMode = .byWordWrapping
            label.cell?.wraps = true
            label.cell?.isScrollable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        line.boxType = .separator

        placeholder.font = .systemFont(ofSize: 12.5)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 2

        // Read-only and unselectable on purpose. The panel is non-activating,
        // and a click that made the text view first responder would take the
        // caret out of the search field, the one thing that must never move.
        // Unselectable is what does it: a text view that can neither be edited
        // nor select anything refuses to become first responder on its own.
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        head.setViews([title, meta, why], in: .leading)
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 4
        // A vertical stack aligned on its leading edge hands each view its own
        // intrinsic width, and a one-line label's intrinsic width is the whole
        // sentence. Tied to the stack instead, the label has an edge to wrap
        // against and the three lines it was allowed become three lines. This
        // has to follow setViews: until then the two share no ancestor.
        for label in [title, meta, why] {
            label.widthAnchor.constraint(equalTo: head.widthAnchor).isActive = true
        }

        for view in [head, line, scroll, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            head.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            line.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            line.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            // A separator pinned between two views and given no height of its
            // own takes every point going. It did: 264 of them, which left the
            // text nothing and made the pane look like it had no body to show.
            line.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: pad),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
        ])
        // The list keeps the width it is given; the pane takes what is left.
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Nothing highlighted, or nothing to highlight: one grey line, rather
    /// than an empty frame that reads as broken.
    func clear(_ message: String) {
        placeholder.stringValue = message
        placeholder.isHidden = false
        for view in [head, line, scroll] { view.isHidden = true }
    }

    func show(_ nut: Nut, body: String) {
        placeholder.isHidden = true
        for view in [head, line, scroll] { view.isHidden = false }
        title.stringValue = nut.title
        var parts = [Dates.relative(nut.capturedAt)]
        parts.append(nut.domain.isEmpty ? nut.source : nut.domain)
        if !nut.tags.isEmpty { parts.append(nut.tags.map { "#\($0)" }.joined(separator: " ")) }
        meta.stringValue = parts.joined(separator: " · ")
        why.stringValue = nut.why
        why.isHidden = nut.why.isEmpty

        text.textStorage?.setAttributedString(PreviewPane.rendered(body.trimmed))
        // A new nut is read from its first line, never from wherever the last
        // one was left.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Markdown, lightly

    /// Enough of Markdown to stop it looking like source: headings stand out,
    /// bullets are bullets, and the punctuation that carries nothing on screen
    /// (`**`, backticks, link targets) goes away. Not a renderer — the pane is
    /// a glance at a file, and a real one would be a dependency and a second
    /// way for the text to be wrong.
    static func rendered(_ markdown: String) -> NSAttributedString {
        let capped = markdown.count > bodyLimit
            ? String(markdown.prefix(bodyLimit)) + "\n\n…"
            : markdown
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let out = NSMutableAttributedString()
        var blanks = 0
        for raw in capped.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // One blank line between blocks, never the four a scraped page
                // sometimes carries.
                blanks += 1
                if blanks == 1, out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: body)) }
                continue
            }
            blanks = 0
            // A rule draws nothing here; it would just be a line of dashes.
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { continue }
            var isHeading = false
            var content = line
            if let hashes = content.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                isHeading = true
                content = String(content[hashes.upperBound...])
            } else if let quote = content.range(of: "^>\\s*", options: .regularExpression) {
                content = String(content[quote.upperBound...])
            } else if let bullet = content.range(of: "^[-*+]\\s+", options: .regularExpression) {
                content = "•  " + content[bullet.upperBound...]
            }
            out.append(NSAttributedString(string: strip(content) + "\n", attributes: isHeading ? heading : body))
        }
        return out
    }

    /// Inline markers that say nothing once the text is styled, and links
    /// reduced to the words a reader sees. Images drop out whole: their alt
    /// text is rarely a sentence, and the pane cannot show the picture anyway.
    private static func strip(_ line: String) -> String {
        var s = line
        for (pattern, replacement) in [
            ("!\\[[^\\]]*\\]\\([^)]*\\)", ""),      // image
            ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),   // link → its text
            ("\\*\\*([^*]+)\\*\\*", "$1"),
            ("__([^_]+)__", "$1"),
            ("`([^`]+)`", "$1"),
        ] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
