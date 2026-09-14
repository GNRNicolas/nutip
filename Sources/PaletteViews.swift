// The pieces of the palette that have no state of their own: the panel
// subclass that can take keys, the rows of the list, and the mask that rounds
// a blurred window.
import AppKit

/// A borderless NSPanel refuses to become key by default, and a panel that is
/// not key receives no keyboard events at all. This is the whole subclass.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Shape

enum PaletteShape {
/// A stretchable rounded rectangle for `NSVisualEffectView.maskImage`.
static func roundedMask(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}
}

// MARK: - Rows

final class PaletteRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 14, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

final class TagCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("tag")
    private let number = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = TagCell.id
        hintLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.isHidden = true
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)
        number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        number.textColor = .tertiaryLabelColor
        number.alignment = .center
        name.font = .systemFont(ofSize: 14)
        check.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        check.contentTintColor = .controlAccentColor
        for v in [number, name, check] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            number.widthAnchor.constraint(equalToConstant: 16),
            number.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(number n: String, tag: String, checked: Bool, hint: String? = nil) {
        number.stringValue = n
        name.stringValue = tag
        if let hint {
            check.image = nil
            hintLabel.stringValue = hint
            hintLabel.isHidden = false
        } else {
            hintLabel.isHidden = true
            check.image = NSImage(systemSymbolName: checked ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
            check.contentTintColor = checked ? .controlAccentColor : .quaternaryLabelColor
        }
    }
}

final class ClipCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("clip")
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    /// The passage that matched, with the matched words in bold. Only a search
    /// produces one, so the row is two lines tall until it appears.
    private let match = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = ClipCell.id
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        meta.font = .systemFont(ofSize: 11.5)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meta.maximumNumberOfLines = 1
        match.font = .systemFont(ofSize: 11.5)
        match.textColor = .tertiaryLabelColor
        match.lineBreakMode = .byTruncatingTail
        match.maximumNumberOfLines = 1
        for v in [title, meta, match] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            match.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            match.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            match.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ clip: Clip) {
        title.stringValue = clip.title
        var parts = [Dates.relative(clip.capturedAt)]
        if !clip.domain.isEmpty { parts.append(clip.domain) } else { parts.append(clip.source) }
        if !clip.tags.isEmpty { parts.append(clip.tags.map { "#\($0)" }.joined(separator: " ")) }
        var line = parts.joined(separator: " · ")
        if !clip.why.isEmpty { line += " · \(clip.why)" }
        meta.stringValue = line
        match.attributedStringValue = ClipCell.highlighted(clip.match)
        match.isHidden = clip.match.isEmpty
    }

    /// FTS5 wraps what it matched in two control characters. Between them the
    /// text goes bold and takes the normal label colour: the eye lands on the
    /// word it searched for, which is the whole point of showing the passage.
    static func highlighted(_ raw: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.tertiaryLabelColor]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.labelColor]
        var emphasised = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(NSAttributedString(string: buffer, attributes: emphasised ? bold : plain))
            buffer = ""
        }
        for c in raw.replacingOccurrences(of: "\n", with: " ") {
            switch c {
            case String.matchOpen: flush(); emphasised = true
            case String.matchClose: flush(); emphasised = false
            default: buffer.append(c)
            }
        }
        flush()
        return out
    }
}
