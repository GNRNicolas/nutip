// What to save when the hotkey fires: the clipboard, and nothing else.
//
// Zero permissions by design. Reading a selection needs Accessibility, asking
// a browser for its page needs Automation, and both grants die every time an
// ad-hoc build is reinstalled. So the gesture is "copy, then hotkey", and the
// clipboard is read for everything it carries: the text, and the page it was
// copied from when the browser says so (Chromium writes the source URL,
// Safari a web archive that contains it).
import AppKit
import Foundation

struct CaptureContext {
    var appName: String         // frontmost app when the hotkey fired
    var selection: String       // text on the clipboard ("" for a bare URL)
    var url: String?            // a copied URL, or the page the text came from
    var pageTitle: String?
    var changeCount: Int        // pasteboard generation, to notice a stale clipboard

    var isEmpty: Bool { selection.trimmed.isEmpty && url == nil }
    var isStale: Bool { changeCount == Capture.lastSavedChangeCount }

    /// "Safari · example.com", "Notes", "Clipboard".
    var source: String {
        let site = url.flatMap(URL.init(string:))?.domain ?? ""
        if appName.isEmpty { return site.isEmpty ? "Clipboard" : site }
        return site.isEmpty ? appName : "\(appName) · \(site)"
    }

    /// The best title we can offer before any page is fetched.
    var suggestedTitle: String {
        if let pageTitle, !pageTitle.trimmed.isEmpty { return pageTitle.trimmed }
        if !selection.trimmed.isEmpty { return selection.excerpt(70) }
        if let url { return URL(string: url)?.domain ?? url }
        return "Untitled nut"
    }
}

enum Capture {
    /// Pasteboard generation of the last nut saved, so pressing the hotkey
    /// again without copying anything new can be pointed out.
    static var lastSavedChangeCount = -1

    static func current() -> CaptureContext {
        let board = NSPasteboard.general
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        var ctx = CaptureContext(appName: app, selection: "", url: nil, pageTitle: nil, changeCount: board.changeCount)

        let text = board.string(forType: .string)?.trimmed ?? ""
        if text.isURL {
            ctx.url = text
        } else {
            ctx.selection = text
            if let page = sourcePage(board) {
                ctx.url = page.url
                ctx.pageTitle = page.title
            }
        }
        Log.write("capture: front=\(app) text=\(text.count) url=\(ctx.url ?? "-")")
        return ctx
    }

    // MARK: Where the clipboard came from

    private static let chromiumSource = NSPasteboard.PasteboardType("org.chromium.source-url")
    private static let webArchive = NSPasteboard.PasteboardType("com.apple.webarchive")
    private static let urlsWithTitles = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")

    /// The page a copied piece of text belongs to, when the browser left it
    /// on the pasteboard. Chrome, Arc, Brave, Edge: a plain URL type. Safari:
    /// a web archive whose main resource carries the URL.
    static func sourcePage(_ board: NSPasteboard) -> (url: String, title: String?)? {
        if let s = board.string(forType: chromiumSource)?.trimmed, s.isURL { return (s, nil) }
        if let data = board.data(forType: webArchive),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let main = plist["WebMainResource"] as? [String: Any],
           let s = (main["WebResourceURL"] as? String)?.trimmed, s.isURL {
            return (s, nil)
        }
        if let data = board.data(forType: urlsWithTitles),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String]],
           plist.count == 2, let s = plist[0].first?.trimmed, s.isURL {
            return (s, plist[1].first)
        }
        return nil
    }
}
