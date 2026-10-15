import AppKit
import Foundation
import Network
import Security
import EmailCore
import CryptoKit

// MARK: Network

/// Google calls carry bearer tokens and full message bodies, so they never touch the shared on-disk URL cache
/// (~/Library/Caches/<app>/Cache.db), which isn't encrypted. Ephemeral = memory only.
enum GoogleNet {
    static let session = URLSession(configuration: .ephemeral)

    /// Older builds used the shared cache: wipe whatever it stored, once.
    static func purgeOldCache() {
        guard !UserDefaults.standard.bool(forKey: "purgedSharedURLCacheV1") else { return }
        URLCache.shared.removeAllCachedResponses()
        if let id = Bundle.main.bundleIdentifier {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(id)
            for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        UserDefaults.standard.set(true, forKey: "purgedSharedURLCacheV1")
    }
}

// MARK: Google OAuth (desktop loopback flow with PKCE)

struct AppError: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

struct HTTPError: LocalizedError {
    let status: Int, body: String
    var isRateLimit: Bool { status == 429 || (status == 403 && (body.contains("ateLimit") || body.contains("uota"))) }
    var isTransient: Bool { isTransientGoogleError(status: status, body: body) }
    /// The account was signed in before Email asked for this permission.
    var needsMorePermission: Bool { status == 403 && (body.contains("nsufficient") || body.lowercased().contains("scope")) }
    var errorDescription: String? { friendlyGoogleError(status: status, body: body) }
}

struct GoogleClient: Decodable {
    let client_id: String, client_secret: String
    static let file = Disk.dir.appendingPathComponent("google_client.json")
    /// The JSON you download from Google Cloud for a "Desktop app" OAuth client.
    /// The app ships with its own Google client (built in by build.sh), so users just sign in.
    /// A file chosen in Settings → Accounts → Advanced overrides it (for developers).
    static func load() -> GoogleClient? {
        struct Wrapper: Decodable { let installed: GoogleClient?; let web: GoogleClient? }
        for url in [file, Bundle.main.url(forResource: "google_client", withExtension: "json")].compactMap({ $0 }) {
            if let d = try? Data(contentsOf: url), let w = try? JSONDecoder().decode(Wrapper.self, from: d), let c = w.installed ?? w.web { return c }
        }
        return nil
    }
    static var isBuiltIn: Bool { !FileManager.default.fileExists(atPath: file.path) && load() != nil }
}

@MainActor
final class GoogleAuth {
    private var cache: [String: (token: String, expires: Date)] = [:]
    // gmail.settings.basic: out of office, signatures (send-as). Accounts added before it existed are asked again once.
    // calendar.events: answer invites (Accept / Maybe / No) on the account's own Google Calendar.
    let scopes = "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.settings.basic https://www.googleapis.com/auth/calendar.events"

    func invalidate(_ account: String) { cache[account] = nil }

    func accessToken(for account: String) async throws -> String {
        if let c = cache[account], c.expires > Date().addingTimeInterval(60) { return c.token }
        guard let client = GoogleClient.load() else { throw AppError("Google client file missing.") }
        guard let refresh = Keychain.get(account) else { throw AppError("\(account) is signed out. Press ⌘K → Add Google account.") }
        let j = try await tokenRequest(["client_id": client.client_id, "client_secret": client.client_secret,
                                        "refresh_token": refresh, "grant_type": "refresh_token"])
        guard let token = j["access_token"] as? String else {
            throw AppError("\(account) needs to sign in again (Google expires test-mode sign-ins after 7 days). Press ⌘K → Add Google account.")
        }
        cache[account] = (token, Date().addingTimeInterval(j["expires_in"] as? Double ?? 3000))
        return token
    }

    /// Which permissions this account's sign-in actually has (asks Google, so it's always current).
    func grantedScopes(_ account: String) async -> Set<String> {
        guard let token = try? await accessToken(for: account),
              let url = URL(string: "https://oauth2.googleapis.com/tokeninfo?access_token=\(token)"),
              let (data, _) = try? await GoogleNet.session.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set((j["scope"] as? String ?? "").split(separator: " ").map(String.init))
    }
    nonisolated static let settingsScope = "https://www.googleapis.com/auth/gmail.settings.basic"

    /// Opens the browser, waits for Google to redirect back to 127.0.0.1, returns the account's email and the
    /// permissions the person actually ticked (Google lets them untick some). `hint` preselects that account.
    func signIn(hint: String? = nil) async throws -> (email: String, scopes: Set<String>) {
        guard let client = GoogleClient.load() else { throw AppError("Google client file missing.") }
        let verifier = (0..<2).map { _ in UUID().uuidString }.joined().replacingOccurrences(of: "-", with: "")
        let state = UUID().uuidString
        var redirect = ""
        let params = try await receiveRedirect { port in
            redirect = "http://127.0.0.1:\(port)"
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [.init(name: "client_id", value: client.client_id), .init(name: "redirect_uri", value: redirect),
                            .init(name: "response_type", value: "code"), .init(name: "scope", value: self.scopes),
                            .init(name: "code_challenge", value: pkceChallenge(verifier)), .init(name: "code_challenge_method", value: "S256"),
                            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent select_account"),
                            .init(name: "state", value: state), .init(name: "include_granted_scopes", value: "true")]
                + (hint.map { [.init(name: "login_hint", value: $0)] } ?? [])
            NSWorkspace.shared.open(c.url!)
        }
        guard params["state"] == state, let code = params["code"] else { throw AppError("Sign-in was cancelled or failed.") }
        let j = try await tokenRequest(["client_id": client.client_id, "client_secret": client.client_secret, "code": code,
                                        "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"])
        guard let access = j["access_token"] as? String, let refresh = j["refresh_token"] as? String else {
            throw AppError("Google didn't return a refresh token.")
        }
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await GoogleNet.session.data(for: req)
        guard let email = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["emailAddress"] as? String else {
            throw AppError("Couldn't load this Gmail account. Try signing in again in a few minutes.")
        }
        Keychain.set(refresh, for: email)
        cache[email] = (access, Date().addingTimeInterval(j["expires_in"] as? Double ?? 3000))
        AuthLog.log.notice("sign-in \(email, privacy: .public) granted: \((j["scope"] as? String ?? "").components(separatedBy: " ").map { $0.components(separatedBy: "/").last ?? $0 }.sorted().joined(separator: ","), privacy: .public)")
        return (email, Set((j["scope"] as? String ?? "").split(separator: " ").map(String.init)))
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await GoogleNet.session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// One-shot HTTP listener on 127.0.0.1. Gives up after 5 minutes.
    private func receiveRedirect(onReady: @escaping (UInt16) -> Void) async throws -> [String: String] {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            func finish(_ r: Result<[String: String], Error>) {
                guard !done else { return }
                done = true; cont.resume(with: r)
                // Stay up a few seconds more to serve the clean /signed-in page the browser is sent to.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { listener.cancel() }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if let p = listener.port?.rawValue { onReady(p) }
                case .failed(let e): finish(.failure(e))
                default: break
                }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let q = queryItems(fromRequest: request)
                    func reply(_ head: String, _ body: String = "") {
                        let resp = head + "\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body
                        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    }
                    if q["code"] != nil || q["error"] != nil {
                        // Google's return address carries the one-time code; forward to a clean address so it
                        // doesn't sit in the address bar or browser history.
                        let target = q["code"] != nil ? "/signed-in" : "/not-signed-in?reason=" + (q["error"] ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                        reply("HTTP/1.1 303 See Other\r\nLocation: \(target)")
                        finish(.success(q))
                    } else if path.hasPrefix("/signed-in") {
                        reply("HTTP/1.1 200 OK", SignInPage.html(ok: true))
                    } else if path.hasPrefix("/not-signed-in") {
                        reply("HTTP/1.1 200 OK", SignInPage.html(ok: false, reason: q["reason"]))
                    } else {
                        reply("HTTP/1.1 404 Not Found") // stray requests like /favicon.ico
                    }
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(.failure(AppError("Sign-in timed out."))) }
        }
    }
}

/// The page the browser shows after Google sign-in: Keymail's icon, a clear message, light and dark mode.
enum SignInPage {
    static let iconDataURL: String = {
        let img = NSApp.applicationIconImage ?? NSImage()
        let size = NSSize(width: 160, height: 160)
        let out = NSImage(size: size); out.lockFocus(); img.draw(in: NSRect(origin: .zero, size: size)); out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    static func html(ok: Bool, reason: String? = nil) -> String {
        let title = ok ? "You're signed in" : "Sign-in didn't finish"
        let detail = ok ? "Keymail has what it needs. You can close this tab and head back to your inbox."
            : reason == "access_denied" ? "Access wasn't approved. Go back to Keymail and try again when you're ready."
            : "Something interrupted the sign-in. Go back to Keymail and try again."
        let mark = ok ? "<path d='M7 12.5l3.2 3.2L17 9' />" : "<path d='M12 7.5v6' /><path d='M12 16.6v.1' />"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Keymail · \(title)</title>
        <style>
        :root { color-scheme: light dark; --bg:#f5f5f7; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:rgba(0,0,0,.08); --accent:#4a66ed; }
        @media (prefers-color-scheme: dark) { :root { --bg:#141416; --card:#1e1e21; --text:#f2f2f4; --muted:#9a9aa1; --line:rgba(255,255,255,.08); --accent:#7a90ff; } }
        * { box-sizing: border-box; }
        body { margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg); color:var(--text);
               font:15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; padding:24px; }
        .card { width:100%; max-width:420px; background:var(--card); border:1px solid var(--line); border-radius:20px;
                padding:40px 36px 32px; text-align:center; animation: rise .5s cubic-bezier(.2,.8,.2,1) both; }
        .icon { width:80px; height:80px; position:relative; margin:0 auto 22px; }
        .icon img { width:80px; height:80px; }
        .badge { position:absolute; right:-6px; bottom:-6px; width:30px; height:30px; border-radius:50%;
                 background:\(ok ? "var(--accent)" : "#e0863a"); border:3px solid var(--card); display:grid; place-items:center; }
        .badge svg { width:18px; height:18px; fill:none; stroke:#fff; stroke-width:2.4; stroke-linecap:round; stroke-linejoin:round; }
        h1 { font-size:22px; font-weight:600; margin:0 0 8px; letter-spacing:-.01em; }
        p { margin:0; color:var(--muted); }
        .foot { margin-top:28px; padding-top:18px; border-top:1px solid var(--line); font-size:12px; color:var(--muted); }
        @keyframes rise { from { opacity:0; transform:translateY(8px); } to { opacity:1; transform:none; } }
        @media (prefers-reduced-motion: reduce) { .card { animation:none; } }
        </style></head><body>
        <main class="card">
          <div class="icon"><img src="\(iconDataURL)" alt=""><span class="badge"><svg viewBox="0 0 24 24">\(mark)</svg></span></div>
          <h1>\(title)</h1>
          <p>\(detail)</p>
          <div class="foot">Keymail talks to Google directly from your Mac. Nothing goes through our servers.</div>
        </main>
        </body></html>
        """
    }
}
