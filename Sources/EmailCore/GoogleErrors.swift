import Foundation

// MARK: Friendly Google errors

/// Turns any Gmail API error response into a sentence a person can act on. Never shows raw JSON.
public func friendlyGoogleError(status: Int, body: String) -> String {
    let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    let err = json?["error"] as? [String: Any]
    let message = (err?["message"] as? String) ?? (json?["error_description"] as? String) ?? ""
    let reason = ((err?["errors"] as? [[String: Any]])?.first?["reason"] as? String ?? "").lowercased()
    let lower = (message + " " + reason + " " + body.prefix(300)).lowercased()
    switch status {
    case 400 where lower.contains("invalid_grant"):
        return "Your Google sign-in expired. Re-add the account in Settings → Accounts."
    case 400:
        return "Gmail couldn't process that request" + (message.isEmpty ? "." : ": \(message)")
    case 401:
        return "Your Google sign-in expired. Re-add the account in Settings → Accounts."
    case 403 where lower.contains("ratelimit") || lower.contains("quota"):
        return "Gmail is asking Keymail to slow down. It will retry automatically."
    case 403 where lower.contains("accessnotconfigured") || lower.contains("has not been used") || lower.contains("disabled"):
        return "Gmail isn't available to Keymail right now. Try again in a few minutes."
    case 403 where lower.contains("insufficient") || lower.contains("scope"):
        return "Keymail doesn't have permission for that. Remove the account and add it again to grant access."
    case 403:
        return "Google blocked that request" + (message.isEmpty ? "." : ": \(message)")
    case 404:
        return "Gmail couldn't find that email. It may have been deleted or moved elsewhere."
    case 409:
        return "That email changed somewhere else at the same time. Try again."
    case 413:
        return "That email is too large for Gmail (25 MB limit including attachments)."
    case 429:
        return "Gmail is asking Email to slow down. It will retry automatically."
    case 500...599:
        return "Gmail is having a temporary problem. Keymail will try again shortly."
    default:
        return "Gmail returned an unexpected error (\(status))" + (message.isEmpty ? "." : ": \(message)")
    }
}

/// Errors worth retrying quietly: rate limits and Google's own temporary failures.
public func isTransientGoogleError(status: Int, body: String) -> Bool {
    status == 429 || (500...599).contains(status)
        || (status == 403 && (body.contains("ateLimit") || body.contains("uota")))
}

/// Network problems (offline, timeouts, DNS) in plain words.
public func friendlyNetworkError(_ e: Error) -> String? {
    guard let u = e as? URLError else { return nil }
    switch u.code {
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "You're offline. Keymail will catch up when you reconnect."
    case .timedOut: return "The connection timed out. Keymail will try again."
    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Couldn't reach the mail server. Check your connection."
    case .secureConnectionFailed, .serverCertificateUntrusted: return "A secure connection couldn't be made. If you're on public Wi-Fi, try another network."
    default: return "A network error occurred (\(u.code.rawValue)). Keymail will try again."
    }
}
