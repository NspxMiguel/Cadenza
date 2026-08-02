import Foundation

/// The v10 endpoints need the same credentials the web player uses: Apple's
/// developer token (a JWT the page ships with) and the user's Music-User-Token.
/// Both live in the page; this stores whatever the harvester finds so the native
/// data layer can call the API directly instead of scraping the DOM.
///
/// These are the user's own credentials on the user's own machine — written
/// locally, never transmitted anywhere.
final class TokenStore: @unchecked Sendable {
    static let shared = TokenStore()

    private let url: URL
    private init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Claude/Cadenza/capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("tokens.json")
    }

    private let queue = DispatchQueue(label: "cadenza.tokens")
    private var current: [String: Any] = [:]

    /// Merges, because the two credentials arrive from different places: the
    /// developer token from the page, the user token from an HttpOnly cookie.
    func merge(_ payload: [String: Any]) {
        queue.async { [self] in
            for (k, v) in payload { current[k] = v }
            guard JSONSerialization.isValidJSONObject(current),
                  let data = try? JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted])
            else { return }
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    var hasUserToken: Bool { queue.sync { credentials != nil } }

    /// Reads back what was harvested, falling back to disk so a fresh launch
    /// can hit the API before the web view has finished booting.
    var credentials: Credentials? {
        queue.sync {
            if current.isEmpty, let data = try? Data(contentsOf: url),
               let disk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                current = disk
            }
            guard let dev = current["developerToken"] as? String,
                  let user = current["musicUserToken"] as? String
            else { return nil }
            return Credentials(
                developerToken: dev,
                musicUserToken: user,
                storefront: current["storefront"] as? String ?? "us")
        }
    }

    struct Credentials: Sendable {
        let developerToken: String
        let musicUserToken: String
        let storefront: String
    }
}

extension ClassicalWebView {
    /// Runs in the page: hunts for the developer token and music-user-token
    /// wherever the player happens to keep them.
    static let harvestScript = #"""
    (function () {
      if (window.__cadenzaHarvest) return;
      window.__cadenzaHarvest = true;
      var send = function (m) {
        try { window.webkit.messageHandlers.cadenza.postMessage(m); } catch (e) {}
      };

      var isJWT = function (v) {
        return typeof v === 'string' && /^eyJ[A-Za-z0-9_-]{10,}\./.test(v);
      };

      var harvest = function () {
        var out = { type: 'tokens', sources: [] };

        // 1. The MusicKit instance, if the player exposes one.
        try {
          var mk = window.MusicKit && window.MusicKit.getInstance && window.MusicKit.getInstance();
          if (mk) {
            if (isJWT(mk.developerToken)) { out.developerToken = mk.developerToken; out.sources.push('musickit.developerToken'); }
            if (mk.musicUserToken) { out.musicUserToken = mk.musicUserToken; out.sources.push('musickit.musicUserToken'); }
            if (mk.storefrontId) out.storefront = mk.storefrontId;
          }
        } catch (e) {}

        // 2. Storage — the player caches both across reloads.
        try {
          for (var i = 0; i < localStorage.length; i++) {
            var k = localStorage.key(i);
            var v = localStorage.getItem(k);
            if (isJWT(v) && !out.developerToken) { out.developerToken = v; out.sources.push('localStorage:' + k); }
            if (/music.?user.?token/i.test(k) && v && !out.musicUserToken) {
              out.musicUserToken = v; out.sources.push('localStorage:' + k);
            }
          }
        } catch (e) {}

        // 3. The devToken is also passed on the commerce iframe's query string.
        try {
          if (!out.developerToken) {
            var frames = document.querySelectorAll('iframe');
            for (var j = 0; j < frames.length; j++) {
              var m = /devToken=([^&]+)/.exec(frames[j].src || '');
              if (m) { out.developerToken = decodeURIComponent(m[1]); out.sources.push('iframe.devToken'); break; }
            }
          }
          var mm = /devToken=([^&]+)/.exec(location.search);
          if (mm && !out.developerToken) {
            out.developerToken = decodeURIComponent(mm[1]); out.sources.push('location.devToken');
          }
        } catch (e) {}

        if (out.developerToken || out.musicUserToken) {
          send(out);
          return true;
        }
        return false;
      };

      var tries = 0;
      var timer = setInterval(function () {
        if (harvest() || ++tries > 40) clearInterval(timer);
      }, 1500);
    })();
    """#
}
