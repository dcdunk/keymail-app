import Foundation

// MARK: Microsoft (Outlook.com, Hotmail, Microsoft 365) via Microsoft Graph

/// The account's email address from Graph's `/me` profile. Work accounts fill `mail`; personal Outlook.com
/// accounts often leave it empty and only have `userPrincipalName`. Guest sign-in names like
/// "bob_gmail.com#EXT#@contoso.onmicrosoft.com" aren't real mailboxes, so they're rejected.
public func microsoftAccountEmail(profile: [String: Any]) -> String? {
    for key in ["mail", "userPrincipalName"] {
        if let v = (profile[key] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
           v.contains("@"), !v.contains("#ext#") { return v }
    }
    return nil
}

/// Microsoft's sign-in errors in plain words. Codes from the `error_description` text (AADSTS…).
public func friendlyMicrosoftSignInError(_ description: String?) -> String {
    let d = description ?? ""
    if d.contains("AADSTS65001") || d.contains("AADSTS90094") || d.contains("AADSTS65004") {
        return "Your organization needs an administrator to approve Keymail before you can sign in. Ask your IT team."
    }
    if d.contains("AADSTS50020") { return "This Microsoft account can't sign in to Keymail. Try a different account." }
    if d.contains("AADSTS70008") || d.contains("AADSTS700082") || d.contains("AADSTS50173") {
        return "Your Microsoft sign-in expired. Add the account again in Settings → Accounts."
    }
    if d.contains("AADSTS50126") || d.contains("AADSTS50034") { return "Microsoft didn't recognize that account. Try again." }
    return "Microsoft sign-in didn't finish. Try again in a moment."
}
