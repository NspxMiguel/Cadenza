import SwiftUI
import WebKit

/// Renders an engraved score and follows the music through it.
///
/// Verovio turns MusicXML — or Humdrum `**kern`, which it reads natively — into
/// SVG and, crucially, hands back a timemap: every note with its onset in the
/// score's own milliseconds. Scaling that map to the track's real duration is
/// what makes following possible without ever touching the audio, which
/// FairPlay would never allow anyway.
///
/// The follow is honest about its limits. It assumes the performance keeps the
/// score's proportions, which holds for steady tempo and drifts under rubato,
/// so the position can be nudged by hand and pinned by clicking a note.
struct ScoreView: NSViewRepresentable {
    let musicXML: String
    let position: TimeInterval
    let duration: TimeInterval
    /// Manual correction, in seconds, for performances that stray from the
    /// score's own proportions.
    let offset: TimeInterval
    /// Which Verovio build to load.
    ///
    /// The default toolkit is compiled without the Humdrum importer — it
    /// answers `loadData` with a plain refusal and no explanation, which reads
    /// exactly like a corrupt file. The Humdrum-capable build exists but is
    /// four megabytes larger and compiles more slowly, so it is loaded only
    /// when there is `**kern` to read.
    var humdrum: Bool = false
    /// Staff size, as a percentage the way Verovio counts it.
    var zoom: Int = 40
    /// Whether the page should scroll itself to keep up with the music.
    var following: Bool = true
    /// Records a calibration point when a note is clicked.
    var onAnchor: ((Double) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "score")
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.page(humdrum: humdrum),
                               baseURL: URL(string: "https://verovio.org"))
        context.coordinator.loadedHumdrum = humdrum
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        // A different renderer is a different page: there is no way to swap
        // the importer in a toolkit that was compiled without it.
        if coordinator.loadedHumdrum != humdrum {
            coordinator.loadedHumdrum = humdrum
            coordinator.toolkitReady = false
            coordinator.loadedXML = nil
            coordinator.pendingXML = musicXML
            webView.loadHTMLString(Self.page(humdrum: humdrum),
                                   baseURL: URL(string: "https://verovio.org"))
            return
        }

        // Held rather than sent immediately: evaluating cadenzaLoad before the
        // page has defined it fails silently, and marking the score as loaded
        // at that point means it is never sent again. The page signals when it
        // is ready.
        if coordinator.pendingXML != musicXML && coordinator.loadedXML != musicXML {
            coordinator.pendingXML = musicXML
            coordinator.flushIfReady()
        }

        if coordinator.zoom != zoom {
            coordinator.zoom = zoom
            webView.evaluateJavaScript("window.cadenzaZoom(\(zoom))", completionHandler: nil)
        }
        if coordinator.following != following {
            coordinator.following = following
            webView.evaluateJavaScript("window.cadenzaFollow(\(following))",
                                       completionHandler: nil)
        }

        guard duration > 0 else { return }
        let elapsed = max(0, position + offset)

        // SwiftUI redraws far more often than once a second, and each redraw
        // was crossing into JavaScript to move a highlight that had not moved.
        guard abs(elapsed - coordinator.lastSeek) >= 0.25 else { return }
        coordinator.lastSeek = elapsed
        coordinator.onAnchor = onAnchor

        // The mapping from recording to score lives in Swift, where the
        // calibration points are kept; the page is simply told where to be.
        let scorePosition = ScoreAnchors.shared.scorePosition(
            forReal: elapsed, duration: duration, scoreEnd: coordinator.scoreEnd)
        webView.evaluateJavaScript(
            "window.cadenzaShow(\(scorePosition))", completionHandler: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var webView: WKWebView?
        var loadedXML: String?
        var pendingXML: String?
        var toolkitReady = false
        var lastSeek: TimeInterval = -1
        var scoreEnd: Double = 0
        var zoom = 40
        var following = true
        var loadedHumdrum = false
        var onAnchor: ((Double) -> Void)?

        /// Written to a file rather than stderr: the app is normally started
        /// with `open`, which discards standard error, so anything logged there
        /// is invisible exactly when it is needed.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let text = "\(message.body)"
            Diagnostics.log("[score] \(text)")
            if text == "toolkit pronto" {
                toolkitReady = true
                flushIfReady()
            } else if text.hasPrefix("fim:") {
                scoreEnd = Double(text.dropFirst(4)) ?? 0
            } else if text.hasPrefix("ancora:") {
                if let stamp = Double(text.dropFirst(7)) { onAnchor?(stamp) }
            }
        }

        /// The score is held until the page reports the renderer is up.
        /// Evaluating `cadenzaLoad` before the page defines it fails silently,
        /// and treating the score as delivered at that point means it is never
        /// sent again — the panel then waits forever on a renderer that is in
        /// fact ready.
        func flushIfReady() {
            guard toolkitReady, let xml = pendingXML, let webView else { return }
            let encoded = Data(xml.utf8).base64EncodedString()
            webView.evaluateJavaScript(
                "window.cadenzaLoad('\(encoded)', \(zoom))") { [weak self] _, error in
                if let error {
                    Diagnostics.log("[score] cadenzaLoad falhou: \(error.localizedDescription)")
                } else {
                    self?.loadedXML = xml
                    self?.pendingXML = nil
                }
            }
        }
    }

    /// Verovio ships as WebAssembly; the page loads it from the project's own
    /// CDN and exposes the entry points Swift drives it with.
    ///
    /// The engraving is drawn on white paper regardless of the interface theme.
    /// Inverting it for dark mode was the earlier approach and it is wrong for
    /// this specific thing: printed music is black on white everywhere it
    /// exists, an inverted stave reads as a photographic negative, and the
    /// inversion also fought with the highlight colour.
    static func page(humdrum: Bool) -> String {
        let script = humdrum
            ? "https://www.verovio.org/javascript/latest/verovio-toolkit-hum.js"
            : "https://www.verovio.org/javascript/latest/verovio-toolkit-wasm.js"
        return template.replacingOccurrences(of: "__SCRIPT__", with: script)
    }

    private static let template = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      html,body { margin:0; padding:0; background:transparent; }
      #paper {
        background:#fffdf8; color:#111;
        margin:12px; padding:18px 12px 34px;
        border-radius:6px; box-shadow:0 2px 14px rgba(0,0,0,.28);
        min-height: calc(100vh - 60px);
      }
      #status { font:13px -apple-system, system-ui; color:#666; padding:24px; }
      svg { width:100%; height:auto; display:block; }
      /* The sounding notes. Stroke as well as fill: stems and beams are
         stroked, noteheads are filled, and colouring only one leaves the
         highlight looking half-applied. */
      .cadenza-now, .cadenza-now * { fill:#c0392b !important; stroke:#c0392b !important; }
      /* The measure being played, tinted behind the notes so the eye can find
         its place on a dense page without hunting for one red notehead. */
      .cadenza-bar { fill:rgba(255,214,102,.36); }
    </style>
    <script>
      window.onerror = function (m, src) {
        try { window.webkit.messageHandlers.score.postMessage('erro js: ' + m + ' @ ' + src); } catch (e) {}
      };
    </script>
    <script src="__SCRIPT__"
            onerror="try{window.webkit.messageHandlers.score.postMessage('script do verovio FALHOU ao carregar')}catch(e){}"
            defer></script>
    </head><body>
    <div id="paper"><div id="status">Carregando gravura…</div></div>
    <script>
    let toolkit = null, timemap = [], scoreEnd = 0, highlighted = null;
    let currentZoom = 40, following = true, lastData = null, shade = null;

    function say(m) {
      try { window.webkit.messageHandlers.score.postMessage(m); } catch (e) {}
    }

    function options(zoom) {
      return {
        scale: zoom,
        adjustPageHeight: true,
        // Let Verovio break systems to the width it is given rather than
        // obeying the engraver's original page, which is set for paper of a
        // different size and overflows a panel.
        breaks: 'auto',
        pageWidth: Math.max(1200, Math.round((window.innerWidth - 60) * 100 / zoom)),
        pageMarginLeft: 40, pageMarginRight: 40,
        pageMarginTop: 30, pageMarginBottom: 30,
        footer: 'none', header: 'none',
        // The words under the staff are the point of the art-song corpus, so
        // never let the engraver drop them to save space.
        lyricTopMinMargin: 3, spacingStaff: 10
      };
    }

    // Registering onRuntimeInitialized only works if the WASM runtime has not
    // finished starting yet. With a deferred script it often has, and the
    // callback never fires — the panel then waits forever while the script is
    // demonstrably loaded. Polling the constructor is indifferent to the order.
    (function waitForToolkit(attempt) {
      if (toolkit) return;
      try {
        if (window.verovio && verovio.toolkit) {
          toolkit = new verovio.toolkit();
          toolkit.setOptions(options(currentZoom));
          say('toolkit pronto');
          return;
        }
      } catch (e) { /* runtime not up yet */ }

      if (attempt > 150) {
        say('toolkit nunca ficou pronto');
        document.getElementById('status').textContent =
          'Não foi possível carregar o renderizador de partitura.';
        return;
      }
      setTimeout(function () { waitForToolkit(attempt + 1); }, 200);
    })(0);

    function render() {
      let svg = '';
      for (let page = 1; page <= toolkit.getPageCount(); page++) {
        svg += toolkit.renderToSVG(page, {});
      }
      document.getElementById('paper').innerHTML = svg;

      timemap = JSON.parse(toolkit.renderToTimemap({ includeMeasures: true }));
      scoreEnd = timemap.length ? timemap[timemap.length - 1].tstamp : 0;
      say('fim:' + scoreEnd);

      highlighted = null;
      shade = null;

      // Clicking a note as it sounds is how the listener corrects the
      // alignment, so every note reports its own place in the score.
      document.querySelectorAll('g.note').forEach(function (el) {
        el.style.cursor = 'crosshair';
        el.addEventListener('click', function () {
          var stamp = onsetOf(el.id);
          if (stamp !== null) say('ancora:' + stamp);
        });
      });
    }

    window.cadenzaLoad = function (base64, zoom) {
      currentZoom = zoom || currentZoom;
      if (!toolkit) return;
      lastData = decodeURIComponent(escape(atob(base64)));

      // Auto-detection does not recognise these Humdrum files: they open with
      // `!!!COM:` reference records rather than with the `**kern` line, and
      // Verovio refuses them outright. Naming the format removes the guess.
      var opts = options(currentZoom);
      if (lastData.indexOf('**kern') !== -1) { opts.inputFrom = 'humdrum'; }
      toolkit.setOptions(opts);

      if (!toolkit.loadData(lastData)) {
        document.getElementById('paper').innerHTML =
          '<div id="status">A gravura não pôde ser lida.</div>';
        var why = '';
        try { why = toolkit.getLog(); } catch (e) {}
        say('loadData recusou os dados: ' + String(why).slice(0, 200));
        return;
      }
      render();
    };

    window.cadenzaZoom = function (zoom) {
      if (!toolkit || !lastData) { currentZoom = zoom; return; }
      currentZoom = zoom;
      toolkit.setOptions(options(zoom));
      toolkit.redoLayout();
      render();
    };

    window.cadenzaFollow = function (on) { following = on; };

    function onsetOf(id) {
      for (var i = 0; i < timemap.length; i++) {
        var entry = timemap[i];
        if (entry.on && entry.on.indexOf(id) !== -1) return entry.tstamp;
      }
      return null;
    }

    /// Tints the measure containing an element, so the reader's eye lands on
    /// the right bar before it looks for the right note.
    function shadeMeasure(el) {
      var measure = el.closest('g.measure');
      if (!measure || measure === shade) return;
      shade = measure;
      var old = document.querySelector('rect.cadenza-bar');
      if (old) old.remove();

      var box = measure.getBBox();
      var rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      rect.setAttribute('class', 'cadenza-bar');
      rect.setAttribute('x', box.x - 40);
      rect.setAttribute('y', box.y - 60);
      rect.setAttribute('width', box.width + 80);
      rect.setAttribute('height', box.height + 120);
      rect.setAttribute('rx', 40);
      measure.insertBefore(rect, measure.firstChild);
    }

    window.cadenzaShow = function (target) {
      if (!timemap.length || !scoreEnd) return;

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
      if (!first) return;
      shadeMeasure(first);

      if (!following) return;
      // Scroll only when the music has left the comfortable middle of the
      // view. Centring on every note makes the page twitch continuously and
      // is far harder to read than a page that turns when it needs to.
      const box = first.getBoundingClientRect();
      const height = window.innerHeight;
      if (box.top < height * 0.25 || box.bottom > height * 0.75) {
        first.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }
    };
    </script></body></html>
    """#
}
