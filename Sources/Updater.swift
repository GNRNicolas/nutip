// Asks GitHub whether a newer release exists, and points the user at it.
// Downloads nothing: Nutip is built from source, so the update is a git pull.
import AppKit
import Foundation

enum Updater {
    static let repository = "GNRNicolas/nutip"
    static let homepage = URL(string: "https://github.com/GNRNicolas/nutip")!
    private static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    static var automatic: Bool {
        get { Settings.defaults.object(forKey: "autoUpdate") as? Bool ?? true }
        set { Settings.defaults.set(newValue, forKey: "autoUpdate") }
    }

    private static var lastCheck: Date? {
        get { Settings.defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { Settings.defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func check(manual: Bool) {
        if !manual {
            guard automatic else { return }
            if let last = lastCheck, Date().timeIntervalSince(last) < checkInterval { return }
        }
        lastCheck = Date()

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                Log.write("update check failed: \(error.localizedDescription)")
                if manual { DispatchQueue.main.async { alert("Could not check for updates", error.localizedDescription) } }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if manual { DispatchQueue.main.async { alert("Could not check for updates", "Unreadable response from GitHub.") } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            let safePage = isGitHub(page) ? page : URL(string: "https://github.com/\(repository)/releases/latest")
            DispatchQueue.main.async {
                if isNewer(latest, than: currentVersion) {
                    offer(version: latest, page: safePage)
                } else if manual {
                    alert("Nutip is up to date", "You are running version \(currentVersion).")
                }
            }
        }.resume()
    }

    static func isGitHub(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func offer(version: String, page: URL?) {
        let a = NSAlert()
        a.messageText = "Nutip \(version) is available"
        a.informativeText = "You are running \(currentVersion). Nutip is built from source, so updating is:\n\n    git pull && ./build.sh --install"
        a.addButton(withTitle: "View Release")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn, let page { NSWorkspace.shared.open(page) }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
