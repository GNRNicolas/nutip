// Turns a web page into readable Markdown, off the main thread of the user's
// attention: the palette has already closed when this runs.
//
// A hidden WKWebView loads the page, Mozilla's Readability.js picks the
// article out of it, and a small script (Resources/tomarkdown.js) walks the
// resulting DOM into Markdown. No network code of our own, no HTML parser of
// our own, and pages that need JavaScript to render still work.
import Foundation
import WebKit

struct Extracted {
    var title: String
    var byline: String
    var excerpt: String
    var markdown: String
}

final class Extractor: NSObject, WKNavigationDelegate {
    static let shared = Extractor()

    private var jobs: [WKWebView: (Extracted?) -> Void] = [:]
    private var timers: [WKWebView: Timer] = [:]

    private lazy var script: String? = {
        guard let readability = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let toMarkdown = Bundle.main.url(forResource: "tomarkdown", withExtension: "js"),
              let a = try? String(contentsOf: readability, encoding: .utf8),
              let b = try? String(contentsOf: toMarkdown, encoding: .utf8) else {
            Log.write("extractor: bundled scripts missing")
            return nil
        }
        return a + "\n" + b + """

        (function () {
          try {
            var doc = document.cloneNode(true);
            var article = new Readability(doc, { charThreshold: 200 }).parse();
            if (!article) return null;
            var wrapper = document.createElement('div');
            wrapper.innerHTML = article.content;
            return {
              title: article.title || document.title || '',
              byline: article.byline || '',
              excerpt: article.excerpt || '',
              markdown: nutipToMarkdown(wrapper, location.href)
            };
          } catch (e) { return { error: String(e) }; }
        })();
        """
    }()

    /// Loads `url` and calls back on the main thread, with nil when the page
    /// could not be read within `timeout` seconds.
    func extract(_ url: URL, timeout: TimeInterval = 20, completion: @escaping (Extracted?) -> Void) {
        guard script != nil else { completion(nil); return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        web.navigationDelegate = self
        jobs[web] = completion
        timers[web] = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Log.write("extractor: timeout for \(url)")
            self?.finish(web, with: nil)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        web.load(request)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give late scripts a moment to fill the page (SPA shells, lazy text).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.run(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.write("extractor: \(error.localizedDescription)")
        finish(webView, with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("extractor: \(error.localizedDescription)")
        finish(webView, with: nil)
    }

    private func run(_ web: WKWebView) {
        guard let script, jobs[web] != nil else { return }
        web.evaluateJavaScript(script) { [weak self] result, error in
            if let error { Log.write("extractor: js \(error.localizedDescription)") }
            guard let dict = result as? [String: Any] else { self?.finish(web, with: nil); return }
            if let err = dict["error"] as? String {
                Log.write("extractor: readability \(err)")
                self?.finish(web, with: nil)
                return
            }
            let out = Extracted(title: dict["title"] as? String ?? "",
                                byline: dict["byline"] as? String ?? "",
                                excerpt: dict["excerpt"] as? String ?? "",
                                markdown: (dict["markdown"] as? String ?? "").trimmed)
            self?.finish(web, with: out.markdown.isEmpty ? nil : out)
        }
    }

    private func finish(_ web: WKWebView, with result: Extracted?) {
        timers[web]?.invalidate()
        timers[web] = nil
        guard let completion = jobs.removeValue(forKey: web) else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        completion(result)
    }
}
