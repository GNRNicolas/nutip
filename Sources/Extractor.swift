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

    /// Under this many characters, an extraction has not found an article.
    private static let thinPage = 400

    private var jobs: [WKWebView: (Extracted?) -> Void] = [:]
    private var timers: [WKWebView: Timer] = [:]

    private lazy var script: String? = {
        guard let readability = Resources.url("Readability", "js"),
              let toMarkdown = Resources.url("tomarkdown", "js"),
              let a = try? String(contentsOf: readability, encoding: .utf8),
              let b = try? String(contentsOf: toMarkdown, encoding: .utf8) else {
            Log.write("extractor: bundled scripts missing")
            return nil
        }
        return a + "\n" + b + """

        (function () {
          // Readability assigns innerHTML internally. On a site with a Trusted
          // Types policy — YouTube, every Google property, and more each year —
          // that throws and the extraction is lost. A default policy that
          // passes the string through restores it. Wrapped: a site may forbid
          // creating one, and then we fall back to the title and description.
          try {
            if (window.trustedTypes && window.trustedTypes.createPolicy) {
              window.trustedTypes.createPolicy('default', { createHTML: function (s) { return s; } });
            }
          } catch (e) {}
          function meta(names) {
            for (var i = 0; i < names.length; i++) {
              var el = document.querySelector(names[i]);
              var v = el && (el.content || '').trim();
              if (v) return v;
            }
            return '';
          }
          // A landing page or an app has no article, and Readability returns a
          // line of boilerplate. Its own description is the better sentence.
          var description = meta([
            'meta[property="og:description"]',
            'meta[name="description"]',
            'meta[name="twitter:description"]'
          ]);
          var heading = meta(['meta[property="og:title"]']) || document.title || '';
          try {
            var doc = document.cloneNode(true);
            var article = new Readability(doc, { charThreshold: 200 }).parse();
            if (!article) return { title: heading, byline: '', excerpt: description, markdown: '', description: description };
            // Not innerHTML: a site with a Trusted Types policy (YouTube and
            // every Google property, and more each year) makes that assignment
            // throw, and the whole extraction was lost with it. DOMParser
            // parses the same string and is not covered by the policy.
            var wrapper = new DOMParser()
              .parseFromString('<div>' + article.content + '</div>', 'text/html')
              .body.firstChild;
            return {
              title: article.title || heading,
              byline: article.byline || '',
              excerpt: article.excerpt || description,
              markdown: nutipToMarkdown(wrapper, location.href),
              description: description
            };
          } catch (e) {
            // Readability failed, but the page still said what it is. Handing
            // back the title and the description beats handing back nothing:
            // the nut keeps its real name instead of its domain.
            return { title: heading, byline: '', excerpt: description, markdown: '',
                     description: description, error: String(e) };
          }
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
                Log.write("extractor: readability \(err) — kept the title")
                // Fall through: the script now returns the page's own title and
                // description alongside the error, and those are worth keeping.
            }
            var out = Extracted(title: dict["title"] as? String ?? "",
                                byline: dict["byline"] as? String ?? "",
                                excerpt: dict["excerpt"] as? String ?? "",
                                // Tidied here rather than at each caller: this is the
                                // one door every extracted page comes through, so
                                // `nutip extract` prints exactly what a save writes.
                                markdown: Tidy.markdown(dict["markdown"] as? String ?? ""))
            // Below this, what came back is a cookie banner or a tagline, not a
            // page: the site's own description says more in one line.
            let description = (dict["description"] as? String ?? "").trimmed
            if out.markdown.count < Extractor.thinPage, !description.isEmpty,
               !out.markdown.contains(description) {
                out.markdown = out.markdown.isEmpty ? description : description + "\n\n" + out.markdown
            }
            // A page with no article still knows its own name. Returning nil
            // here threw that away, and a saved YouTube video ended up titled
            // "youtube.com": nothing to search, nothing to recognise. Anything
            // at all is worth handing back; the caller decides what to do with
            // a nut that has a title and no text.
            let nothing = out.markdown.isEmpty && out.title.trimmed.isEmpty
            self?.finish(web, with: nothing ? nil : out)
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
