import SwiftUI
import WebKit

/// Renders an engraved score and follows the music through it.
///
/// Verovio turns MusicXML into SVG and, crucially, hands back a timemap: every
/// note with its onset in the score's own milliseconds. Scaling that map to the
/// track's real duration is what makes following possible without ever touching
/// the audio — which FairPlay would never allow anyway.
///
/// The follow is honest about its limits. It assumes the performance keeps the
/// score's proportions, which holds for steady tempo and drifts under rubato,
/// so the position can be nudged by hand.
struct ScoreView: NSViewRepresentable {
    let musicXML: String
    let position: TimeInterval
    let duration: TimeInterval
    /// Manual correction, in seconds, for performances that stray from the
    /// score's own proportions.
    let offset: TimeInterval

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://verovio.org"))
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedXML != musicXML {
            coordinator.loadedXML = musicXML
            let encoded = Data(musicXML.utf8).base64EncodedString()
            webView.evaluateJavaScript("window.cadenzaLoad('\(encoded)')", completionHandler: nil)
        }

        guard duration > 0 else { return }
        let elapsed = max(0, position + offset)
        webView.evaluateJavaScript(
            "window.cadenzaSeek(\(elapsed), \(duration))", completionHandler: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var webView: WKWebView?
        var loadedXML: String?
    }

    /// Verovio ships as WebAssembly; the page loads it from the project's own
    /// CDN and exposes two entry points to Swift.
    static let page = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html,body { margin:0; padding:0; background:transparent; }
      #score { padding:14px 10px 30px; }
      svg { width:100%; height:auto; }
      /* The engraving is black ink; invert it for a dark interface. */
      @media (prefers-color-scheme: dark) { #score { filter: invert(0.92) hue-rotate(180deg); } }
      .cadenza-now { fill:#d43f4f !important; stroke:#d43f4f !important; }
    </style>
    <script src="https://www.verovio.org/javascript/latest/verovio-toolkit-wasm.js" defer></script>
    </head><body><div id="score">Carregando gravura…</div>
    <script>
    let toolkit = null, timemap = [], scoreEnd = 0, highlighted = null;

    document.addEventListener('DOMContentLoaded', () => {
      verovio.module.onRuntimeInitialized = () => {
        toolkit = new verovio.toolkit();
        toolkit.setOptions({
          scale: 38, adjustPageHeight: true, breaks: 'encoded',
          pageWidth: 2100, footer: 'none', header: 'none'
        });
        if (window.pendingScore) window.cadenzaLoad(window.pendingScore);
      };
    });

    window.cadenzaLoad = function (base64) {
      if (!toolkit) { window.pendingScore = base64; return; }
      const xml = decodeURIComponent(escape(atob(base64)));
      toolkit.loadData(xml);

      let svg = '';
      for (let page = 1; page <= toolkit.getPageCount(); page++) {
        svg += toolkit.renderToSVG(page, {});
      }
      document.getElementById('score').innerHTML = svg;

      // Note onsets in the score's own time, which is what gets rescaled.
      timemap = JSON.parse(toolkit.renderToTimemap({ includeMeasures: true }));
      scoreEnd = timemap.length ? timemap[timemap.length - 1].tstamp : 0;
    };

    window.cadenzaSeek = function (elapsed, duration) {
      if (!timemap.length || !scoreEnd || !duration) return;

      // The score's timeline is stretched onto the recording's.
      const target = (elapsed / duration) * scoreEnd;

      let current = null;
      for (const entry of timemap) {
        if (entry.tstamp > target) break;
        if (entry.on && entry.on.length) current = entry;
      }
      if (!current || current === highlighted) return;
      highlighted = current;

      document.querySelectorAll('.cadenza-now').forEach(n => n.classList.remove('cadenza-now'));
      let first = null;
      for (const id of current.on) {
        const el = document.getElementById(id);
        if (el) { el.classList.add('cadenza-now'); first = first || el; }
      }
      if (first) first.scrollIntoView({ behavior: 'smooth', block: 'center' });
    };
    </script></body></html>
    """#
}
