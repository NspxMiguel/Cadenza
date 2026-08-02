import AppKit
import SwiftUI
import Observation
import WebKit

/// Playback engine backed by WebKit.
///
/// FairPlay decryption cannot leave WebKit, so the audio has to originate
/// there. Rather than configure MusicKit ourselves — which would mean
/// reproducing Apple's token exchange and CORS setup — this hosts Apple's own
/// player in an offscreen window and drives the MusicKit instance it already
/// authorised. Nothing of that page is ever shown.
///
/// The web view must live inside the app's real, visible window. WebKit
/// suspends media in windows it considers occluded, and an offscreen or
/// zero-alpha host window counts as occluded: MusicKit reports `isPlaying`,
/// the queue loads, and playback time never advances. `EngineHost` parks it in
/// the view tree at one pixel instead.
///
/// This is the engine the `Player` protocol exists to make replaceable: it is
/// capped at lossy AAC, and a native MusicKit engine would not be.
@MainActor
@Observable
final class WebKitEngine: NSObject, Player {
    static let shared = WebKitEngine()

    // MARK: Player

    private(set) var status: PlaybackStatus = .idle
    private(set) var nowPlaying: NowPlaying?
    private(set) var position: TimeInterval = 0
    let ceiling: AudioCeiling = .lossyAAC

    /// Whether the hosted page has reached the point of exposing a usable
    /// MusicKit instance. Commands issued before this are queued.
    private(set) var isReady = false

    private(set) var webView: WKWebView?
    private var pending: [String] = []
    private var statesLogged = 0

    // MARK: Lifecycle

    /// Boots the offscreen page. Safe to call more than once.
    func start() {
        guard webView == nil else { return }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        let controller = WKUserContentController()
        controller.add(self, name: "engine")
        // Verifying playback should not mean filling the room with sound.
        // CADENZA_SILENT=1 keeps the engine muted while still exercising it.
        if ProcessInfo.processInfo.environment["CADENZA_SILENT"] == "1" {
            controller.addUserScript(WKUserScript(
                source: "window.__cadenzaSilent = true;",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            log("modo silencioso — volume forçado a zero")
        }
        controller.addUserScript(
            WKUserScript(source: Self.bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        self.webView = webView

        let storefront = TokenStore.shared.credentials?.storefront ?? "us"
        webView.load(URLRequest(url: URL(string: "https://classical.music.apple.com/\(storefront)")!))
        log("motor iniciando (storefront \(storefront))")
    }

    // MARK: Commands

    func play(trackID: String) async throws {
        try await play(id: trackID, kind: "songs")
    }

    /// `kind` mirrors the catalog's `payload.type` — `songs`, `albums`,
    /// `playlists` — which is what MusicKit's queue descriptor expects.
    func play(id: String, kind: String) async throws {
        log("play pedido: id=\(id) kind=\(kind) pronto=\(isReady)")
        status = .loading
        run("window.__cadenzaPlay(\(quote(id)), \(quote(kind)))")
    }

    func togglePlayPause() {
        run("window.__cadenzaToggle()")
    }

    func seek(to position: TimeInterval) {
        run("window.__cadenzaSeek(\(position))")
    }

    func skipForward() { run("window.__cadenzaSkip(1)") }
    func skipBackward() { run("window.__cadenzaSkip(-1)") }

    func stop() {
        run("window.__cadenzaStop()")
        status = .idle
        nowPlaying = nil
        position = 0
    }

    // MARK: Plumbing

    private func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func run(_ script: String) {
        guard isReady, let webView else {
            pending.append(script)
            return
        }
        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error { self?.log("comando falhou: \(error.localizedDescription)") }
        }
    }

    private func drainPending() {
        let queued = pending
        pending.removeAll()
        for script in queued { run(script) }
    }

    nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("[engine] \(message)\n".utf8))
    }
}

// MARK: - Bridge messages

extension WebKitEngine: WKScriptMessageHandler {
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        let kind = body["kind"] as? String ?? "?"

        MainActor.assumeIsolated {
            switch kind {
            case "ready":
                isReady = true
                log("MusicKit pronto — autorizado=\(body["authorized"] as? Bool ?? false)")
                drainPending()

            case "trace":
                log("· \(body["step"] as? String ?? "?") — \(body["detail"] as? String ?? "")")

            case "diagnostic":
                log("diagnóstico: MusicKit=\(body["musicKit"] as? String ?? "?") "
                    + "getInstance=\(body["getInstance"] as? Bool ?? false) "
                    + "globais=[\(body["globals"] as? String ?? "")]")

            case "state":
                if statesLogged < 3 {
                    statesLogged += 1
                    log("estado: tocando=\(body["playing"] as? Bool ?? false) "
                        + "pos=\(Int(body["position"] as? Double ?? 0))s "
                        + "título=\(body["title"] as? String ?? "<vazio>")")
                }
                let playing = body["playing"] as? Bool ?? false
                let loading = body["loading"] as? Bool ?? false
                status = loading ? .loading : (playing ? .playing : .paused)
                position = body["position"] as? Double ?? 0
                if let title = body["title"] as? String, !title.isEmpty {
                    nowPlaying = NowPlaying(
                        trackID: body["trackID"] as? String ?? "",
                        title: title,
                        artist: body["artist"] as? String ?? "",
                        artworkURL: (body["artwork"] as? String).flatMap(URL.init(string:)),
                        duration: body["duration"] as? Double ?? 0)
                }

            case "error":
                log("erro: \(body["message"] as? String ?? "?")")
                status = .paused

            default:
                break
            }
        }
    }
}

// MARK: - Injected bridge

extension WebKitEngine {
    static let bridge = #"""
    (function () {
      if (window.__cadenzaEngine) return;
      window.__cadenzaEngine = true;

      var send = function (m) {
        try { window.webkit.messageHandlers.engine.postMessage(m); } catch (e) {}
      };

      var instance = function () {
        try {
          return window.MusicKit && window.MusicKit.getInstance
            ? window.MusicKit.getInstance() : null;
        } catch (e) { return null; }
      };

      // Report what the page exposes, so the Swift side is not guessing about
      // whether MusicKit is reachable from this frame.
      var reported = false;
      var diagnose = function () {
        if (reported) return;
        reported = true;
        var globals = [];
        try {
          for (var k in window) { if (/musickit/i.test(k)) globals.push(k); }
        } catch (e) {}
        send({
          kind: 'diagnostic',
          musicKit: typeof window.MusicKit,
          getInstance: !!(window.MusicKit && window.MusicKit.getInstance),
          globals: globals.slice(0, 10).join(',')
        });
      };
      setTimeout(diagnose, 8000);

      var mk = null;
      var waitForReady = setInterval(function () {
        var candidate = instance();
        if (!candidate) return;
        clearInterval(waitForReady);
        mk = candidate;
        diagnose();
        send({ kind: 'ready', authorized: !!mk.isAuthorized });
        if (window.__cadenzaSilent) {
          try { mk.volume = 0; } catch (e) {}
        }

        var report = function () {
          try {
            var item = mk.nowPlayingItem;
            send({
              kind: 'state',
              playing: !!mk.isPlaying,
              loading: mk.playbackState === 1,
              position: mk.currentPlaybackTime || 0,
              duration: mk.currentPlaybackDuration || 0,
              trackID: item ? String(item.id || '') : '',
              title: item ? (item.title || item.attributes && item.attributes.name || '') : '',
              artist: item ? (item.artistName ||
                (item.attributes && item.attributes.artistName) || '') : '',
              artwork: item && item.artworkURL ? item.artworkURL : ''
            });
          } catch (e) {}
        };
        setInterval(report, 1000);
        report();
      }, 500);

      var fail = function (e) { send({ kind: 'error', message: String(e) }); };

      // MusicKit's queue descriptor keys are singular: song, album, playlist.
      var descriptorKey = function (kind) {
        return { songs: 'song', albums: 'album', playlists: 'playlist' }[kind] || 'song';
      };

      window.__cadenzaPlay = function (id, kind) {
        if (!mk) return fail('MusicKit indisponível');
        var q = {};
        q[descriptorKey(kind)] = id;
        send({ kind: 'trace', step: 'setQueue', detail: JSON.stringify(q) });
        try {
          Promise.resolve(mk.setQueue(q))
            .then(function () {
              send({
                kind: 'trace', step: 'fila pronta',
                detail: 'itens=' + ((mk.queue && mk.queue.length) || 0) +
                        ' estado=' + mk.playbackState
              });
              return mk.play();
            })
            .then(function () {
              send({
                kind: 'trace', step: 'play resolvido',
                detail: 'tocando=' + !!mk.isPlaying + ' estado=' + mk.playbackState +
                        ' item=' + (mk.nowPlayingItem ? 'sim' : 'não')
              });
            })
            .catch(function (e) { fail('promessa: ' + (e && e.message ? e.message : e)); });
        } catch (e) {
          fail('exceção síncrona: ' + (e && e.message ? e.message : e));
        }
      };

      window.__cadenzaToggle = function () {
        if (!mk) return fail('MusicKit indisponível');
        (mk.isPlaying ? mk.pause() : mk.play());
      };

      window.__cadenzaSeek = function (seconds) {
        if (mk) { try { mk.seekToTime(seconds); } catch (e) { fail(e); } }
      };

      window.__cadenzaSkip = function (direction) {
        if (!mk) return;
        try { direction > 0 ? mk.skipToNextItem() : mk.skipToPreviousItem(); } catch (e) { fail(e); }
      };

      window.__cadenzaStop = function () {
        if (mk) { try { mk.stop(); } catch (e) {} }
      };
    })();
    """#
}


// MARK: - Host view

/// Keeps the engine's web view in the visible window so WebKit does not
/// suspend its media. One pixel is enough; it is never seen.
struct EngineHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        WebKitEngine.shared.start()
        if let webView = WebKitEngine.shared.webView {
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
