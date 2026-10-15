import AppKit
import Foundation
import Network
import Security
import EmailCore
import CryptoKit

/// The demo build ("Email Demo", bundle id ending in .demo) keeps its own data and Keychain entries,
/// so it starts fresh like a new user and never touches the real app's accounts.
enum AppFlavor {
    static let isDemo = Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true
}

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

// MARK: Disk

enum Disk {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppFlavor.isDemo ? "Email-Demo" : "Email")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // Mail cache and settings: readable by you only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        return d
    }()
    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let data: Data
        if raw.starts(with: encryptedFileMagic) {
            guard let key = CacheKey.key else { return nil } // Keychain unavailable: don't touch the file
            guard let d = try? decryptFile(raw, key: key) else {
                // Never delete what can't be read; set it aside so nothing is overwritten.
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
                return nil
            }
            data = d
        } else {
            // Plain files exist only from before encryption, and are accepted just once: on the launch that
            // created the key. After that a plain file was planted (it would skip the tamper check), so it's set aside.
            _ = CacheKey.key // make sure the Keychain check has run
            guard CacheKey.createdThisLaunch else {
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unencrypted-\(Int(Date().timeIntervalSince1970))"))
                return nil
            }
            data = raw
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: data)
    }
    /// Encrypted with AES-256-GCM; the key lives in the Keychain. Readable by you only on disk too.
    static func save<T: Encodable>(_ value: T, _ name: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        // No key (Keychain refused): skip saving rather than write something unreadable or unencrypted.
        guard let key = CacheKey.key, let json = try? enc.encode(value), let sealed = try? encryptFile(json, key: key) else { return }
        let url = dir.appendingPathComponent(name)
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Attachment previews must stay plain files for Quick Look, so they're cleared at every launch.
    static func clearPreviewCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(AppFlavor.isDemo ? "Email-Demo" : "Email")
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The 256-bit key for Email's files: created once, kept in the Keychain, read once per launch.
/// Nil only if the Keychain refuses access; a new key is made only when none exists at all.
enum CacheKey {
    /// True only on the first launch after installing (or upgrading from a build without encryption).
    private(set) static var createdThisLaunch = false
    static let key: SymmetricKey? = {
        let account = "cache-encryption-key"
        var out: AnyObject?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: Keychain.service, kSecAttrAccount: account,
                 kSecReturnData: true] as CFDictionary
        switch SecItemCopyMatching(q, &out) {
        case errSecSuccess:
            guard let d = out as? Data, let b = Data(base64Encoded: d), b.count == 32 else { return nil }
            return SymmetricKey(data: b)
        case errSecItemNotFound:
            createdThisLaunch = true
            let k = SymmetricKey(size: .bits256)
            Keychain.set(k.withUnsafeBytes { Data($0) }.base64EncodedString(), for: account)
            return k
        default:
            return nil
        }
    }()
}

// MARK: Keychain (refresh tokens only)

enum Keychain {
    static let service = AppFlavor.isDemo ? "Email-Demo.google-refresh-token" : "Email.google-refresh-token"
    static func set(_ value: String, for account: String) {
        delete(account)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecValueData: Data(value.utf8)] as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        var out: AnyObject?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                 kSecReturnData: true] as CFDictionary
        guard SecItemCopyMatching(q, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
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
    let scopes = "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.settings.basic"

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
    static let settingsScope = "https://www.googleapis.com/auth/gmail.settings.basic"

    /// Opens the browser, waits for Google to redirect back to 127.0.0.1, returns the account's email.
    func signIn() async throws -> String {
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
            throw AppError("Couldn't read the Gmail profile. Is the Gmail API enabled in your Google Cloud project?")
        }
        Keychain.set(refresh, for: email)
        cache[email] = (access, Date().addingTimeInterval(j["expires_in"] as? Double ?? 3000))
        return email
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
                        if q["code"] != nil { NSApp.activate(ignoringOtherApps: true) } // bring Lightmail back to the front
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

/// The page the browser shows after Google sign-in: Lightmail's icon, a clear message, light and dark mode.
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
        let detail = ok ? "Lightmail has what it needs. You can close this tab and head back to your inbox."
            : reason == "access_denied" ? "Access wasn't approved. Go back to Lightmail and try again when you're ready."
            : "Something interrupted the sign-in. Go back to Lightmail and try again."
        let mark = ok ? "<path d='M7 12.5l3.2 3.2L17 9' />" : "<path d='M12 7.5v6' /><path d='M12 16.6v.1' />"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Lightmail · \(title)</title>
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
          <div class="foot">Lightmail talks to Google directly from your Mac. Nothing goes through our servers.</div>
        </main>
        </body></html>
        """
    }
}

// MARK: Gmail REST API

struct Gmail {
    let account: String
    let auth: GoogleAuth

    /// Waits and retries when Gmail says "slow down" (429, or 403 rate/quota errors): 2s, 4s, 8s, 16s.
    func call(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do { return try await callOnce(path, method: method, query: query, json: json) }
            // Rate limits and Google's temporary 5xx errors: wait 2s, 4s, 8s, 16s and retry.
            catch let e as HTTPError where attempt < 4 && e.isTransient {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
            }
        }
    }

    private func callOnce(_ path: String, method: String, query: [URLQueryItem], json: [String: Any]?, retry: Bool = true) async throws -> [String: Any] {
        var c = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken(for: account))", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await GoogleNet.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, retry {
            await auth.invalidate(account)
            return try await callOnce(path, method: method, query: query, json: json, retry: false)
        }
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func listIds(_ q: String, max: Int) async throws -> [String] {
        var ids: [String] = [], page: String?
        repeat {
            var query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "maxResults", value: "100")]
            // Gmail leaves spam and trash out of results unless asked.
            if q.contains("in:spam") || q.contains("in:trash") { query.append(.init(name: "includeSpamTrash", value: "true")) }
            if let page { query.append(.init(name: "pageToken", value: page)) }
            let j = try await call("messages", query: query)
            ids += (j["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            page = j["nextPageToken"] as? String
        } while page != nil && ids.count < max
        return Array(ids.prefix(max))
    }

    /// Fetches full messages 8 at a time. Messages that fail (e.g. deleted meanwhile) are skipped.
    func messages(_ ids: [String]) async -> [Message] {
        var out: [Message] = []
        for chunk in stride(from: 0, to: ids.count, by: 8).map({ Array(ids[$0..<min($0 + 8, ids.count)]) }) {
            await withTaskGroup(of: Message?.self) { g in
                for id in chunk {
                    g.addTask { (try? await call("messages/\(id)", query: [.init(name: "format", value: "full")])).flatMap { parseMessage($0, account: account) } }
                }
                for await m in g { if let m { out.append(m) } }
            }
        }
        return out
    }

    func thread(_ id: String) async throws -> [Message] {
        let j = try await call("threads/\(id)", query: [.init(name: "format", value: "full")])
        return (j["messages"] as? [[String: Any]] ?? []).compactMap { parseMessage($0, account: account) }
    }

    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        _ = try await call("threads/\(id)/modify", method: "POST", json: ["addLabelIds": add, "removeLabelIds": remove])
    }

    func trashThread(_ id: String) async throws { _ = try await call("threads/\(id)/trash", method: "POST") }
    func untrashThread(_ id: String) async throws { _ = try await call("threads/\(id)/untrash", method: "POST") }

    /// Gmail's upload endpoint (35 MB limit) with JSON metadata + the raw message. Used for send and drafts.
    private func upload(_ path: String, method: String = "POST", meta: [String: Any], raw: Data) async throws -> [String: Any] {
        let boundary = "email_" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += try JSONSerialization.data(withJSONObject: meta)
        body += Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8)
        body += raw
        body += Data("\r\n--\(boundary)--".utf8)
        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/\(path)?uploadType=multipart")!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken(for: account))", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await GoogleNet.session.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func send(_ d: Draft) async throws -> [String: Any] {
        var meta: [String: Any] = [:]
        if let t = d.threadId { meta["threadId"] = t }
        return try await upload("messages/send", meta: meta, raw: Data(buildRaw(d).utf8))
    }

    /// Creates or updates a Gmail draft; returns its draft id.
    func saveDraft(_ d: Draft) async throws -> String {
        var message: [String: Any] = [:]
        if let t = d.threadId { message["threadId"] = t }
        let raw = Data(buildRaw(d).utf8)
        if let id = d.draftId {
            do { return try await upload("drafts/\(id)", method: "PUT", meta: ["id": id, "message": message], raw: raw)["id"] as? String ?? id }
            catch let e as HTTPError where e.status == 404 { /* deleted elsewhere: fall through and recreate */ }
        }
        return try await upload("drafts", meta: ["message": message], raw: raw)["id"] as? String ?? ""
    }

    func deleteDraft(_ id: String) async throws { _ = try await call("drafts/\(id)", method: "DELETE") }

    /// Message id → draft id, so opening a draft from the Drafts folder edits the same draft.
    func draftIds() async throws -> [String: String] {
        var out: [String: String] = [:], page: String?
        repeat {
            var q = [URLQueryItem(name: "maxResults", value: "100")]
            if let page { q.append(.init(name: "pageToken", value: page)) }
            let j = try await call("drafts", query: q)
            for d in j["drafts"] as? [[String: Any]] ?? [] {
                if let id = d["id"] as? String, let mid = (d["message"] as? [String: Any])?["id"] as? String { out[mid] = id }
            }
            page = j["nextPageToken"] as? String
        } while page != nil
        return out
    }

    func attachment(message: String, id: String) async throws -> Data {
        let j = try await call("messages/\(message)/attachments/\(id)")
        guard let d = (j["data"] as? String).flatMap(base64urlDecode) else { throw AppError("Couldn't download the attachment.") }
        return d
    }

    func historyId() async throws -> String { try await call("profile")["historyId"] as? String ?? "" }

    /// Returns nil when Google says the history id is too old (needs a full resync).
    func history(since start: String) async throws -> (pages: [[String: Any]], latest: String)? {
        var pages: [[String: Any]] = [], page: String?, latest = start
        repeat {
            var q = [URLQueryItem(name: "startHistoryId", value: start)]
            if let page { q.append(.init(name: "pageToken", value: page)) }
            do {
                let j = try await call("history", query: q)
                pages.append(j); page = j["nextPageToken"] as? String
                latest = j["historyId"] as? String ?? latest
            } catch let e as HTTPError where e.status == 404 { return nil }
        } while page != nil
        return (pages, latest)
    }

    // MARK: Settings: out of office, send-as signatures, labels

    func vacation() async throws -> Vacation { Vacation(json: try await call("settings/vacation")) }
    func setVacation(_ v: Vacation) async throws { _ = try await call("settings/vacation", method: "PUT", json: v.json) }

    struct SendAs: Identifiable { var id: String { email }; let email: String, name: String, signature: String, isPrimary: Bool }
    func sendAs() async throws -> [SendAs] {
        (try await call("settings/sendAs")["sendAs"] as? [[String: Any]] ?? []).compactMap { j in
            guard let e = j["sendAsEmail"] as? String else { return nil }
            return SendAs(email: e, name: j["displayName"] as? String ?? "", signature: j["signature"] as? String ?? "",
                          isPrimary: j["isPrimary"] as? Bool ?? false)
        }
    }
    func setSignature(_ address: String, html: String) async throws {
        let path = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? address
        _ = try await call("settings/sendAs/\(path)", method: "PATCH", json: ["signature": html])
    }

    struct Label: Identifiable, Hashable { let id: String; var name: String; var bg: String?; var text: String? }
    func userLabels() async throws -> [Label] {
        (try await call("labels")["labels"] as? [[String: Any]] ?? []).compactMap { l in
            guard l["type"] as? String == "user", let id = l["id"] as? String, let name = l["name"] as? String else { return nil }
            let c = l["color"] as? [String: Any]
            return Label(id: id, name: name, bg: c?["backgroundColor"] as? String, text: c?["textColor"] as? String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func createLabel(_ name: String) async throws {
        _ = try await call("labels", method: "POST", json: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
    }
    func updateLabel(_ id: String, name: String? = nil, color: (bg: String, text: String)? = nil) async throws {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let color { body["color"] = ["backgroundColor": color.bg, "textColor": color.text] }
        _ = try await call("labels/\(id)", method: "PATCH", json: body)
    }
    func deleteLabel(_ id: String) async throws { _ = try await call("labels/\(id)", method: "DELETE") }

    func labels() async throws -> [String: String] {
        let j = try await call("labels")
        var out: [String: String] = [:]
        for l in j["labels"] as? [[String: Any]] ?? [] where l["type"] as? String == "user" {
            if let id = l["id"] as? String, let name = l["name"] as? String { out[id] = name }
        }
        return out
    }

    func labelId(named name: String, existing: [String: String]) async throws -> String {
        if let id = existing.first(where: { $0.value == name })?.key { return id }
        return try await call("labels", method: "POST", json: ["name": name, "labelListVisibility": "labelHide"])["id"] as? String ?? ""
    }
}

// MARK: AI providers (command-line tools already signed in on this Mac, billed to your own plan)

struct AIProvider: Identifiable, Hashable {
    let id: String, name: String, maker: String, binary: String
    let installURL: String, signInHint: String
    /// Arguments for a one-shot, read-only run. The prompt always goes in on stdin.
    let args: (_ model: String?) -> [String]

    static func == (a: AIProvider, b: AIProvider) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let all: [AIProvider] = [
        AIProvider(id: "claude", name: "Claude", maker: "Anthropic", binary: "claude",
                   installURL: "https://claude.com/claude-code", signInHint: "Run `claude` in Terminal and log in.",
                   // --tools "" turns every tool off: email text can only produce text.
                   args: { m in ["-p", "--tools", "", "--output-format", "text"] + (m.map { ["--model", $0] } ?? []) }),
        AIProvider(id: "codex", name: "Codex", maker: "OpenAI", binary: "codex",
                   installURL: "https://github.com/openai/codex", signInHint: "Run `codex login` in Terminal.",
                   // Read-only sandbox: it can't write files or run commands that change anything.
                   args: { m in ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral"] + (m.map { ["-m", $0] } ?? []) }),
        AIProvider(id: "gemini", name: "Gemini", maker: "Google", binary: "gemini",
                   installURL: "https://github.com/google-gemini/gemini-cli", signInHint: "Run `gemini` in Terminal and sign in, or set GEMINI_API_KEY.",
                   // plan = read-only approval mode; --skip-trust lets it run headless outside a trusted project folder.
                   args: { m in ["-p", "Respond to the request above. Output only the answer.", "--approval-mode", "plan", "--skip-trust"]
                       + (m.map { ["-m", $0] } ?? []) }),
    ]
}

enum AI {
    static func binary(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)",
                          "\(home)/.claude/local/\(name)", "\(home)/.npm-global/bin/\(name)"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        // Apps launched from Finder don't get your shell PATH, so ask a login shell.
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "command -v \(name)"]; p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func run(_ prompt: String, with provider: AIProvider, model: String? = nil) async throws -> String {
        guard let bin = binary(provider.binary) else {
            throw AppError("\(provider.name) isn't installed. Install it, then: \(provider.signInHint)")
        }
        let model = model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return try await Task.detached {
            let p = Process(), input = Pipe(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = provider.args(model)
            // An empty scratch folder, so nothing in it is worth reading.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("email-ai")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env["NO_COLOR"] = "1"
            p.environment = env
            p.standardInput = input; p.standardOutput = out; p.standardError = err
            try p.run()
            input.fileHandleForWriting.write(Data(prompt.utf8)); try? input.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0, !text.isEmpty else {
                let msg = String(decoding: errData + data, as: UTF8.self)
                // Surface the tool's own error line, which says what's wrong (login, model, plan).
                let line = msg.components(separatedBy: .newlines).last { $0.contains("rror") || $0.lowercased().contains("login") || $0.lowercased().contains("not supported") }
                    ?? msg.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "no output"
                throw AppError("\(provider.name) failed: \(line.trimmingCharacters(in: .whitespaces).prefix(220))")
            }
            return text
        }.value
    }
}
