import AppKit
import CryptoKit
import Foundation
import Observation

/// Signing in with Google, and keeping the library in Drive.
///
/// There is no client secret here, and that is the point. Google issues two
/// kinds of OAuth client for an app like this: a "desktop" one, which comes
/// with a secret you are told to embed anyway, and a public one — the iOS type,
/// which macOS apps use for exactly this reason — which has no secret at all
/// and is held together by PKCE plus a redirect only this app can receive.
///
/// The first was tried and rejected, by GitHub rather than by argument: push
/// protection refuses to accept a `GOCSPX-` string however well-reasoned the
/// commit message is. It was right to. A public client removes the question
/// instead of arguing it — nothing here is confidential, so nothing can leak.
///
/// `drive.file` means the app can only ever see files it created itself. It
/// cannot read the rest of someone's Drive, which is both the right amount of
/// power and why Google does not demand the heavy verification review that
/// broader scopes do.
enum GoogleCredentials {
    static let clientID =
        "343088507785-tnetv9soj3rk1ickh7utb7hiosrn3eh1.apps.googleusercontent.com"
    static let scope = "https://www.googleapis.com/auth/drive.file"

    /// Google's convention for public clients: the reversed client id is the
    /// URL scheme the browser hands the answer back on. It is registered in the
    /// app's Info.plist, so only this app can receive it.
    static var redirectURI: String {
        let reversed = clientID
            .replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(reversed):/oauth"
    }

    static var urlScheme: String {
        "com.googleusercontent.apps."
            + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
}

// MARK: - Token storage

/// The refresh token lives in the Keychain, not in preferences.
///
/// It is the one piece here that really is a secret: it grants access to the
/// user's own Drive until revoked. UserDefaults is a plist any process can
/// read.
enum TokenKeychain {
    private static let service = "com.miguel.cadenza.google"
    private static let account = "refresh-token"

    static func store(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// MARK: - Sign-in

/// The browser-based flow Google requires.
///
/// The app opens the system browser and the answer comes back through the URL
/// scheme registered in Info.plist. No embedded web view: Google blocks those
/// outright, and rightly — a login page inside an app is a login page the app
/// can read.
@MainActor
@Observable
final class GoogleAuth {
    static let shared = GoogleAuth()

    private(set) var email: String?
    private(set) var busy = false
    private(set) var lastError: String?

    private var accessToken: String?
    private var accessExpiry = Date.distantPast

    private static let connectedKey = "cadenza.google.connected"
    private static let emailKey = "cadenza.google.email"

    /// Whether there is a token, answered without waking the Keychain.
    ///
    /// Reading the Keychain is not a free question. If the item's access list
    /// does not recognise the running binary — which happens after any rebuild,
    /// and after any change of signing identity — macOS puts a modal password
    /// dialog on screen. Asking from `init`, or from a settings pane merely
    /// being drawn, meant that *opening the app* could demand the login
    /// password with no explanation of why.
    ///
    /// Sign-in and sign-out already know the answer, so they record it. The
    /// Keychain is touched only when a token is actually about to be used, and
    /// at that point a prompt is both expected and explicable.
    var isSignedIn: Bool { UserDefaults.standard.bool(forKey: Self.connectedKey) }

    private init() {
        let defaults = UserDefaults.standard
        // Someone who signed in before this flag existed still has their
        // address on record. Take that as the answer rather than reading the
        // Keychain to find out.
        if defaults.object(forKey: Self.connectedKey) == nil,
           defaults.string(forKey: Self.emailKey) != nil {
            defaults.set(true, forKey: Self.connectedKey)
        }
        if isSignedIn { email = defaults.string(forKey: Self.emailKey) }
    }

    func signOut() {
        TokenKeychain.clear()
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        accessToken = nil
        email = nil
    }

    // MARK: The flow

    func signIn() async {
        busy = true
        lastError = nil
        defer { busy = false }

        // PKCE is what stands in for the missing secret: the verifier never
        // leaves this process, so another app that somehow received the
        // redirect still could not trade the code for a token.
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)

        do {
            let redirect = GoogleCredentials.redirectURI

            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id", value: GoogleCredentials.clientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: GoogleCredentials.scope + " email"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                // Without this Google returns no refresh token on the second
                // sign-in, and the app silently loses access a hour later.
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]

            NSWorkspace.shared.open(components.url!)
            let code = try await awaitCallback()
            try await exchange(code: code, verifier: verifier, redirect: redirect)
        } catch {
            lastError = "Não consegui concluir o login: \(error.localizedDescription)"
        }
    }

    /// Waits for the browser to hand the answer back through the app's URL
    /// scheme. Resolved by `handleCallback`, which the app delegate calls.
    private var pendingCallback: CheckedContinuation<String, Error>?

    private func awaitCallback() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pendingCallback = continuation
            // A login the user walks away from must not leave the app waiting.
            Task {
                try? await Task.sleep(for: .seconds(300))
                if let pending = self.pendingCallback {
                    self.pendingCallback = nil
                    pending.resume(throwing: CloudError.message("tempo esgotado"))
                }
            }
        }
    }

    /// Called when macOS hands the app the redirect URL.
    func handleCallback(_ url: URL) {
        guard let pending = pendingCallback else { return }
        pendingCallback = nil

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            pending.resume(throwing: CloudError.message(
                error == "access_denied" ? "acesso negado" : error))
        } else if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
            pending.resume(returning: code)
        } else {
            pending.resume(throwing: CloudError.message("resposta sem código"))
        }
    }

    private func exchange(code: String, verifier: String, redirect: String) async throws {
        // No client_secret: a public client proves itself with the verifier.
        let body = [
            "code": code,
            "client_id": GoogleCredentials.clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ]
        let payload = try await Self.post("https://oauth2.googleapis.com/token", form: body)

        guard let access = payload["access_token"] as? String else {
            throw CloudError.message(String(describing: payload["error"] ?? "resposta inesperada"))
        }
        accessToken = access
        accessExpiry = Date().addingTimeInterval((payload["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = payload["refresh_token"] as? String {
            TokenKeychain.store(refresh)
            UserDefaults.standard.set(true, forKey: Self.connectedKey)
        }

        // The id_token carries the address; decoding its middle segment avoids
        // a second request just to show who is signed in.
        if let idToken = payload["id_token"] as? String,
           let address = Self.email(fromIDToken: idToken) {
            email = address
            UserDefaults.standard.set(address, forKey: Self.emailKey)
        }
    }

    /// A valid access token, refreshing if the last one has expired.
    func token() async throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = TokenKeychain.read() else { throw CloudError.notSignedIn }

        let payload = try await Self.post("https://oauth2.googleapis.com/token", form: [
            "client_id": GoogleCredentials.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        guard let access = payload["access_token"] as? String else {
            // A refresh token can be revoked from the Google account page, and
            // when it is, the honest thing is to sign out rather than retry.
            signOut()
            throw CloudError.notSignedIn
        }
        accessToken = access
        accessExpiry = Date().addingTimeInterval((payload["expires_in"] as? Double ?? 3600) - 60)
        return access
    }

    // MARK: Helpers

    private static func post(_ url: String, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { key, value in
            let encoded = value.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&").utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var middle = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while middle.count % 4 != 0 { middle += "=" }
        guard let data = Data(base64Encoded: middle),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum CloudError: LocalizedError {
    case notSignedIn
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Não conectado ao Google."
        case .message(let text): text
        }
    }
}
