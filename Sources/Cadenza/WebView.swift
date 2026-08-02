import SwiftUI
import WebKit

// MARK: - Probe state

/// Records what the page actually does, so we can tell a real FairPlay session
/// apart from a silent DRM failure that only shows up as "nothing plays".
@Observable
final class DRMProbe {
    struct Entry: Identifiable {
        let id = UUID()
        let text: String
        let good: Bool?
    }

    var entries: [Entry] = []
    var verdict: String = "aguardando…"

    @MainActor
    func record(_ text: String, good: Bool? = nil) {
        entries.append(Entry(text: text, good: good))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }
}

// MARK: - Web view

struct ClassicalWebView: NSViewRepresentable {
    let probe: DRMProbe

    // Brazilian storefront — the web player is storefront-scoped.
    static let home = URL(string: "https://classical.music.apple.com/br")!

    func makeCoordinator() -> Coordinator { Coordinator(probe: probe) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Persistent store so the Apple ID login survives relaunches.
        config.websiteDataStore = .default()

        // The player starts audio programmatically; without this WebKit blocks it.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "cadenza")
        controller.addUserScript(
            WKUserScript(source: Self.probeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        controller.addUserScript(
            WKUserScript(source: Self.harvestScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        // Apple's player gates features on the UA; present as desktop Safari.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

        webView.load(URLRequest(url: Self.home))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let probe: DRMProbe
        init(probe: DRMProbe) { self.probe = probe }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let type = body["type"] as? String ?? "?"
            let detail = body["detail"] as? String

            Task { @MainActor in
                switch type {
                case "boot":
                    probe.record("página carregada: \(body["url"] as? String ?? "?")")

                case "eme":
                    let stage = body["stage"] as? String ?? "?"
                    let ks = body["keySystem"] as? String ?? "?"
                    switch stage {
                    case "missing":
                        probe.record("EME indisponível no WKWebView", good: false)
                        probe.verdict = "❌ sem EME — DRM impossível"
                    case "request":
                        probe.record("EME solicitado: \(ks)")
                    case "access-ok":
                        probe.record("EME acesso concedido: \(ks)", good: true)
                        if ks.contains("fps") {
                            probe.verdict = "✅ FairPlay disponível — faça login e toque uma faixa"
                        }
                    case "mediakeys-ok":
                        probe.record("MediaKeys criado: \(ks)", good: true)
                    case "license-request":
                        probe.record("licença requisitada ao servidor: \(ks)", good: true)
                    case "key-status":
                        let ok = (detail ?? "").contains("usable")
                        probe.record("status da chave: \(detail ?? "?")", good: ok)
                        probe.verdict = ok
                            ? "✅ FairPlay funciona — faixa completa liberada"
                            : "⚠️ chave não utilizável: \(detail ?? "?")"
                    case "access-fail", "mediakeys-fail":
                        // Only FairPlay matters. The player probes Widevine/PlayReady too;
                        // WebKit has never implemented those, so their failure is expected
                        // and says nothing about whether playback works.
                        if ks.contains("fps") {
                            probe.record("falha EME (\(stage)) \(ks): \(detail ?? "?")", good: false)
                            probe.verdict = "❌ FairPlay bloqueado no WKWebView"
                        } else {
                            probe.record("\(ks) indisponível (esperado no WebKit)")
                        }
                    default:
                        probe.record("eme/\(stage) \(ks) \(detail ?? "")")
                    }

                case "media":
                    let event = body["event"] as? String ?? "?"
                    let err = body["err"] as? String
                    if event == "playing" {
                        probe.record("áudio tocando (\(body["tag"] as? String ?? "?"))", good: true)
                    } else if event == "error" {
                        probe.record("erro de mídia: \(err ?? "?")", good: false)
                    } else if event == "encrypted" {
                        probe.record("stream criptografado detectado")
                    }

                case "tokens":
                    var payload = body
                    payload.removeValue(forKey: "type")
                    TokenStore.shared.merge(payload)
                    let sources = (body["sources"] as? [String] ?? []).joined(separator: ", ")
                    let hasUser = (body["musicUserToken"] as? String)?.isEmpty == false
                    probe.record("tokens obtidos [\(sources)] user-token=\(hasUser ? "sim" : "não")",
                                 good: hasUser)

                case "stream":
                    let url = body["url"] as? String ?? ""
                    StreamLog.shared.append(url)
                    probe.record("stream: \(URL(string: url)?.lastPathComponent ?? "?")")

                case "net":
                    let method = body["method"] as? String ?? "GET"
                    let url = body["url"] as? String ?? ""
                    CaptureLog.shared.append("\(method) \(url)")
                    probe.record("api: \(method) \(Self.shortPath(url))")

                case "musickit":
                    let sf = body["storefront"] as? String ?? "?"
                    let authed = body["authorized"] as? Bool ?? false
                    probe.record("MusicKit v\(body["version"] as? String ?? "?") "
                        + "storefront=\(sf) autenticado=\(authed ? "sim" : "não")", good: authed)

                default:
                    break
                }
            }
        }

        /// Trims a recorded URL down to the part that identifies the endpoint.
        static func shortPath(_ url: String) -> String {
            guard let comps = URLComponents(string: url), let path = comps.path.isEmpty ? nil : comps.path
            else { return String(url.prefix(70)) }
            return path
        }

        /// The Music-User-Token lives in an HttpOnly cookie, so the injected
        /// script can never see it. Native code can.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var found: [String: Any] = [:]
                for cookie in cookies {
                    switch cookie.name {
                    case "media-user-token":
                        found["musicUserToken"] = cookie.value
                    case "itua":
                        found["storefront"] = cookie.value.lowercased()
                    default:
                        break
                    }
                }
                guard !found.isEmpty else { return }
                TokenStore.shared.merge(found)

                Task { @MainActor in
                    if found["musicUserToken"] != nil {
                        self.probe.record("media-user-token obtido do cookie store", good: true)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in probe.record("navegação falhou: \(error.localizedDescription)", good: false) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in probe.record("carga falhou: \(error.localizedDescription)", good: false) }
        }
    }
}

// MARK: - Injected probe

extension ClassicalWebView {
    static let probeScript = #"""
    (function () {
      if (window.__cadenzaProbe) return;
      window.__cadenzaProbe = true;
      var send = function (m) {
        try { window.webkit.messageHandlers.cadenza.postMessage(m); } catch (e) {}
      };

      send({ type: 'boot', url: location.href });

      var orig = navigator.requestMediaKeySystemAccess
        ? navigator.requestMediaKeySystemAccess.bind(navigator) : null;

      if (!orig) {
        send({ type: 'eme', stage: 'missing' });
      } else {
        navigator.requestMediaKeySystemAccess = function (keySystem, configs) {
          send({ type: 'eme', stage: 'request', keySystem: keySystem });
          return orig(keySystem, configs).then(function (access) {
            send({ type: 'eme', stage: 'access-ok', keySystem: keySystem });
            var cm = access.createMediaKeys.bind(access);
            access.createMediaKeys = function () {
              return cm().then(function (keys) {
                send({ type: 'eme', stage: 'mediakeys-ok', keySystem: keySystem });
                var cs = keys.createSession.bind(keys);
                keys.createSession = function () {
                  var s = cs.apply(keys, arguments);
                  s.addEventListener('message', function () {
                    send({ type: 'eme', stage: 'license-request', keySystem: keySystem });
                  });
                  s.addEventListener('keystatuseschange', function () {
                    var st = [];
                    s.keyStatuses.forEach(function (v) { st.push(v); });
                    send({ type: 'eme', stage: 'key-status', keySystem: keySystem, detail: st.join(',') });
                  });
                  return s;
                };
                return keys;
              }).catch(function (e) {
                send({ type: 'eme', stage: 'mediakeys-fail', keySystem: keySystem, detail: String(e) });
                throw e;
              });
            };
            return access;
          }).catch(function (e) {
            send({ type: 'eme', stage: 'access-fail', keySystem: keySystem, detail: String(e) });
            throw e;
          });
        };
      }

      // --- API surface recorder -------------------------------------------
      // The classical catalog has no public API. Record every call the official
      // player makes so we can drive the same endpoints from our own UI.
      var interesting = function (u) {
        return /amp-api|api\.music\.apple\.com|classical\.music\.apple\.com\/api/.test(u);
      };

      // Playlists/manifests only — segments would flood the log and tell us
      // nothing the manifest doesn't already state in its CODECS attribute.
      var isManifest = function (u) {
        return /\.m3u8|aod[\w-]*\.itunes\.apple\.com|audio-ssl\.itunes/.test(u);
      };

      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          try {
            var u = typeof input === 'string' ? input : (input && input.url) || '';
            if (interesting(u)) {
              send({ type: 'net', method: (init && init.method) || 'GET', url: u });
            }
          } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }

      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { if (interesting(url)) send({ type: 'net', method: method, url: url }); } catch (e) {}
        return origOpen.apply(this, arguments);
      };

      // Catch-all: resource timing sees every request the document makes,
      // including ones issued by service workers or the commerce fetch-proxy
      // iframe, which page-level fetch/XHR wrappers never observe.
      try {
        var report = function (entries) {
          entries.forEach(function (e) {
            if (interesting(e.name)) send({ type: 'net', method: 'RES', url: e.name });
            else if (isManifest(e.name)) send({ type: 'stream', url: e.name });
          });
        };
        report(performance.getEntriesByType('resource'));
        new PerformanceObserver(function (list) { report(list.getEntries()); })
          .observe({ entryTypes: ['resource'] });
      } catch (e) {
        send({ type: 'net', method: 'ERR', url: 'PerformanceObserver: ' + String(e) });
      }

      // Surface the developer token + MusicKit instance once the page boots it.
      var seenToken = false;
      setInterval(function () {
        try {
          if (seenToken || !window.MusicKit) return;
          var mk = window.MusicKit.getInstance && window.MusicKit.getInstance();
          if (!mk) return;
          seenToken = true;
          send({
            type: 'musickit',
            version: window.MusicKit.version || '?',
            storefront: mk.storefrontId || '?',
            authorized: !!mk.isAuthorized,
            token: (mk.developerToken || '').slice(0, 24) + '…'
          });
        } catch (e) {}
      }, 1500);

      var watch = function (el) {
        if (el.__cadenzaWatched) return;
        el.__cadenzaWatched = true;
        ['playing', 'error', 'encrypted'].forEach(function (ev) {
          el.addEventListener(ev, function () {
            send({
              type: 'media', event: ev, tag: el.tagName,
              err: el.error ? (el.error.code + ':' + el.error.message) : null
            });
          });
        });
      };
      var scan = function () { document.querySelectorAll('audio,video').forEach(watch); };
      new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
      scan();
      setInterval(scan, 2000);
    })();
    """#
}

// MARK: - Verdict bar

struct DRMProbeBar: View {
    let probe: DRMProbe
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(probe.entries.reversed()) { entry in
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(entry.good == true ? .green
                                    : entry.good == false ? .red : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 180)
            }

            HStack {
                Text("DRM: \(probe.verdict)").font(.callout.weight(.medium))
                Spacer()
                Button(expanded ? "ocultar log" : "ver log") { expanded.toggle() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }
}
