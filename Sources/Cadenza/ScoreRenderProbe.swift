import Foundation
import WebKit

/// Puts a score through the real renderer and reports what came out.
///
/// The score panel can fail in a way that looks like an empty panel and nothing
/// else: Verovio refuses the data, the page shows a blank sheet, and no error
/// reaches Swift. This drives the same page the panel uses, off screen, and
/// waits for it to say how many notes it laid out — which is the difference
/// between "the format is supported" as a belief and as a fact.
@MainActor
final class ScoreRenderProbe: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var contents: String
    private var ready = false
    private var finished: CheckedContinuation<String, Never>?
    private var reported = false

    private init(contents: String) {
        self.contents = contents
    }

    static func render(_ contents: String, humdrum: Bool) async -> String {
        let probe = ScoreRenderProbe(contents: contents)
        probe.humdrum = humdrum
        return await probe.run()
    }

    private var humdrum = false

    private func run() async -> String {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "score")
        config.userContentController = controller
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700),
                                configuration: config)
        webView.loadHTMLString(ScoreView.page(humdrum: humdrum), baseURL: URL(string: "https://verovio.org"))
        self.webView = webView

        // Verovio is fetched from a CDN and compiled from WebAssembly; on a
        // cold start that is not instant.
        Task {
            try? await Task.sleep(for: .seconds(40))
            self.report("tempo esgotado (o renderizador não respondeu)")
        }

        return await withCheckedContinuation { continuation in
            finished = continuation
        }
    }

    private func report(_ text: String) {
        guard !reported else { return }
        reported = true
        finished?.resume(returning: text)
        finished = nil
        webView = nil
    }

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        let text = "\(message.body)"
        MainActor.assumeIsolated {
            if text == "toolkit pronto", !ready {
                ready = true
                let encoded = Data(contents.utf8).base64EncodedString()
                webView?.evaluateJavaScript("window.cadenzaLoad('\(encoded)', 40)",
                                            completionHandler: nil)
                // Ask the page what it produced, once it has had a moment.
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    self.measure()
                }
            } else if text.hasPrefix("loadData recusou") {
                report(text)
            }
        }
    }

    private func measure() {
        let script = """
        (function () {
          var notes = document.querySelectorAll('g.note').length;
          var lyrics = document.querySelectorAll('g.syl, g.verse').length;
          var pages = document.querySelectorAll('svg').length;
          return notes + '|' + lyrics + '|' + pages;
        })()
        """
        webView?.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let text = value as? String else {
                    self.report("não consegui medir a página"
                                + (error.map { ": \($0.localizedDescription)" } ?? ""))
                    return
                }
                let parts = text.split(separator: "|").map(String.init)
                let notes = Int(parts.first ?? "0") ?? 0
                let lyrics = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                let pages = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                self.report(notes > 0
                    ? "\(notes) notas, \(lyrics) sílabas de letra, \(pages) página(s)"
                    : "a página ficou vazia")
            }
        }
    }
}
