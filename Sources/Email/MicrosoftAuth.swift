import AppKit
import Foundation
import EmailCore

/// Sign in with Microsoft (personal Outlook.com/Hotmail and work/school Microsoft 365 accounts).
/// Same shape as Google: the browser signs in, returns to 127.0.0.1 on this Mac, and a PKCE check proves the
/// returning code is ours. Desktop apps can't keep secrets, so there is no client secret.
@MainActor
final class MicrosoftAuth {
    /// The "Keymail" app registration in Microsoft Entra (not a secret: it's in every copy of the app).
    static let clientId = "49c942b2-3216-4244-8516-0d622335f648"
    /// `common` lets both personal and work accounts sign in.
    static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    static let scopes = "offline_access openid email profile User.Read Mail.ReadWrite Mail.Send MailboxSettings.ReadWrite"
    static func keychainKey(_ account: String) -> String { "ms:" + account }

    private var cache: [String: (token: String, expires: Date)] = [:]

    func invalidate(_ account: String) { cache[account] = nil }

    func accessToken(for account: String) async throws -> String {
        if let c = cache[account], c.expires > Date().addingTimeInterval(60) { return c.token }
        guard let refresh = Keychain.get(Self.keychainKey(account)) else {
            throw AppError("\(account) is signed out. Add it again in Settings → Accounts.")
        }
        let j = try await tokenRequest(["client_id": Self.clientId, "grant_type": "refresh_token",
                                        "refresh_token": refresh, "scope": Self.scopes])
        guard let token = j["access_token"] as? String else {
            throw AppError(friendlyMicrosoftSignInError(j["error_description"] as? String))
        }
        // Microsoft hands out a new refresh token each time; keep the latest.
        if let newRefresh = j["refresh_token"] as? String { Keychain.set(newRefresh, for: Self.keychainKey(account)) }
        cache[account] = (token, Date().addingTimeInterval(j["expires_in"] as? Double ?? 3000))
        return token
    }

    /// Opens the browser, waits for Microsoft to send it back to this Mac, returns the account's email address.
    func signIn(hint: String? = nil) async throws -> String {
        let verifier = (0..<2).map { _ in UUID().uuidString }.joined().replacingOccurrences(of: "-", with: "")
        let state = UUID().uuidString
        var redirect = ""
        let params = try await receiveOAuthRedirect { port in
            redirect = "http://127.0.0.1:\(port)"
            var c = URLComponents(string: Self.authority + "/authorize")!
            c.queryItems = [.init(name: "client_id", value: Self.clientId), .init(name: "response_type", value: "code"),
                            .init(name: "redirect_uri", value: redirect), .init(name: "response_mode", value: "query"),
                            .init(name: "scope", value: Self.scopes), .init(name: "state", value: state),
                            .init(name: "code_challenge", value: pkceChallenge(verifier)), .init(name: "code_challenge_method", value: "S256"),
                            .init(name: "prompt", value: "select_account")]
                + (hint.map { [.init(name: "login_hint", value: $0)] } ?? [])
            NSWorkspace.shared.open(c.url!)
        }
        if let err = params["error_description"] ?? params["error"] { throw AppError(friendlyMicrosoftSignInError(err)) }
        guard params["state"] == state, let code = params["code"] else { throw AppError("Sign-in was cancelled or failed.") }
        let j = try await tokenRequest(["client_id": Self.clientId, "grant_type": "authorization_code", "code": code,
                                        "redirect_uri": redirect, "code_verifier": verifier, "scope": Self.scopes])
        guard let access = j["access_token"] as? String, let refresh = j["refresh_token"] as? String else {
            throw AppError(friendlyMicrosoftSignInError(j["error_description"] as? String))
        }
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName,displayName")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await GoogleNet.session.data(for: req)
        guard let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = microsoftAccountEmail(profile: profile) else {
            throw AppError("Couldn't load this Microsoft account. Try signing in again in a few minutes.")
        }
        Keychain.set(refresh, for: Self.keychainKey(email))
        cache[email] = (access, Date().addingTimeInterval(j["expires_in"] as? Double ?? 3000))
        return email
    }

    private func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: Self.authority + "/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        // Same no-disk-cache session as Google: tokens never land in the shared URL cache.
        let (data, _) = try await GoogleNet.session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
