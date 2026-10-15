import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Accounts

    func addAccount() {
        Task {
            busy = "Waiting for Google sign-in in your browser…"
            do {
                let email = try await auth.signIn().email
                if !state.accounts.contains(email) { state.accounts.append(email) }
                state.historyIds[email] = nil
                busy = nil
                try await fullSync(email)
                saveCache()
            } catch { busy = nil; report(error) }
        }
    }

    /// Checks the app-specific password with iCloud before saving it to the Keychain.
    func addICloudAccount(email: String, password: String, aliases: String = "") async throws {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let found = try await ICloud.findLogin(email: e, password: password)
        Keychain.set(found.password, for: ICloud.keychainKey(e))
        state.icloudLogins[e] = found.login
        setAliases(aliases, for: e)
        if !state.accounts.contains(e) { state.accounts.append(e) }
        if !state.icloud.contains(e) { state.icloud.append(e) }
        Task {
            busy = "Loading \(e)…"
            defer { busy = nil }
            do { try await syncICloud(e); saveCache() } catch { report(error) }
        }
    }

    // MARK: Microsoft (preview: sign-in and an inbox check; mail support comes next)

    func connectMicrosoft() {
        Task {
            busy = "Waiting for Microsoft sign-in in your browser…"
            defer { busy = nil }
            do {
                let email = try await microsoft.signIn()
                if !state.microsoftPreview.contains(email) { state.microsoftPreview.append(email) }
                await checkMicrosoft(email)
            } catch { report(error) }
        }
    }

    /// Proves Keymail can read the mailbox: asks Microsoft for the inbox's email and unread counts.
    func checkMicrosoft(_ a: String) async {
        microsoftStatus[a] = "Checking…"
        do {
            let token = try await microsoft.accessToken(for: a)
            var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox?$select=totalItemCount,unreadItemCount")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await GoogleNet.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                microsoftStatus[a] = "Signed in, but the inbox couldn't be read."
                return
            }
            let total = j["totalItemCount"] as? Int ?? 0, unread = j["unreadItemCount"] as? Int ?? 0
            microsoftStatus[a] = "Connected · \(total.formatted()) emails in Inbox, \(unread.formatted()) unread"
        } catch {
            microsoftStatus[a] = error.localizedDescription
        }
    }

    func removeMicrosoft(_ a: String) {
        Keychain.delete(MicrosoftAuth.keychainKey(a))
        microsoft.invalidate(a)
        state.microsoftPreview.removeAll { $0 == a }
        microsoftStatus[a] = nil
    }

    func removeAccount(_ a: String) {
        Keychain.delete(a)
        Keychain.delete(ICloud.keychainKey(a))
        state.forget(a)
        messages = messages.filter { $0.value.account != a }
        saveCache()
    }
}
